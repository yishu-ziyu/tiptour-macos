//
//  StepFunRealtimeSession.swift
//  TipTour
//
//  Owns one live voice conversation: microphone capture, playback, and the
//  tool calls that let the voice model act on the desktop.
//
//  Full duplex: the microphone keeps streaming while the model talks. Echo is
//  removed by the system's voice-processing unit (AUVoiceIO) on the shared
//  AVAudioEngine; if it cannot be enabled the session refuses to start instead
//  of silently muting the microphone during playback. A half-duplex loop can
//  never hear a barge-in, and it dies permanently whenever a response fails to
//  complete — which is exactly how this session used to behave.
//
//  The interesting decision in this file is *when* a tool result is sent back.
//  Measurement (docs/model-research-findings.md §7) showed the model speaks
//  first and only then emits its function call, in the same turn. So a tool can
//  be executed while the model is still talking, and the result reported once
//  the turn ends — where "ends" means the speaker has actually drained, not
//  when `response.done` arrives. Sending the result earlier interrupts the
//  speech, which is the failure the StepFun documentation warns about without
//  explaining the ordering.
//
//  Turn bookkeeping lives in `StepFunTurnLifecycle`, a plain value type with no
//  AVFoundation or async state in it, so the ordering rules — a finished turn
//  must not restart itself, an interrupted turn must not report its tool
//  result — are testable without a microphone. See
//  TipTourTests/StepFunRealtimeSessionLifecycleTests.swift.
//

import AVFoundation
import Combine
import Foundation

/// Drives one tool call. Returns the text the model should be told; that text is
/// what it will speak next, so keep it short and plain.
@MainActor
protocol StepFunRealtimeToolHandling {
    func handleToolCall(name: String, argumentsJSON: String) async throws -> String
    func interrupt()
    func beginUserTurn(_ turnID: String)
}

extension StepFunRealtimeToolHandling {
    func interrupt() {}
    func beginUserTurn(_ turnID: String) {}
}

/// Everything the UI needs to render a live session.
@MainActor
final class StepFunRealtimeSessionState: ObservableObject {
    @Published var isSessionActive = false
    @Published var isConnecting = false
    @Published var lastInputTranscript = ""
    @Published var lastOutputTranscript = ""
    @Published var lastToolActivity = ""
    @Published var errorMessage: String?
    /// True while the model's voice is being played. Drives the speaking
    /// indicator, and is what makes an interruption feel responsive rather than
    /// lagging behind the audio it is cutting off.
    @Published var isModelSpeaking = false
}

/// Why the session stopped itself before the user asked it to.
enum StepFunRealtimeSessionError: LocalizedError {
    case microphoneFormatInvalid(sampleRate: Double, channelCount: AVAudioChannelCount)
    case echoCancellationUnavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .microphoneFormatInvalid(let sampleRate, let channelCount):
            return "麦克风输入格式无效（采样率 \(sampleRate)，声道 \(channelCount)），无法开始语音对话。"
        case .echoCancellationUnavailable(let reason):
            return "无法开启系统回声消除（AUVoiceIO）：\(reason)。不开启回声消除时，扬声器的声音会被当成用户说话，语音对话会陷入自我打断，因此本次会话没有开始。"
        }
    }
}

// MARK: - Turn lifecycle

/// The model-response phase of one spoken turn.
///
/// Deliberately separate from the audio engine and from async task state: these
/// are the rules that decide whether a reply has finished, whether a tool
/// result may still be sent, and what an interruption cancels.
enum StepFunTurnPhase: Equatable {
    /// Nothing from the model is in flight. The user may be mid-utterance.
    case idle
    /// Audio for a response is arriving or playing; `response.done` not seen yet.
    case awaitingResponseDone
    /// `response.done` arrived; the player queue is still draining.
    case awaitingPlaybackDrain
    /// Everything played; the pending tool result is being prepared.
    case awaitingToolResult
    /// The user interrupted before `response.done`; that completion must be
    /// ignored so the cancelled turn cannot continue itself.
    case interrupted
}

/// What the session owes after a phase transition.
enum StepFunTurnAction: Equatable {
    /// `response.done` arrived; wait for the player queue to empty before
    /// considering the turn over.
    case beginPlaybackDrain
    /// `response.done` for a response the user already interrupted; drop it.
    case ignoreTurnCompletionAfterInterrupt
    /// Playback drained and there is nothing to report; the turn is over.
    case finishTurn
    /// Playback drained, but a tool call is pending; report its result first.
    case finishTurnWithToolResult
    /// A tool call arrived for a response the user already interrupted; drop it
    /// instead of running an action the user countermanded.
    case ignoreToolCallFromInterruptedTurn
    /// The user spoke over an active response; cancel it and drop its audio.
    case interruptModelResponse
    /// The user spoke while a finishing turn was still pending; drop that
    /// turn's audio and tool result instead of letting it continue.
    case abandonCurrentTurn
    /// Nothing to do.
    case none
}

/// Pure state machine for one model turn.
///
/// The bug this replaces treated `response.done` as the end of the turn, which
/// sent the tool result while the speaker was still talking, and let a late
/// completion from an interrupted response restart a turn the user had already
/// cancelled.
struct StepFunTurnLifecycle {
    private(set) var phase: StepFunTurnPhase = .idle
    private(set) var hasPendingToolCall = false

    /// Audio is playing. Only moves forward: a chunk that arrives after
    /// `response.done` must not push the phase back and cancel the drain wait,
    /// and a chunk from a response the user already interrupted must not revive
    /// the turn they cancelled. `recordResponseCreated()` is what retires the
    /// interrupted phase.
    mutating func recordAudioChunkArrived() {
        switch phase {
        case .idle:
            phase = .awaitingResponseDone
        case .interrupted, .awaitingResponseDone, .awaitingPlaybackDrain, .awaitingToolResult:
            break
        }
    }

    /// The server started a new response. This is what retires an interrupted
    /// response: waiting forever for a cancelled response's completion is how
    /// the session would go permanently deaf.
    mutating func recordResponseCreated() {
        switch phase {
        case .idle, .interrupted:
            // A response can emit a function call before its first audio chunk.
            // Mark it in-flight here, otherwise that early tool call looks like
            // a post-drain call and starts a second response on top of this one.
            phase = .awaitingResponseDone
        case .awaitingResponseDone, .awaitingPlaybackDrain, .awaitingToolResult:
            break
        }
    }

    mutating func recordToolCallArrived() -> StepFunTurnAction {
        switch phase {
        case .interrupted:
            // The user cancelled this response before the call landed. Running
            // it would act on a request that no longer exists.
            return .ignoreToolCallFromInterruptedTurn
        case .idle, .awaitingToolResult:
            // Playback already drained for this response (or the response had
            // no audio), so there is no completion left to wait for: report the
            // result now instead of waiting for a `response.done` that came.
            hasPendingToolCall = true
            phase = .awaitingToolResult
            return .finishTurnWithToolResult
        case .awaitingResponseDone, .awaitingPlaybackDrain:
            hasPendingToolCall = true
            return .none
        }
    }

    mutating func recordResponseDoneArrived() -> StepFunTurnAction {
        switch phase {
        case .interrupted:
            phase = .idle
            return .ignoreTurnCompletionAfterInterrupt
        case .idle, .awaitingResponseDone:
            phase = .awaitingPlaybackDrain
            return .beginPlaybackDrain
        case .awaitingPlaybackDrain, .awaitingToolResult:
            // Duplicate completions must not start a second drain.
            return .none
        }
    }

    mutating func recordPlaybackDrained() -> StepFunTurnAction {
        guard phase == .awaitingPlaybackDrain else { return .none }
        guard hasPendingToolCall else {
            phase = .idle
            return .finishTurn
        }
        phase = .awaitingToolResult
        return .finishTurnWithToolResult
    }

    mutating func recordToolResultReported() {
        hasPendingToolCall = false
        if phase == .awaitingToolResult {
            phase = .idle
        }
    }

    mutating func recordUserStartedSpeaking() -> StepFunTurnAction {
        switch phase {
        case .awaitingResponseDone:
            phase = .interrupted
            hasPendingToolCall = false
            return .interruptModelResponse
        case .awaitingPlaybackDrain, .awaitingToolResult:
            phase = .idle
            hasPendingToolCall = false
            return .abandonCurrentTurn
        case .idle:
            // A tool call can be running without speech (the model called the
            // tool first). The user speaking now cancels it.
            guard hasPendingToolCall else { return .none }
            hasPendingToolCall = false
            return .abandonCurrentTurn
        case .interrupted:
            return .none
        }
    }

    mutating func reset() {
        phase = .idle
        hasPendingToolCall = false
    }
}

// MARK: - Session

@MainActor
final class StepFunRealtimeSession {
    let state = StepFunRealtimeSessionState()

    private let client: StepFunRealtimeClient
    private let toolHandler: StepFunRealtimeToolHandling

    func updateScreenContext(_ context: String) {
        client.updateScreenContext(context)
    }
    private let instructions: String

    private var audioEngine = AVAudioEngine()
    private let audioPlayer = GeminiLiveAudioPlayer()
    private let pcm16Converter: BuddyPCM16AudioConverter

    private var turnLifecycle = StepFunTurnLifecycle()
    private var pendingToolWork: Task<String, Never>?
    private var pendingToolCallID: String?
    private var pendingToolName: String?
    private var expectedSpokenReceipt: String?
    private var pendingReceiptAudioChunks: [Data] = []
    private var pendingReceiptTranscript = ""
    private var didReceiveAudioForCurrentResponse = false
    private var suppressAudioForCurrentResponse = false
    private var didTraceSuppressedAudioForCurrentResponse = false
    private var currentUserSpeechStoppedAt: Date?
    private var currentResponseCreatedAt: Date?
    private var currentTurnID = UUID().uuidString
    private var inputTurnIDs: [String: String] = [:]
    private var didRequestDesktopTaskThisUtterance = false
    /// Incremented for every tool call. A delivery task checks it before
    /// sending, so a superseded call can never report the wrong result.
    private var pendingToolCallSequence = 0
    private var toolResultDeliveryTask: Task<Void, Never>?
    private var playbackDrainTask: Task<Void, Never>?
    private var sessionLifetimeTask: Task<Void, Never>?

    /// Bumped by start() and stop(). Every continuation captures it and refuses
    /// to act once it changes, which is what stops an in-flight tool call or a
    /// drain wait from continuing a session the user has already ended.
    private var sessionRunID = 0

    private var isMicrophoneTapInstalled = false

    /// The player reports a buffer as rendered when it is consumed, but the last
    /// few milliseconds are still inside the output hardware buffer. This margin
    /// keeps the follow-up response from clipping the final syllable.
    private static let playbackTailMargin: Duration = .milliseconds(200)
    /// If the player's completion handlers never fire, continuing beats hanging
    /// the conversation forever — but say so rather than pretending it drained.
    private static let playbackDrainTimeout: Duration = .seconds(15)

    init(
        apiKey: String,
        model: String,
        voice: String,
        instructions: String,
        tools: [[String: Any]],
        turnDetection: StepFunTurnDetection,
        toolHandler: StepFunRealtimeToolHandling
    ) {
        self.toolHandler = toolHandler
        self.instructions = instructions
        self.pcm16Converter = BuddyPCM16AudioConverter(
            targetSampleRate: StepFunRealtimeClient.audioSampleRate
        )
        self.client = StepFunRealtimeClient(
            apiKey: apiKey,
            model: model,
            voice: voice,
            instructions: instructions,
            tools: tools,
            turnDetection: turnDetection
        )
        // Bound only after every stored property exists: the closure captures the
        // session, which is not fully initialized while `client` is being built.
        //
        // No Task per event: the client awaits this handler on the main actor, so
        // events are applied in the order the server sent them.
        self.client.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    #if DEBUG
    private(set) var playbackProbeSpeechStarts = 0
    private var syntheticProbeResponseCount = 0
    private var syntheticProbeAudioCapture: ((Data) -> Void)?

    struct SyntheticProbeResult {
        let timedOut: Bool
        let renderedTexts: [String]
        let audio: Data
        let error: String?
    }

    /// Exercises the production event handler, tool budget and realtime audio
    /// playback path with public synthetic PCM. Only the microphone and speaker
    /// are replaced; it cannot verify acoustic echo cancellation or listening.
    func runSyntheticProbe(audio input: Data) async throws -> SyntheticProbeResult {
        guard !state.isSessionActive, !state.isConnecting, !input.isEmpty,
              input.count.isMultiple(of: 2), input.count <= 24_000 * 2 * 30 else {
            throw DesktopTaskContractError.invalid("探针需要空闲会话和最多 30 秒的 PCM16 输入。")
        }
        var renderedTexts: [String] = []
        var capturedAudio = Data()
        syntheticProbeAudioCapture = { capturedAudio.append($0) }
        let transcriptSubscription = state.$lastOutputTranscript.dropFirst().sink {
            if !$0.isEmpty { renderedTexts.append($0) }
        }
        defer {
            syntheticProbeAudioCapture = nil
            transcriptSubscription.cancel()
        }
        sessionRunID += 1
        state.isConnecting = true
        state.errorMessage = nil
        currentTurnID = UUID().uuidString
        toolHandler.beginUserTurn(currentTurnID)
        let initialResponseCount = syntheticProbeResponseCount
        do {
            try await client.connect()
            state.isConnecting = false
            state.isSessionActive = true
            for offset in stride(from: 0, to: input.count, by: 960) {
                try Task.checkCancellation()
                client.sendAudioChunk(input.subdata(in: offset..<min(offset + 960, input.count)))
                try await Task.sleep(for: .milliseconds(20))
            }
            client.commitAndRequestResponse()
            let deadline = ContinuousClock.now + .seconds(45)
            var completed = false
            while ContinuousClock.now < deadline, state.errorMessage == nil {
                try await Task.sleep(for: .milliseconds(50))
                if syntheticProbeResponseCount > initialResponseCount, turnLifecycle.phase == .idle,
                   pendingToolWork == nil, toolResultDeliveryTask == nil {
                    completed = true
                    break
                }
            }
            let result = SyntheticProbeResult(timedOut: !completed, renderedTexts: renderedTexts,
                audio: capturedAudio, error: state.errorMessage)
            await stop()
            return result
        } catch {
            await stop()
            throw error
        }
    }

    func runPlaybackProbe() async {
        await start()
        guard state.isSessionActive else { return }
        playbackProbeSpeechStarts = 0
        let initialResponseCount = syntheticProbeResponseCount
        client.requestSpokenResponse("这是一句完整的播放检查，请保持安静，让我把这句话说完。")
        let deadline = Date().addingTimeInterval(18)
        while Date() < deadline {
            if syntheticProbeResponseCount > initialResponseCount,
               turnLifecycle.phase == .idle, !audioPlayer.isPlaying {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("[PlaybackProbe] speech starts during playback=\(playbackProbeSpeechStarts)")
        await stop()
    }
    #endif

    // MARK: - Lifecycle

    func start() async {
        guard !state.isSessionActive, !state.isConnecting else { return }
        sessionRunID += 1
        let runID = sessionRunID

        state.isConnecting = true
        state.errorMessage = nil
        state.lastInputTranscript = ""
        state.lastOutputTranscript = ""
        state.lastToolActivity = ""

        do {
            try await client.connect()
            // stop() may have run while the handshake was in flight. Its
            // disconnect may not have closed this socket: connect() can finish
            // after stop() returns, leaving a live WebSocket that no session
            // owns. Close it here instead of returning without a teardown.
            guard runID == sessionRunID else {
                client.disconnect()
                return
            }
            try startMicrophoneCapture()
            audioPlayer.startPlaying()
            state.isConnecting = false
            state.isSessionActive = true
            startSessionLifetimeGuard(runID: runID)
        } catch {
            guard runID == sessionRunID else { return }
            state.isConnecting = false
            state.isSessionActive = false
            state.errorMessage = error.localizedDescription
            await stop()
        }
    }

    func stop() async {
        sessionRunID += 1
        // Mark the session down before teardown so an event already in flight
        // takes the early-return path in handle() instead of touching a player
        // that is about to be detached.
        state.isSessionActive = false
        state.isConnecting = false

        playbackDrainTask?.cancel()
        playbackDrainTask = nil
        cancelOutstandingToolWork()
        sessionLifetimeTask?.cancel()
        sessionLifetimeTask = nil

        stopMicrophoneCapture()

        // Clear the queue before detaching: the player only resets its
        // pending-buffer counter while it is still attached, and a stale count
        // would make the next drain wait think audio was still playing.
        audioPlayer.clearQueuedAudio()
        audioPlayer.detach()

        turnLifecycle.reset()
        clearExpectedReceiptSpeech()
        state.isModelSpeaking = false
        client.disconnect()
    }

    /// Closes the user's turn and asks for a reply. Required in `.manual` mode.
    func commitTurn() {
        client.commitAndRequestResponse()
    }

    // MARK: - Microphone

    private func startMicrophoneCapture() throws {
        // A fresh engine per session is deliberate. Reusing one caches the input
        // format from the first session, so a later device or sample-rate change
        // makes installTap fault on a format mismatch. Querying the hardware each
        // time always asks for the format that is current right now.
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        // Check the raw hardware format first, so a missing or dead input device
        // is reported as a microphone problem instead of being blamed on the
        // echo canceller below.
        let hardwareInputFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareInputFormat.sampleRate > 0, hardwareInputFormat.channelCount > 0 else {
            throw StepFunRealtimeSessionError.microphoneFormatInvalid(
                sampleRate: hardwareInputFormat.sampleRate,
                channelCount: hardwareInputFormat.channelCount
            )
        }

        // This is the full-duplex requirement. Without it the model's own voice
        // re-enters the microphone, the server's VAD hears it as the user, and
        // every reply cancels itself. Muting the mic during playback instead
        // would make barge-in impossible, so an unenableable AEC is a hard,
        // visible failure rather than a silent fallback.
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            throw StepFunRealtimeSessionError.echoCancellationUnavailable(reason: error.localizedDescription)
        }
        guard inputNode.isVoiceProcessingEnabled else {
            throw StepFunRealtimeSessionError.echoCancellationUnavailable(reason: "系统报告未启用")
        }

        // Voice processing can expose a multichannel aggregate device. Request
        // a mono client format instead of averaging all aggregate channels.
        // Its input and output client formats must match (AVAudioIONode).
        // Keep Voice Processing at its device rate; convert to the provider's
        // 24kHz only after echo cancellation, in pcm16Converter below.
        let processedInputFormat = inputNode.outputFormat(forBus: 0)
        guard processedInputFormat.sampleRate > 0,
              let inputFormat = AVAudioFormat(
                standardFormatWithSampleRate: processedInputFormat.sampleRate,
                channels: 1
              ) else {
            throw StepFunRealtimeSessionError.microphoneFormatInvalid(
                sampleRate: processedInputFormat.sampleRate,
                channelCount: processedInputFormat.channelCount
            )
        }

        audioPlayer.attach(to: audioEngine)
        audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: inputFormat)
        print("[StepFunRealtimeSession] Mic input format: \(inputFormat), voice processing enabled")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Full duplex: buffers keep flowing while the model speaks. Echo
            // removal is the voice-processing unit's job; dropping audio here
            // instead would make a barge-in undetectable and would leave the
            // microphone dead for the rest of the session if a turn ever failed
            // to complete.
            guard let pcm16Data = self.pcm16Converter.convertToPCM16Data(from: buffer) else { return }
            self.client.sendAudioChunk(pcm16Data)
        }
        isMicrophoneTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        print("[StepFunRealtimeSession] Mic capture started")
        print("[StepFunRealtimeSession] Voice IO: input=\(inputNode.outputFormat(forBus: 0)), output=\(audioEngine.outputNode.inputFormat(forBus: 0)), bypassed=\(inputNode.isVoiceProcessingBypassed)")
    }

    private func stopMicrophoneCapture() {
        // Only remove a tap that was actually installed: removeTap without one
        // raises an Objective-C exception, which would turn a failed start into
        // a crash on the way out.
        if isMicrophoneTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isMicrophoneTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func startSessionLifetimeGuard(runID: Int) {
        sessionLifetimeTask?.cancel()
        sessionLifetimeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.sessionLifetimeStopAfter * 1_000_000_000))
            guard !Task.isCancelled, let self, runID == self.sessionRunID else { return }
            // Surface it as a notice rather than an error: nothing went wrong, the
            // server simply would have dropped us a minute later.
            self.state.errorMessage = "语音会话即将达到服务端上限，已安全停止。再次按下快捷键即可继续。"
            await self.stop()
        }
    }

    // MARK: - Server events

    private func handle(_ event: StepFunRealtimeEvent) {
        // Events can already be in flight when stop() runs. Acting on one after
        // teardown would touch a detached player or a cancelled tool call.
        guard state.isSessionActive || state.isConnecting else { return }

        switch event {
        case .sessionReady:
            print("[StepFunRealtimeSession] Session ready")

        case .sessionConfigured(let voiceMatchesRequest, let effectiveVoice):
            DesktopVoiceTrace.event("realtime_voice_configured", turnID: currentTurnID,
                fields: [
                    "voice_matches_request": String(voiceMatchesRequest),
                    "effective_voice_returned": String(effectiveVoice != nil)
                ])

        case .audioChunk(let pcm16Data):
            // Audio already in flight from a response the user interrupted must
            // neither play nor restart that turn. Drop it until a new
            // `response.created` retires the interrupted phase.
            guard turnLifecycle.phase != .interrupted else { return }
            turnLifecycle.recordAudioChunkArrived()
            if suppressAudioForCurrentResponse, expectedSpokenReceipt == nil {
                if !didTraceSuppressedAudioForCurrentResponse {
                    didTraceSuppressedAudioForCurrentResponse = true
                    DesktopVoiceTrace.event("tool_preamble_audio_suppressed", turnID: currentTurnID)
                }
                return
            }
            if expectedSpokenReceipt != nil {
                pendingReceiptAudioChunks.append(pcm16Data)
            } else {
                enqueueRealtimeAudio(pcm16Data)
                state.isModelSpeaking = true
            }
            if !didReceiveAudioForCurrentResponse {
                didReceiveAudioForCurrentResponse = true
                var fields = ["buffered_receipt": String(expectedSpokenReceipt != nil)]
                if let currentUserSpeechStoppedAt {
                    fields["ms_since_speech_stopped"] = String(Int(Date().timeIntervalSince(currentUserSpeechStoppedAt) * 1000))
                }
                if let currentResponseCreatedAt {
                    fields["ms_since_response_created"] = String(Int(Date().timeIntervalSince(currentResponseCreatedAt) * 1000))
                }
                DesktopVoiceTrace.event("realtime_audio_started", turnID: currentTurnID,
                    fields: fields)
            }

        case .inputTranscript(let text):
            state.lastInputTranscript += text

        case .userInputIdentity(let itemID):
            if inputTurnIDs.count >= 32 { inputTurnIDs.removeAll() }
            inputTurnIDs[itemID] = currentTurnID

        case .inputTranscriptFinal(let itemID, let text):
            let associatedTurn = inputTurnIDs[itemID]
            if associatedTurn == currentTurnID { state.lastInputTranscript = text }
            DesktopVoiceTrace.event("input_transcript_final", turnID: associatedTurn ?? "unassociated",
                fields: ["source": "provider_completed", "correlation": associatedTurn == nil ? "unavailable" : "item_id"],
                privateFields: ["transcript": text])

        case .outputTranscript(let text):
            guard turnLifecycle.phase != .interrupted else { return }
            if suppressAudioForCurrentResponse, expectedSpokenReceipt == nil { return }
            if expectedSpokenReceipt != nil {
                pendingReceiptTranscript += text
            } else {
                state.lastOutputTranscript += text
            }

        case .outputTranscriptFinal(let text):
            guard turnLifecycle.phase != .interrupted else { return }
            if suppressAudioForCurrentResponse, expectedSpokenReceipt == nil { return }
            if expectedSpokenReceipt != nil {
                pendingReceiptTranscript = text
            } else {
                state.lastOutputTranscript = text
            }

        case .responseCreated:
            #if DEBUG
            syntheticProbeResponseCount += 1
            #endif
            print("[StepFunRealtimeSession] response created, phase=\(turnLifecycle.phase)")
            didReceiveAudioForCurrentResponse = false
            suppressAudioForCurrentResponse = false
            didTraceSuppressedAudioForCurrentResponse = false
            currentResponseCreatedAt = Date()
            turnLifecycle.recordResponseCreated()
            DesktopVoiceTrace.event("response_created", turnID: currentTurnID)

        case .toolCall(let callID, let name, let argumentsJSON):
            startToolWork(callID: callID, name: name, argumentsJSON: argumentsJSON)

        case .turnComplete:
            print("[StepFunRealtimeSession] response done, queued=\(audioPlayer.pendingBufferCount)")
            handleResponseDone()

        case .userStartedSpeaking:
            #if DEBUG
            playbackProbeSpeechStarts += 1
            #endif
            didRequestDesktopTaskThisUtterance = false
            print("[StepFunRealtimeSession] speech started, phase=\(turnLifecycle.phase), queued=\(audioPlayer.pendingBufferCount)")
            handleUserStartedSpeaking()
            currentTurnID = UUID().uuidString
            state.lastInputTranscript = ""
            currentUserSpeechStoppedAt = nil
            currentResponseCreatedAt = nil
            toolHandler.beginUserTurn(currentTurnID)
            DesktopVoiceTrace.event("user_turn_started", turnID: currentTurnID)

        case .userStoppedSpeaking:
            currentUserSpeechStoppedAt = Date()
            DesktopVoiceTrace.event("user_speech_stopped", turnID: currentTurnID)

        case .responseAborted:
            clearExpectedReceiptSpeech()
            audioPlayer.clearQueuedAudio()
            playbackDrainTask?.cancel()
            playbackDrainTask = nil
            cancelOutstandingToolWork()
            turnLifecycle.reset()
            state.isModelSpeaking = false
            DesktopVoiceTrace.event("response_aborted", turnID: currentTurnID)

        case .unexpectedDisconnect(let error):
            state.errorMessage = "Voice connection dropped: \(error.localizedDescription)"
            Task { await self.stop() }

        case .error(let error):
            state.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Turn handling

    private func startToolWork(callID: String, name: String, argumentsJSON: String) {
        let repeatedDesktopTask = name == "act_on_screen" && didRequestDesktopTaskThisUtterance
        // Reject additional model calls without cancelling or replacing the
        // first accepted task. Only a user interruption can supersede it.
        if repeatedDesktopTask || pendingToolWork != nil {
            client.sendToolResult(callID: callID, output: "本轮已有工具任务，未执行这个追加调用；请使用首个任务的真实结果。", requestResponse: false)
            DesktopVoiceTrace.event("tool_rejected", turnID: currentTurnID, fields: ["tool": name, "reason": "duplicate_or_busy"])
            return
        }
        let lifecycleAction = turnLifecycle.recordToolCallArrived()
        guard lifecycleAction != .ignoreToolCallFromInterruptedTurn else {
            print("[StepFunRealtimeSession] dropping a tool call from an interrupted turn")
            return
        }
        state.lastToolActivity = name == "describe_screen" ? "读取屏幕" : "处理桌面任务"
        if name == "act_on_screen" { didRequestDesktopTaskThisUtterance = true }

        // The model may start a spoken preamble around the same time as its
        // function call. Once a real tool call exists, that preamble is both
        // redundant and the main source of overlapping/voice-shifting replies.
        // Stop anything already queued and suppress later audio from THIS
        // response. The verified receipt gets its own next response.
        suppressAudioForCurrentResponse = true
        if audioPlayer.pendingBufferCount > 0 || state.isModelSpeaking {
            audioPlayer.clearQueuedAudio()
            state.isModelSpeaking = false
        }
        DesktopVoiceTrace.event("tool_response_audio_suppression_enabled", turnID: currentTurnID,
            fields: ["tool": name])

        pendingToolCallSequence += 1
        let toolHandler = self.toolHandler
        let work = Task {
            do {
                return try await toolHandler.handleToolCall(name: name, argumentsJSON: argumentsJSON)
            } catch {
                return "Action failed: \(error.localizedDescription)"
            }
        }
        pendingToolWork = work
        pendingToolCallID = callID
        pendingToolName = name
        DesktopVoiceTrace.event("tool_requested", turnID: currentTurnID,
            fields: ["tool": name, "call_id": callID, "transcript_status": state.lastInputTranscript.isEmpty ? "unavailable" : "partial_or_final"],
            privateFields: ["arguments": argumentsJSON, "input_transcript": state.lastInputTranscript])
        print("[StepFunRealtimeSession] tool call \(name) started")

        // Playback has already drained, so the result can go back now rather
        // than waiting for a completion that has already arrived.
        if lifecycleAction == .finishTurnWithToolResult {
            deliverPendingToolResult(runID: sessionRunID)
        }
    }

    private func handleResponseDone() {
        finalizeExpectedReceiptSpeech()
        switch turnLifecycle.recordResponseDoneArrived() {
        case .beginPlaybackDrain:
            startPlaybackDrainWait(runID: sessionRunID)
        case .ignoreTurnCompletionAfterInterrupt:
            // The user already cancelled this response; its late completion must
            // not start a drain wait or report a tool result.
            break
        default:
            break
        }
    }

    private func enqueueRealtimeAudio(_ pcm16Data: Data) {
        #if DEBUG
        if let syntheticProbeAudioCapture {
            syntheticProbeAudioCapture(pcm16Data)
            return
        }
        #endif
        audioPlayer.enqueueAudioChunk(pcm16Data)
    }

    /// Action receipts are generated by program state, not by the model. The
    /// realtime model may voice one only when its own transcript still matches
    /// that receipt; otherwise the audio is discarded and the exact text stays
    /// visible in the panel.
    private func finalizeExpectedReceiptSpeech() {
        guard let expectedSpokenReceipt else { return }
        let audioChunks = pendingReceiptAudioChunks
        let transcript = pendingReceiptTranscript
        clearExpectedReceiptSpeech()
        state.lastOutputTranscript = expectedSpokenReceipt

        guard !audioChunks.isEmpty,
              StepFunVerifiedReceiptSpeech.matches(
                expected: expectedSpokenReceipt,
                transcript: transcript
              ) else {
            state.errorMessage = "Realtime 未按已验证回执原样播报，本次已停止播放。"
            DesktopVoiceTrace.event("receipt_audio_rejected", turnID: currentTurnID,
                fields: ["has_audio": String(!audioChunks.isEmpty)],
                privateFields: ["expected": expectedSpokenReceipt, "transcript": transcript])
            return
        }

        for audioChunk in audioChunks {
            enqueueRealtimeAudio(audioChunk)
        }
        state.isModelSpeaking = true
        DesktopVoiceTrace.event("receipt_audio_accepted", turnID: currentTurnID,
            fields: ["chunk_count": String(audioChunks.count)])
    }

    private func clearExpectedReceiptSpeech() {
        expectedSpokenReceipt = nil
        pendingReceiptAudioChunks.removeAll(keepingCapacity: true)
        pendingReceiptTranscript = ""
    }

    /// Wait for the player to actually finish before letting the turn end.
    ///
    /// `response.done` only says the server stopped generating. The player can
    /// still hold most of a sentence, and reporting a tool result or asking for
    /// a follow-up response at that moment clips it off.
    private func startPlaybackDrainWait(runID: Int) {
        playbackDrainTask?.cancel()
        playbackDrainTask = Task { [weak self] in
            guard let self else { return }
            let hadPlayback = self.audioPlayer.isPlaying
            let drainDeadline = ContinuousClock.now + Self.playbackDrainTimeout
            while !Task.isCancelled && self.audioPlayer.isPlaying && ContinuousClock.now < drainDeadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard !Task.isCancelled, runID == self.sessionRunID else { return }
            if self.audioPlayer.isPlaying {
                print("[StepFunRealtimeSession] ⚠ playback drain timed out with \(self.audioPlayer.pendingBufferCount) buffers still queued")
                self.audioPlayer.clearQueuedAudio()
                DesktopVoiceTrace.event("playback_timeout", turnID: self.currentTurnID)
            }

            // The queue is empty, but the last buffer may still be in the output
            // hardware buffer.
            if hadPlayback { try? await Task.sleep(for: Self.playbackTailMargin) }

            guard !Task.isCancelled, runID == self.sessionRunID else { return }
            self.handlePlaybackDrained(runID: runID)
        }
    }

    private func handlePlaybackDrained(runID: Int) {
        state.isModelSpeaking = false
        DesktopVoiceTrace.event("playback_drain_finished", turnID: currentTurnID,
            fields: ["queued_buffers": String(audioPlayer.pendingBufferCount)])

        switch turnLifecycle.recordPlaybackDrained() {
        case .finishTurn:
            resetTurnTranscripts()
        case .finishTurnWithToolResult:
            deliverPendingToolResult(runID: runID)
        default:
            break
        }
    }

    private func deliverPendingToolResult(runID: Int) {
        guard let toolWork = pendingToolWork, let callID = pendingToolCallID else {
            // The call disappeared between the drain and here — an interruption
            // cancelled it. There is nothing to report and the turn is over.
            turnLifecycle.recordToolResultReported()
            resetTurnTranscripts()
            return
        }
        let callSequence = pendingToolCallSequence

        toolResultDeliveryTask?.cancel()
        toolResultDeliveryTask = Task { [weak self] in
            let output = await toolWork.value
            // Checked with no await in between, so nothing can start an
            // interruption or a new session between here and the send.
            guard let self, !Task.isCancelled, runID == self.sessionRunID,
                  callSequence == self.pendingToolCallSequence,
                  self.turnLifecycle.phase == .awaitingToolResult else { return }

            let isActionResult = self.pendingToolName == "act_on_screen"
            let receipt = isActionResult
                ? try? JSONDecoder().decode(DesktopTaskReceipt.self, from: Data(output.utf8))
                : nil
            let exactSpokenResponse = isActionResult
                ? receipt?.spokenSummary ?? "本次执行结果无法确认，不能报告完成。"
                : nil
            if let exactSpokenResponse {
                self.clearExpectedReceiptSpeech()
                self.expectedSpokenReceipt = exactSpokenResponse
            }
            self.client.sendToolResult(callID: callID, output: output,
                exactSpokenResponse: exactSpokenResponse)
            print("[StepFunRealtimeSession] tool result submitted, characters=\(output.count)")
            DesktopVoiceTrace.event("tool_result_submitted", turnID: self.currentTurnID,
                fields: ["call_id": callID, "action_result": String(isActionResult)], privateFields: ["result": output])
            self.turnLifecycle.recordToolResultReported()
            self.pendingToolWork = nil
            self.pendingToolCallID = nil
            self.pendingToolName = nil
            self.toolResultDeliveryTask = nil
            self.resetTurnTranscripts()
            if let exactSpokenResponse {
                DesktopVoiceTrace.event("receipt_audio_requested", turnID: self.currentTurnID,
                    fields: ["source": "realtime", "status": receipt?.status ?? "unreadable"],
                    privateFields: ["text": exactSpokenResponse])
            }
        }
    }

    private func handleUserStartedSpeaking() {
        clearExpectedReceiptSpeech()
        switch turnLifecycle.recordUserStartedSpeaking() {
        case .interruptModelResponse:
            // The user talked over the model. Stop the local playback first so
            // the interruption feels immediate, then tell the server to stop
            // generating. Tool work from the interrupted turn is abandoned:
            // acting after the user has countermanded the request is worse than
            // not acting.
            state.isModelSpeaking = false
            audioPlayer.clearQueuedAudio()
            playbackDrainTask?.cancel()
            playbackDrainTask = nil
            cancelOutstandingToolWork()
            client.cancelCurrentResponse()
            print("[StepFunRealtimeSession] barge-in: cancelled the model response")

        case .abandonCurrentTurn:
            // The response had already finished generating, so there is nothing
            // to cancel server-side — but its audio and tool result must not
            // continue.
            state.isModelSpeaking = false
            audioPlayer.clearQueuedAudio()
            playbackDrainTask?.cancel()
            playbackDrainTask = nil
            cancelOutstandingToolWork()
            print("[StepFunRealtimeSession] barge-in: abandoned the finishing turn")

        default:
            break
        }
    }

    private func cancelOutstandingToolWork() {
        toolHandler.interrupt()
        pendingToolWork?.cancel()
        pendingToolWork = nil
        pendingToolCallID = nil
        pendingToolName = nil
        // Retire the sequence so a delivery task already awaiting the old work
        // cannot send its result after the interruption.
        pendingToolCallSequence += 1
        toolResultDeliveryTask?.cancel()
        toolResultDeliveryTask = nil
    }

    private func resetTurnTranscripts() {
        state.lastInputTranscript = ""
        state.lastOutputTranscript = ""
    }

    /// Stops the session before the server's own 30-minute cap fires.
    ///
    /// Deliberately not a reconnect. A fresh socket loses the conversation
    /// history and any in-flight tool call, so silently re-establishing one would
    /// resume a task whose context is gone — and could repeat an action the user
    /// has already seen. Stopping and saying so keeps the user in control of what
    /// happens next.
    private static let sessionLifetimeStopAfter: TimeInterval = 29 * 60
}

// MARK: - Locking helper

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
