//
//  StepFunRealtimeSession.swift
//  TipTour
//
//  Owns one live voice conversation: microphone capture, playback, and the
//  tool calls that let the voice model act on the desktop.
//
//  The interesting decision in this file is *when* a tool result is sent back.
//  Measurement (docs/model-research-findings.md §7) showed the model speaks
//  first and only then emits its function call, in the same turn. So a tool can
//  be executed while the model is still talking, and the result reported once
//  the turn ends. That hides the perceive-and-decide latency — local detection
//  plus a Jev round trip — behind speech the user is already listening to,
//  instead of adding it on top.
//
//  Sending the result earlier would interrupt the speech, which is the failure
//  the StepFun documentation warns about without explaining the ordering.
//

import AVFoundation
import Combine
import Foundation

/// Drives one tool call. Returns the text the model should be told; that text is
/// what it will speak next, so keep it short and plain.
@MainActor
protocol StepFunRealtimeToolHandling {
    func handleToolCall(name: String, argumentsJSON: String) async throws -> String
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
}

@MainActor
final class StepFunRealtimeSession {
    let state = StepFunRealtimeSessionState()

    private let client: StepFunRealtimeClient
    private let toolHandler: StepFunRealtimeToolHandling
    private let instructions: String

    private var audioEngine = AVAudioEngine()
    private var audioPlayer = GeminiLiveAudioPlayer()
    private let pcm16Converter: BuddyPCM16AudioConverter

    /// The tool call that is currently executing, so its result can be reported
    /// the moment the model finishes speaking.
    private var pendingToolWork: Task<String, Never>?

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
        self.client.eventHandler = { [weak self] event in
            Task { await self?.handle(event) }
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !state.isSessionActive, !state.isConnecting else { return }
        state.isConnecting = true
        state.errorMessage = nil
        state.lastInputTranscript = ""
        state.lastOutputTranscript = ""
        state.lastToolActivity = ""

        do {
            try await client.connect()
            try startMicrophoneCapture()
            audioPlayer.startPlaying()
            state.isConnecting = false
            state.isSessionActive = true
        } catch {
            state.isConnecting = false
            state.isSessionActive = false
            state.errorMessage = error.localizedDescription
            await stop()
        }
    }

    func stop() async {
        stopMicrophoneCapture()
        audioPlayer.detach()
        audioPlayer.clearQueuedAudio()
        pendingToolWork?.cancel()
        pendingToolWork = nil
        client.disconnect()
        state.isSessionActive = false
        state.isConnecting = false
    }

    /// Barge-in: the user started talking over the model.
    ///
    /// Stopping the audio is only half of it. Tool work that has been started but
    /// not yet executed must be abandoned too — otherwise the desktop carries out
    /// an action the user has just verbally countermanded. Whatever was already
    /// executed cannot be undone, which is why actions are single-step.
    private func beginBargeIn() {
        audioPlayer.clearQueuedAudio()
        client.cancelCurrentResponse()
        if let pendingToolWork {
            pendingToolWork.cancel()
            print("[StepFunRealtimeSession] barge-in abandoned an in-flight tool call")
        }
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
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "StepFunRealtimeSession",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone format is invalid — sample rate \(inputFormat.sampleRate), channels \(inputFormat.channelCount)"]
            )
        }
        print("[StepFunRealtimeSession] Mic input format: \(inputFormat)")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Converted on the audio thread and handed straight to the socket.
            // Hopping to the main actor here would stall the tap.
            guard let pcm16Data = self.pcm16Converter.convertToPCM16Data(from: buffer) else { return }
            self.client.sendAudioChunk(pcm16Data)
        }

        // The player shares the engine that captures the microphone. Without this
        // the engine has no player node, so startPlaying() succeeds and nothing is
        // ever audible — the whole voice loop appears to work while silent.
        audioPlayer.attach(to: audioEngine)

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopMicrophoneCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    // MARK: - Events

    private func handle(_ event: StepFunRealtimeEvent) async {
        switch event {
        case .sessionReady:
            print("[StepFunRealtimeSession] Session ready")

        case .audioChunk(let pcm16Data):
            audioPlayer.enqueueAudioChunk(pcm16Data)

        case .inputTranscript(let text):
            state.lastInputTranscript += text

        case .outputTranscript(let text):
            state.lastOutputTranscript += text

        case .userStartedSpeaking:
            beginBargeIn()

        case .toolCall(let callID, let name, let argumentsJSON):
            // Start the work now so it overlaps the speech already in progress.
            state.lastToolActivity = "\(name)"
            let toolHandler = self.toolHandler
            pendingToolWork = Task.detached(priority: .userInitiated) {
                do {
                    return try await toolHandler.handleToolCall(name: name, argumentsJSON: argumentsJSON)
                } catch {
                    return "Action failed: \(error.localizedDescription)"
                }
            }
            self.pendingCallID = callID

        case .turnComplete:
            // The speech is over. Now it is safe to report the result.
            guard let pendingToolWork else { return }
            self.pendingToolWork = nil

            if pendingToolWork.isCancelled {
                // The user interrupted while the action was in flight. Say so
                // plainly rather than reporting an outcome that will not happen;
                // the model needs *some* output to close the call.
                client.sendToolResult(callID: pendingCallID ?? "", output: "已停止：用户中断了操作。")
            } else {
                let output = await pendingToolWork.value
                client.sendToolResult(callID: pendingCallID ?? "", output: output)
            }
            pendingCallID = nil
            state.lastInputTranscript = ""
            state.lastOutputTranscript = ""

        case .unexpectedDisconnect(let error):
            state.errorMessage = "Voice connection dropped: \(error.localizedDescription)"
            await stop()

        case .error(let error):
            state.errorMessage = error.localizedDescription
        }
    }

    private var pendingCallID: String?
}
