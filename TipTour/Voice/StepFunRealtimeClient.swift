//
//  StepFunRealtimeClient.swift
//  TipTour
//
//  WebSocket client for StepFun's Realtime voice API (阶跃星辰双向实时语音).
//  One bidirectional connection carries microphone audio in and synthesized
//  speech out, plus the tool calls that let the voice model ask the app to act
//  on the desktop.
//
//  Why this exists instead of extending the Gemini client: the two protocols
//  share a shape but not a message vocabulary, and the differences are exactly
//  where the bugs live. This client encodes the behaviour that was measured
//  against the live API (see docs/model-research-findings.md §7) rather than
//  what the documentation claims.
//
//  Connection lifecycle:
//  1. connect() opens wss://api.stepfun.com/v1/realtime?model=<model> with a
//     Bearer key, and waits for the server's opening `session.created`.
//  2. session.update configures voice, instructions, audio formats and tools.
//  3. sendAudioChunk() streams base64 PCM16 24 kHz mono in ~20 ms pieces.
//  4. A turn is closed either by server VAD, or by the caller invoking
//     commitAndRequestResponse() when VAD is off.
//  5. The server streams response.audio.delta for playback,
//     response.audio_transcript.delta for captions, and — after the speech —
//     the function call arguments.
//  6. The caller runs the tool, then sendToolResult() closes the loop and
//     requestFollowUpResponse() makes the model speak again.
//
//  Measurement notes that shape this implementation:
//  - The model SPEAKS FIRST and emits its tool call afterwards, in the same
//    turn. A tool result sent while audio is still playing interrupts it, so
//    the caller must wait for `turnComplete` before responding.
//  - Omitting `turn_detection` does not disable VAD; it is on by default.
//  - A session is capped at 30 minutes server-side.
//

import Foundation

/// Events surfaced from the StepFun Realtime WebSocket.
enum StepFunRealtimeEvent {
    /// The socket is open and configured; audio and text may now be sent.
    case sessionReady

    /// A chunk of PCM16 24 kHz mono audio to play back.
    case audioChunk(Data)

    /// Streaming ASR of what the user said.
    case inputTranscript(String)

    /// Streaming transcript of what the model is saying.
    case outputTranscript(String)

    /// The model asked for a tool. Arguments are the complete JSON string once
    /// `response.function_call_arguments.done` arrives — the deltas are only
    /// useful for progress display, so this fires once, complete.
    case toolCall(callID: String, name: String, arguments: String)

    /// The response finished. Safe to send a tool result or start new input.
    case turnComplete

    /// The server began hearing the user — the cue to stop playing audio.
    case userStartedSpeaking

    /// The socket closed without the app asking. Reconnectable.
    case unexpectedDisconnect(Error)

    /// Fatal error; the client disconnects itself.
    case error(Error)
}

/// How the caller wants turn boundaries handled.
enum StepFunTurnDetection {
    /// Server decides when the user has finished speaking. Convenient, but it
    /// needs real trailing silence to fire — see `trailingSilenceRequirement`.
    case serverVAD
    /// The app decides, by calling commitAndRequestResponse(). Right for
    /// push-to-talk and for audio that ends abruptly.
    case manual
}

final class StepFunRealtimeClient {
    // MARK: - Configuration

    /// The Realtime API's required audio format. Documented nowhere in the
    /// prose; taken from the official demo's `sampleRate = 24000` and confirmed
    /// by streaming synthesized speech at this rate and getting audio back.
    static let audioSampleRate: Double = 24_000

    /// The StepFun open-platform endpoint. The Step Plan channel is deliberately
    /// not used for realtime: its realtime model did not call tools in testing.
    private static let webSocketBaseURL = "wss://api.stepfun.com/v1/realtime"

    /// Server-side cap on a single session's lifetime.
    static let maximumSessionSeconds: TimeInterval = 30 * 60

    /// Audio is appended in ~20 ms pieces. Larger chunks make server VAD lag
    /// behind real time, which shows up as the model replying late.
    private static let audioChunkMilliseconds = 20

    // MARK: - State

    private let apiKey: String
    private let model: String
    private let voice: String
    private let instructions: String
    private let tools: [[String: Any]]
    private let turnDetection: StepFunTurnDetection
    /// Mutable so a session can bind its handler after its own stored
    /// properties are initialized — a closure that captures the session cannot be
    /// passed while the session's `let client` is still being constructed.
    var eventHandler: @MainActor (StepFunRealtimeEvent) -> Void

    private let urlSession: URLSession
    private let stateLock = NSLock()
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var isConnected = false
    private var isSessionConfigured = false
    private var wasIntentionallyDisconnected = false
    /// Set once `session.updated` arrives, so sending before it is dropped
    /// rather than silently ignored by the server.
    private var isReadyForInput = false

    private var sessionStartedAt: Date?

    init(
        apiKey: String,
        model: String,
        voice: String,
        instructions: String,
        tools: [[String: Any]] = [],
        turnDetection: StepFunTurnDetection,
        eventHandler: @escaping @MainActor (StepFunRealtimeEvent) -> Void = { _ in }
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.tools = tools
        self.turnDetection = turnDetection
        self.eventHandler = eventHandler

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Connection

    func connect() async throws {
        // Scoped locking rather than bare lock()/unlock(): the latter is unavailable
        // from async contexts and only warns today — it is an error in Swift 6 mode.
        let alreadyConnected = stateLock.withLock { () -> Bool in
            if isConnected { return true }
            isConnected = true
            wasIntentionallyDisconnected = false
            return false
        }

        if alreadyConnected {
            print("[StepFunRealtime] Already connected — ignoring connect()")
            return
        }

        guard var components = URLComponents(string: Self.webSocketBaseURL) else {
            throw connectionError("Invalid WebSocket base URL")
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw connectionError("Cannot build WebSocket URL for model \(model)")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = urlSession.webSocketTask(with: request)
        stateLock.withLock { webSocketTask = task }
        task.resume()
        print("[StepFunRealtime] WebSocket opened for \(model)")

        startReceiveLoop()

        // The server's first event is `session.created`. Nothing can be sent
        // before it, and skipping the wait is how you end up streaming audio
        // into a socket that is still handshaking.
        let createdDeadline = Date().addingTimeInterval(15)
        while !isReadyForInput {
            if Date() > createdDeadline {
                disconnect()
                throw connectionError("No session.created within 15s")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func disconnect() {
        let (capturedReceiveTask, capturedWebSocketTask) = stateLock.withLock {
            let taken = (receiveLoopTask, webSocketTask)
            receiveLoopTask = nil
            webSocketTask = nil
            isConnected = false
            isSessionConfigured = false
            isReadyForInput = false
            wasIntentionallyDisconnected = true
            sessionStartedAt = nil
            return taken
        }
        capturedReceiveTask?.cancel()
        capturedWebSocketTask?.cancel(with: .normalClosure, reason: nil)
        print("[StepFunRealtime] WebSocket closed")
    }

    /// True once the 30-minute server-side session cap is close enough that a
    /// reconnect should be prepared. Callers poll this to keep a long-running
    /// assistant alive.
    func isSessionNearExpiry(within margin: TimeInterval = 120) -> Bool {
        guard let startedAt = stateLock.withLock({ sessionStartedAt }) else { return false }
        return Date().timeIntervalSince(startedAt) >= Self.maximumSessionSeconds - margin
    }

    // MARK: - Sending

    /// Stream one chunk of PCM16 24 kHz mono microphone audio.
    ///
    /// Callable from the audio tap's real-time thread: the base64 work and the
    /// WebSocket write are handed off, so this never blocks the tap.
    func sendAudioChunk(_ pcm16Data: Data) {
        guard stateLock.withLock({ isReadyForInput }) else { return }
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString(),
        ]
        Task { try? await self.sendJSON(message) }
    }

    /// Close the current user turn and ask for a spoken reply.
    ///
    /// Required in `.manual` mode. In `.serverVAD` mode the server does this
    /// itself once it hears the user stop — calling it there as well commits an
    /// empty buffer, which the server rejects.
    func commitAndRequestResponse() {
        guard stateLock.withLock({ isReadyForInput }) else { return }
        Task {
            try? await self.sendJSON(["type": "input_audio_buffer.commit"])
            try? await self.sendJSON(["type": "response.create"])
        }
    }

    /// Report the result of a tool call and ask the model to speak again.
    ///
    /// Must not be called while the model is still playing audio from the turn
    /// that requested the tool: the follow-up response would cut it off. Wait
    /// for `.turnComplete`.
    func sendToolResult(callID: String, output: String) {
        guard stateLock.withLock({ isReadyForInput }) else { return }
        Task {
            try? await self.sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output,
                ],
            ])
            try? await self.sendJSON(["type": "response.create"])
        }
    }

    /// Stop the current spoken response — the barge-in path.
    func cancelCurrentResponse() {
        guard stateLock.withLock({ isReadyForInput }) else { return }
        Task { try? await self.sendJSON(["type": "response.cancel"]) }
    }

    /// Discard buffered input audio that has not been committed yet.
    func clearInputBuffer() {
        guard stateLock.withLock({ isReadyForInput }) else { return }
        Task { try? await self.sendJSON(["type": "input_audio_buffer.clear"]) }
    }

    // MARK: - Session configuration

    private func sendSessionUpdate() {
        var session: [String: Any] = [
            "modalities": ["text", "audio"],
            "instructions": instructions,
            "voice": voice,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
        ]

        switch turnDetection {
        case .serverVAD:
            session["turn_detection"] = [
                "type": "server_vad",
                "prefix_padding_ms": 500,
                "silence_duration_ms": 100,
                "energy_awakeness_threshold": 2500,
            ]
        case .manual:
            // Omitting the field leaves VAD on — it has to be turned off
            // explicitly, which is easy to miss and produces a session that
            // both auto-commits and rejects a manual commit.
            session["turn_detection"] = NSNull()
        }

        if !tools.isEmpty {
            session["tools"] = tools
        }

        Task {
            try? await self.sendJSON(["type": "session.update", "session": session])
        }
    }

    // MARK: - Wire

    private func sendJSON(_ message: [String: Any]) async throws {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            throw connectionError("Cannot encode client event")
        }
        let task = stateLock.withLock { webSocketTask }
        guard let task else { return }
        try await task.send(.string(text))
    }

    private func startReceiveLoop() {
        let task = Task.detached { [weak self] in
            guard let self else { return }
            let webSocketTask = self.stateLock.withLock { self.webSocketTask }
            guard let webSocketTask else { return }

            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await webSocketTask.receive()
                } catch {
                    // A cancelled or closed socket is the normal way out.
                    let wasIntentional = self.stateLock.withLock { self.wasIntentionallyDisconnected }
                    if !wasIntentional {
                        await self.emit(.unexpectedDisconnect(error))
                    }
                    return
                }

                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let eventType = object["type"] as? String else { continue }

                await self.handle(eventType: eventType, payload: object)
            }
        }
        stateLock.withLock { receiveLoopTask = task }
    }

    private func handle(eventType: String, payload: [String: Any]) async {
        switch eventType {
        case "session.created":
            stateLock.withLock { sessionStartedAt = Date() }
            sendSessionUpdate()

        case "session.updated":
            stateLock.withLock {
                isSessionConfigured = true
                isReadyForInput = true
            }
            await emit(.sessionReady)

        case "response.audio.delta":
            guard let delta = payload["delta"] as? String,
                  let audioData = Data(base64Encoded: delta) else { return }
            await emit(.audioChunk(audioData))

        case "response.audio_transcript.delta":
            if let delta = payload["delta"] as? String {
                await emit(.outputTranscript(delta))
            }

        case "conversation.item.input_audio_transcription.delta":
            if let delta = payload["delta"] as? String {
                await emit(.inputTranscript(delta))
            }

        case "response.function_call_arguments.done":
            // The whole argument string arrives here in one piece. Earlier
            // runs confirmed the model reaches this only after its speech, so
            // the caller must not answer before `response.done`.
            await emit(.toolCall(
                callID: (payload["call_id"] as? String) ?? "",
                name: (payload["name"] as? String) ?? "",
                arguments: (payload["arguments"] as? String) ?? ""
            ))

        case "input_audio_buffer.speech_started":
            await emit(.userStartedSpeaking)

        case "response.done":
            await emit(.turnComplete)

        case "error":
            let error = payload["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? "unknown realtime error"
            await emit(.error(StepFunRealtimeError.serverReported(message)))

        default:
            break
        }
    }

    private func emit(_ event: StepFunRealtimeEvent) async {
        await eventHandler(event)
    }

    private func connectionError(_ message: String) -> Error {
        StepFunRealtimeError.connection(message)
    }
}

enum StepFunRealtimeError: LocalizedError {
    case connection(String)
    case serverReported(String)

    var errorDescription: String? {
        switch self {
        case .connection(let message), .serverReported(let message):
            return message
        }
    }
}
