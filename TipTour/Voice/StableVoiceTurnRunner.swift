//
//  StableVoiceTurnRunner.swift
//  TipTour
//
//  One spoken turn in the 「声音稳定」 voice style: hold the shortcut to talk,
//  let go, and the utterance goes to speech-to-text, then her reply, then
//  speech. Holding the shortcut again while she thinks or speaks stops her.
//  Audio capture and playback are passed in, so the turn logic runs without
//  a microphone.
//

import Combine
import Foundation

/// How long each part of a turn took, measured from the moment the user let go.
nonisolated struct StableVoiceTiming: Equatable, Sendable {
    var transcribedAfter: TimeInterval?
    var repliedAfter: TimeInterval?
    var firstAudioAfter: TimeInterval?
    var finishedAfter: TimeInterval?
    var outcome = "running"

    var fields: [String: String] {
        func milliseconds(_ interval: TimeInterval?) -> String { interval.map { String(Int(($0 * 1000).rounded())) } ?? "" }
        return ["transcribed_ms": milliseconds(transcribedAfter), "replied_ms": milliseconds(repliedAfter),
                "first_audio_ms": milliseconds(firstAudioAfter), "finished_ms": milliseconds(finishedAfter),
                "outcome": outcome]
    }
}

@MainActor
final class StableVoiceTurnRunner: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    struct Services: Sendable {
        var transcribe: @Sendable (Data) async throws -> String
        var reply: @Sendable (String, String?) async throws -> StableVoiceReply
        var speak: @Sendable (String, @escaping @Sendable (Data) async -> Void) async throws -> Void
        /// Opens the network connections while the user is still talking:
        /// on this Mac a fresh TLS handshake alone took 0.4–6 s per provider.
        var warmUp: @Sendable () async -> Void = {}
    }

    /// Where her audio goes. `isPlaying` is true until the last queued chunk
    /// has been heard, not just handed over.
    struct Playback {
        var enqueue: (Data) -> Void
        var clear: () -> Void
        var isPlaying: () -> Bool
    }

    /// Shorter than this (0.3 s of 16 kHz PCM16) is a tap, not speech.
    static let minimumUtteranceBytes = 9_600

    @Published private(set) var phase: Phase = .idle
    /// What the speech-to-text heard in the latest turn.
    @Published private(set) var heard: String?
    /// What she said in the latest turn.
    @Published private(set) var said: String?
    /// Why the latest turn ended without her answer; nil when it did not fail.
    @Published private(set) var failure: String?

    var companionContext: () -> String? = { nil }
    /// Called before she speaks, so a name she says has already been saved.
    var onNames: (_ companionName: String?, _ userAddress: String?) -> Void = { _, _ in }
    var onTurnFinished: (StableVoiceTiming) -> Void = { _ in }

    private let services: Services
    private let playback: Playback
    private let clock: () -> Date
    private var turnID = UUID()
    private var turnTask: Task<Void, Never>?

    init(services: Services, playback: Playback, clock: @escaping () -> Date = Date.init) {
        self.services = services
        self.playback = playback
        self.clock = clock
    }

    /// The shortcut went down. Whatever she was doing stops.
    func beginListening() {
        stopTurn(outcome: "interrupted")
        failure = nil
        phase = .listening
        let warmUp = services.warmUp
        Task.detached(priority: .userInitiated) { await warmUp() }
    }

    /// The shortcut came up with what the microphone recorded.
    func finishListening(audio: Data) {
        guard phase == .listening else { return }
        guard audio.count >= Self.minimumUtteranceBytes else {
            phase = .idle
            failure = "太短了：按住 ⌃⌥ 说完再松手。"
            return
        }
        let id = UUID()
        turnID = id
        let released = clock()
        phase = .thinking
        turnTask = Task { [weak self] in await self?.run(audio: audio, id: id, released: released) }
    }

    /// Stop without starting to listen (the session or the voice style ended).
    func interrupt() {
        stopTurn(outcome: "stopped")
        phase = .idle
    }

    private func stopTurn(outcome: String) {
        guard turnTask != nil || phase == .speaking || phase == .thinking else { return }
        turnID = UUID()
        turnTask?.cancel()
        turnTask = nil
        playback.clear()
        timing.outcome = outcome
        if timing.finishedAfter == nil, let turnStarted { timing.finishedAfter = clock().timeIntervalSince(turnStarted) }
        if turnStarted != nil { onTurnFinished(timing) }
        turnStarted = nil
    }

    private var timing = StableVoiceTiming()
    private var turnStarted: Date?

    private func run(audio: Data, id: UUID, released: Date) async {
        timing = StableVoiceTiming()
        turnStarted = released
        func elapsed() -> TimeInterval { clock().timeIntervalSince(released) }
        do {
            let text = try await services.transcribe(audio)
            guard turnID == id else { return }
            timing.transcribedAfter = elapsed()
            guard !text.isEmpty else { return end(id: id, outcome: "nothing_heard", failure: "没听清，再说一次。") }
            heard = text

            let reply = try await services.reply(text, companionContext())
            guard turnID == id else { return }
            timing.repliedAfter = elapsed()
            onNames(reply.companionName, reply.userAddress)
            said = reply.say
            phase = .speaking

            try await services.speak(reply.say) { [weak self] chunk in
                await self?.play(chunk, turn: id, released: released)
            }
            while turnID == id, playback.isPlaying() {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard turnID == id else { return }
            end(id: id, outcome: "spoken", failure: nil)
        } catch {
            guard turnID == id, !(error is CancellationError) else { return }
            end(id: id, outcome: "failed", failure: Self.message(for: error))
        }
    }

    private func play(_ chunk: Data, turn id: UUID, released: Date) {
        guard turnID == id else { return }
        if timing.firstAudioAfter == nil { timing.firstAudioAfter = clock().timeIntervalSince(released) }
        playback.enqueue(chunk)
    }

    private func end(id: UUID, outcome: String, failure: String?) {
        guard turnID == id else { return }
        timing.outcome = outcome
        if let turnStarted { timing.finishedAfter = clock().timeIntervalSince(turnStarted) }
        self.failure = failure
        phase = .idle
        turnTask = nil
        onTurnFinished(timing)
        turnStarted = nil
    }

    static func message(for error: Error) -> String {
        switch error {
        case let error as StepAudioTranscriberError: return error.userMessage
        case let error as MiniMaxSpeechError: return error.userMessage
        case let error as StableVoiceConversationError: return error.userMessage
        case let error as URLError where error.code == .notConnectedToInternet: return "没有网络，她听不到也说不出。"
        case let error as URLError where error.code == .timedOut: return "等太久没有回应，再说一次试试。"
        default: return "这一句没有完成：\(error.localizedDescription)"
        }
    }
}
