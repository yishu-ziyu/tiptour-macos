//
//  StableVoiceSession.swift
//  TipTour
//
//  Microphone and speaker for the 「声音稳定」 voice style. The microphone is
//  on only while the shortcut is held, in its own engine, so macOS shows the
//  microphone as in use only then and she never hears herself. Playback has
//  a separate output-only engine.
//

import AVFoundation
import Foundation

@MainActor
final class StableVoiceSession {
    let runner: StableVoiceTurnRunner

    private let player = RealtimeAudioPlayer()
    private let playbackEngine = AVAudioEngine()
    private var captureEngine: AVAudioEngine?
    private let captured = CapturedAudio()

    init(services: StableVoiceTurnRunner.Services) {
        let player = self.player
        runner = StableVoiceTurnRunner(services: services, playback: .init(
            enqueue: { player.enqueueAudioChunk($0) },
            clear: { player.clearQueuedAudio() },
            isPlaying: { player.isPlaying }))
        player.attach(to: playbackEngine)
    }

    /// The shortcut went down: stop her and start recording. Returns why the
    /// microphone could not start, or nil.
    func press() -> String? {
        runner.beginListening()
        stopCapture()
        captured.reset()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            runner.interrupt()
            return "麦克风没有声音输入，检查一下系统设置里的输入设备。"
        }
        let converter = BuddyPCM16AudioConverter(targetSampleRate: Double(StepAudioTranscriber.sampleRate))
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(converter: converter, into: captured))
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            runner.interrupt()
            return "麦克风打不开：\(error.localizedDescription)"
        }
        captureEngine = engine
        return nil
    }

    /// The shortcut came up: close the microphone and hand over the utterance.
    func release() {
        guard captureEngine != nil else { return }
        stopCapture()
        startPlaybackEngineIfNeeded()
        runner.finishListening(audio: captured.take())
    }

    var isRecording: Bool { captureEngine != nil }

    func stop() {
        stopCapture()
        captured.reset()
        runner.interrupt()
        player.clearQueuedAudio()
        playbackEngine.stop()
    }

    private func stopCapture() {
        guard let engine = captureEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        captureEngine = nil
    }

    /// Runs on the audio thread, so it is built outside the main actor.
    nonisolated private static func tap(converter: BuddyPCM16AudioConverter, into captured: CapturedAudio) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let data = converter.convertToPCM16Data(from: buffer) { captured.append(data) }
        }
    }

    private func startPlaybackEngineIfNeeded() {
        guard !playbackEngine.isRunning else { return }
        do {
            try playbackEngine.start()
            player.startPlaying()
        } catch {
            print("[StableVoice] playback engine did not start: \(error.localizedDescription)")
        }
    }
}

/// PCM written by the audio thread and taken by the main actor.
nonisolated private final class CapturedAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    func reset() { lock.withLock { data = Data() } }
    func take() -> Data { lock.withLock { defer { data = Data() }; return data } }
}
