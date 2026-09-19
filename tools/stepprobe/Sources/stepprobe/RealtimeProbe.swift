//
//  RealtimeProbe.swift
//  stepprobe
//
//  Exercises the StepFun Realtime WebSocket end to end: session setup, streamed
//  speech input, tool calling, and interruption. It exists because the
//  documentation contradicts itself about how function calls surface — the
//  event reference says output items only support `message`, while the tool
//  call walkthrough shows `type: "function_call"` — and that contradiction has
//  to be settled by observation, not by reading.
//

import Foundation

/// Which StepFun route to dial. The two bill different accounts and offer
/// different realtime models.
enum RealtimeRoute: String {
    case openPlatform = "open"
    case stepPlan = "plan"

    var webSocketBaseURL: String {
        switch self {
        case .openPlatform:
            return "wss://api.stepfun.com/v1/realtime"
        case .stepPlan:
            return "wss://api.stepfun.com/step_plan/v1/realtime"
        }
    }
}

struct RealtimeProbeConfiguration {
    var route: RealtimeRoute
    var model: String
    var voice: String
    var instructions: String
    /// Spoken text rendered locally and streamed as the user's turn.
    var spokenText: String
    var chunkMilliseconds: Int
    var secondsToListenAfterStreaming: Double
    /// Declared as a `function` tool so the tool-call path is exercised.
    var declaresTool: Bool
    /// Server VAD off requires a manual `input_audio_buffer.commit` +
    /// `response.create`; on, the server commits and responds by itself. The
    /// first probe run proved this empirically: without it, audio was accepted
    /// and transcribed but never produced a response.
    var serverVAD: Bool
}

struct RealtimeEventRecord {
    var eventType: String
    var millisecondsSinceStart: Int
    var summary: String
}

struct RealtimeProbeResult {
    var route: RealtimeRoute
    var model: String
    var spokenDurationSeconds: Double
    var events: [RealtimeEventRecord]
    var firstAudioMilliseconds: Int?
    var firstTranscriptMilliseconds: Int?
    var functionCallArguments: [(callID: String, name: String, arguments: String)]
    var audioDeltaCount: Int
    var audioBytesReceived: Int
    var assistantTranscript: String
}

struct RealtimeProbe {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func run(_ configuration: RealtimeProbeConfiguration) async throws -> RealtimeProbeResult {
        let speech = try SpeechSynthesizer().synthesize(configuration.spokenText)
        let spokenSeconds = String(format: "%.2f", speech.durationSeconds)
        print("""
          synthesized \(spokenSeconds)s of speech (\(speech.pcm16Data.count) bytes, \(Int(speech.sampleRate)) Hz mono PCM16) — \
          streaming in \(configuration.chunkMilliseconds)ms chunks

        """)

        var components = URLComponents(string: configuration.route.webSocketBaseURL)!
        components.queryItems = [URLQueryItem(name: "model", value: configuration.model)]
        guard let url = components.url else {
            throw ProbeError.usage("cannot build WebSocket URL from \(configuration.route.webSocketBaseURL)")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let session = URLSession(configuration: .default)
        let webSocketTask = session.webSocketTask(with: request)
        webSocketTask.resume()

        let collector = RealtimeEventCollector()
        let startedAt = DispatchTime.now()
        let receiveTask = Task.detached {
            await collector.receiveLoop(from: webSocketTask, startedAt: startedAt)
        }

        // Wait for the server's opening event before configuring anything.
        try await collector.waitForEvent(ofType: "session.created", timeoutSeconds: 15)

        try await send(webSocketTask, sessionUpdate(configuration))
        try await collector.waitForEvent(ofType: "session.updated", timeoutSeconds: 15)
        print("  session configured (voice=\(configuration.voice), tools=\(configuration.declaresTool ? "1 function" : "none"))")

        let chunks = SpeechSynthesizer().chunkForStreaming(speech.pcm16Data, chunkMilliseconds: configuration.chunkMilliseconds)
        print("  streaming \(chunks.count) audio chunks…")
        for chunk in chunks {
            try await send(webSocketTask, ["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])
            // Pace the stream at roughly real time so server VAD sees a natural cadence.
            try await Task.sleep(nanoseconds: UInt64(configuration.chunkMilliseconds) * 1_000_000)
        }
        print("  finished streaming; listening for \(String(format: "%.0f", configuration.secondsToListenAfterStreaming))s…")

        // Without server VAD the turn never closes on its own: the buffer is
        // transcribed but never committed, so no response is ever created. The
        // documented manual path is commit, then create.
        if !configuration.serverVAD {
            try await send(webSocketTask, ["type": "input_audio_buffer.commit"])
            try await send(webSocketTask, ["type": "response.create"])
            print("  sent input_audio_buffer.commit + response.create")
        }

        // Wait for the first response to finish before touching the conversation:
        // the model speaks first and emits its function call afterwards, so a
        // premature result would collide with the speech that is still playing.
        try await collector.waitForEvent(ofType: "response.done", timeoutSeconds: configuration.secondsToListenAfterStreaming)

        // Close the product loop once: execute a stubbed tool, report the result,
        // and ask for a follow-up response. This is the sequence the desktop
        // control flow depends on, so it is measured rather than assumed.
        let toolCalls = await collector.functionCallArguments()
        if let toolCall = toolCalls.first {
            print("  closing the loop: returning a result for `\(toolCall.name)`")
            let simulatedToolResult = "屏幕上有访达窗口，左侧边栏，右侧文件列表，顶部工具栏。"
            try await send(webSocketTask, [
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": toolCall.callID,
                    "output": simulatedToolResult,
                ],
            ])
            try await send(webSocketTask, ["type": "response.create"])
            try await collector.waitForEvent(ofType: "response.done", timeoutSeconds: 30)
            print("  follow-up response received")
        } else {
            print("  no function call was emitted, so no follow-up was requested")
        }

        try await Task.sleep(nanoseconds: UInt64(configuration.secondsToListenAfterStreaming * 1_000_000_000))

        webSocketTask.cancel(with: .goingAway, reason: nil)
        receiveTask.cancel()

        let events = await collector.snapshot()
        return RealtimeProbeResult(
            route: configuration.route,
            model: configuration.model,
            spokenDurationSeconds: speech.durationSeconds,
            events: events,
            firstAudioMilliseconds: events.first(where: { $0.eventType == "response.audio.delta" })?.millisecondsSinceStart,
            firstTranscriptMilliseconds: events.first(where: { $0.eventType == "response.audio_transcript.delta" })?.millisecondsSinceStart,
            functionCallArguments: await collector.functionCallArguments(),
            audioDeltaCount: events.filter { $0.eventType == "response.audio.delta" }.count,
            audioBytesReceived: await collector.audioBytesReceived(),
            assistantTranscript: await collector.assistantTranscript()
        )
    }

    // MARK: Client events

    private func sessionUpdate(_ configuration: RealtimeProbeConfiguration) -> [String: Any] {
        var session: [String: Any] = [
            "modalities": ["text", "audio"],
            "instructions": configuration.instructions,
            "voice": configuration.voice,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
        ]

        if !configuration.serverVAD {
            // Omitting the field is not enough: VAD is on by default and has to
            // be switched off explicitly.
            session["turn_detection"] = NSNull()
        } else {
            session["turn_detection"] = [
                "type": "server_vad",
                "prefix_padding_ms": 500,
                "silence_duration_ms": 100,
                "energy_awakeness_threshold": 2500,
            ]
        }

        if configuration.declaresTool {
            // A deliberately mundane tool: it lets us confirm the shape of the
            // function-call events without depending on the model choosing to
            // act on anything risky.
            session["tools"] = [[
                "type": "function",
                "function": [
                    "name": "report_screen_summary",
                    "description": "Report what is currently visible on the user's screen in one short sentence.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "summary": ["type": "string", "description": "One short sentence about what is on screen."],
                        ],
                        "required": ["summary"],
                    ],
                ],
            ]]
        }

        return ["type": "session.update", "session": session]
    }

    private func send(_ task: URLSessionWebSocketTask, _ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProbeError.malformedResponse("cannot encode client event")
        }
        try await task.send(.string(text))
    }
}

// MARK: - Event collection

/// Collects server events off the receive loop. A reference type because the
/// receive loop and the reporting code touch it from different tasks.
private final class RealtimeEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RealtimeEventRecord] = []
    private var accumulatedTranscript = ""
    private var audioBytes = 0
    private var toolCalls: [(callID: String, name: String, arguments: String)] = []

    func receiveLoop(from task: URLSessionWebSocketTask, startedAt: DispatchTime) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // A cancelled or closed socket is the normal exit for this probe.
                return
            }
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = object["type"] as? String else { continue }

            let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
            record(eventType: eventType, elapsedMilliseconds: elapsedMilliseconds, payload: object)
        }
    }

    private func record(eventType: String, elapsedMilliseconds: Int, payload: [String: Any]) {
        var summary = ""
        switch eventType {
        case "response.audio.delta":
            if let delta = payload["delta"] as? String {
                let bytes = Data(base64Encoded: delta)?.count ?? 0
                lock.withLock { audioBytes += bytes }
                summary = "\(bytes) bytes"
            }
        case "response.audio_transcript.delta":
            if let delta = payload["delta"] as? String {
                lock.withLock { accumulatedTranscript += delta }
                summary = delta
            }
        case "response.function_call_arguments.delta":
            summary = (payload["arguments"] as? String) ?? ""
        case "response.function_call_arguments.done":
            let arguments = (payload["arguments"] as? String) ?? ""
            let callID = (payload["call_id"] as? String) ?? "?"
            let name = (payload["name"] as? String) ?? "?"
            lock.withLock { toolCalls.append((callID, name, arguments)) }
            summary = "\(name)(\(arguments))"
        case "error":
            let error = payload["error"] as? [String: Any]
            summary = (error?["message"] as? String) ?? (error?["code"] as? String) ?? "unknown"
        default:
            break
        }

        let record = RealtimeEventRecord(
            eventType: eventType,
            millisecondsSinceStart: elapsedMilliseconds,
            summary: summary.prefix(120).description
        )
        lock.withLock { events.append(record) }
        print("    [\(String(format: "%6d", elapsedMilliseconds)) ms] \(eventType)\(summary.isEmpty ? "" : "  \(record.summary)")")
    }

    func waitForEvent(ofType eventType: String, timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if hasReceived(eventType) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ProbeError.malformedResponse("timed out after \(Int(timeoutSeconds))s waiting for `\(eventType)`")
    }

    private func hasReceived(_ eventType: String) -> Bool {
        lock.withLock { events.contains { $0.eventType == eventType } }
    }

    func snapshot() -> [RealtimeEventRecord] {
        lock.withLock { events }
    }

    func functionCallArguments() -> [(callID: String, name: String, arguments: String)] {
        lock.withLock { toolCalls }
    }

    func audioBytesReceived() -> Int {
        lock.withLock { audioBytes }
    }

    func assistantTranscript() -> String {
        lock.withLock { accumulatedTranscript }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
