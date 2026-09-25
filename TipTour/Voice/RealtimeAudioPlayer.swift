//
//  RealtimeAudioPlayer.swift
//  TipTour
//
//  Streams PCM16 24kHz audio chunks from the realtime voice session to the
//  speakers in real time. Owns an AVAudioPlayerNode but NOT an AVAudioEngine
//  — the session passes in a shared engine so mic capture and playback both
//  run on the same engine. That's a hard requirement for Apple's voice
//  processing (AUVoiceIO) AEC to work: the audio unit needs to see both
//  uplink (mic) and downlink (speaker) on the same engine to subtract
//  speaker bleed from the mic input.
//
//  Why not AVAudioPlayer: it requires a complete audio file. Realtime APIs
//  stream audio in ~40ms chunks over the WebSocket — we need to queue each
//  chunk for playback the instant it arrives.
//

import AVFoundation
import Combine
import Foundation

struct AudioPlaybackQueueState {
    private(set) var pendingCount = 0
    private(set) var generation = 0

    mutating func schedule() -> Int {
        pendingCount += 1
        return generation
    }

    mutating func complete(generation completedGeneration: Int) {
        guard completedGeneration == generation, pendingCount > 0 else { return }
        pendingCount -= 1
    }

    mutating func reset() {
        generation += 1
        pendingCount = 0
    }
}

@MainActor
final class RealtimeAudioPlayer {

    // MARK: - State

    private let playerNode = AVAudioPlayerNode()

    /// The player node requires Float32 PCM. Incoming PCM16 is converted
    /// before scheduling, keeping the provider's 24kHz mono sample rate.
    private let playbackAudioFormat: AVAudioFormat

    /// The engine the player is currently attached to. Owned by the
    /// session, not by us — this is a weak reference so a dropped
    /// session doesn't keep the engine alive.
    private weak var sharedEngine: AVAudioEngine?

    /// Whether the player node is currently attached + connected to
    /// `sharedEngine`. Used to avoid double-attach and to guard
    /// scheduleBuffer when the session hasn't called attach yet.
    private var isAttachedAndConnected: Bool = false

    /// Number of audio buffers we've scheduled on `playerNode` but
    /// that haven't finished playing yet. The session uses
    /// this — NOT `playerNode.isPlaying` — to decide when the model
    /// is actually done speaking. `AVAudioPlayerNode.isPlaying` stays
    /// true forever once `play()` is called, regardless of whether the
    /// scheduled queue has drained, so it's useless as a "have we
    /// finished playing?" signal.
    ///
    /// scheduleBuffer's completion handler runs on an audio thread, so
    /// access is lock-protected.
    private var playbackQueueState = AudioPlaybackQueueState()
    private let pendingBufferLock = NSLock()

    /// A PCM16 sample can be split across two network chunks. The odd trailing
    /// byte is held for the next chunk instead of discarding the whole chunk,
    /// which was an audible dropout.
    private var carriedOddByte: UInt8?

    /// Per-response playback facts for telemetry, reset by the session at each
    /// `response.created`. An underrun is a chunk that arrived after the queue
    /// had already played out: the user heard a gap inside her reply.
    private(set) var underrunCountSinceReset = 0
    private(set) var oddByteChunkCountSinceReset = 0
    private var hasScheduledSinceReset = false

    func resetPlaybackStatistics() {
        underrunCountSinceReset = 0
        oddByteChunkCountSinceReset = 0
        hasScheduledSinceReset = false
    }

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: StepFunRealtimeClient.audioSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("[RealtimeAudio] Could not create 24kHz Float32 format — this should never happen")
        }
        self.playbackAudioFormat = format
    }

    // MARK: - Engine Attach / Detach

    /// Attach the player to the session's stopped engine before capture starts,
    /// so playback and microphone processing share the same audio graph.
    ///
    /// Connects the player to the engine's mainMixerNode so the engine
    /// handles sample-rate conversion from our 24kHz source to whatever
    /// the output device wants.
    func attach(to engine: AVAudioEngine) {
        // If we're already attached to this exact engine, no-op.
        if isAttachedAndConnected, sharedEngine === engine {
            return
        }
        // If we're attached to a different (older) engine, detach first.
        if isAttachedAndConnected, let previous = sharedEngine, previous !== engine {
            previous.detach(playerNode)
            isAttachedAndConnected = false
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackAudioFormat)
        sharedEngine = engine
        isAttachedAndConnected = true
        print("[RealtimeAudio] player node attached to shared engine")
    }

    /// Detach the player from its current engine. Called by the session
    /// during stop / narration enter so the engine can be torn down or
    /// reconfigured for a new session.
    func detach() {
        guard isAttachedAndConnected, let engine = sharedEngine else {
            return
        }
        pendingBufferLock.withLock { playbackQueueState.reset() }
        carriedOddByte = nil
        playerNode.stop()
        engine.detach(playerNode)
        sharedEngine = nil
        isAttachedAndConnected = false
        print("[RealtimeAudio] player node detached")
    }

    /// Start the player node. The session must have already started the
    /// shared engine — we don't touch engine lifecycle here.
    func startPlaying() {
        guard isAttachedAndConnected, let engine = sharedEngine, engine.isRunning else {
            return
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    /// Clear any queued audio and re-arm the player so subsequent
    /// scheduleBuffer calls play back immediately. Used on barge-in /
    /// interruption. Retire the old queue before stopping: callbacks from
    /// flushed buffers must not decrement the next response's count.
    func clearQueuedAudio() {
        guard isAttachedAndConnected else { return }
        pendingBufferLock.withLock { playbackQueueState.reset() }
        carriedOddByte = nil
        playerNode.stop()
        if let engine = sharedEngine, engine.isRunning {
            playerNode.play()
        }
        print("[RealtimeAudio] Audio queue cleared")
    }

    // MARK: - Audio Chunk Playback

    /// Schedule a PCM16 24kHz audio chunk for playback. Chunks play back
    /// in order — AVAudioPlayerNode handles the queueing. Auto-starts the
    /// player node on first chunk so the session doesn't have to call
    /// `startPlaying()` separately.
    func enqueueAudioChunk(_ pcm16Data: Data) {
        guard isAttachedAndConnected else {
            print("[RealtimeAudio] dropped chunk — player not attached to an engine yet")
            return
        }
        guard let engine = sharedEngine, engine.isRunning else {
            print("[RealtimeAudio] dropped chunk — shared engine not running")
            return
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }

        var wholeSampleData = Data()
        if let carriedOddByte {
            wholeSampleData.append(carriedOddByte)
            self.carriedOddByte = nil
        }
        wholeSampleData.append(pcm16Data)
        if pcm16Data.count % 2 != 0 { oddByteChunkCountSinceReset += 1 }
        if wholeSampleData.count % 2 != 0 {
            carriedOddByte = wholeSampleData.removeLast()
        }
        guard !wholeSampleData.isEmpty else { return }

        guard let audioBuffer = makeAudioBuffer(from: wholeSampleData) else {
            print("[RealtimeAudio] Could not create buffer from \(wholeSampleData.count)-byte chunk")
            return
        }

        // Track this buffer through render so the session can detect
        // when audio actually finishes playing. The completion handler
        // runs on a real-time audio thread — keep it cheap and lock-safe.
        let (generation, queueHadPlayedOut) = pendingBufferLock.withLock {
            (playbackQueueState.schedule(), playbackQueueState.pendingCount == 1)
        }
        if hasScheduledSinceReset && queueHadPlayedOut { underrunCountSinceReset += 1 }
        hasScheduledSinceReset = true
        // The default callback reports data consumption, before audible playback
        // finishes. Tool follow-ups must wait until the user has heard the reply.
        playerNode.scheduleBuffer(audioBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.pendingBufferLock.withLock {
                self?.playbackQueueState.complete(generation: generation)
            }
        }
    }

    /// Convert a raw PCM16 Data chunk into an AVAudioPCMBuffer that
    /// AVAudioPlayerNode can schedule.
    func makeAudioBuffer(from pcm16Data: Data) -> AVAudioPCMBuffer? {
        let bytesPerFrame = MemoryLayout<Int16>.size
        // PCM16 mono => byte count must be divisible by 2. If the server
        // ever sends a different format (stereo, PCM24, etc.), the raw
        // bytes would produce scrambled audio or a silently-dropped
        // buffer. Reject and log instead of schedule-and-hope.
        guard pcm16Data.count % bytesPerFrame == 0 else {
            print("[RealtimeAudio] ⚠ dropped \(pcm16Data.count)-byte chunk — not a multiple of \(bytesPerFrame) bytes/frame. Audio format may have changed upstream.")
            return nil
        }
        let frameCount = pcm16Data.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let audioBuffer = AVAudioPCMBuffer(
            pcmFormat: playbackAudioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }

        audioBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Data need not be aligned to Int16. Decode little-endian samples
        // explicitly and normalize the full signed range to [-1, 1).
        guard let destinationBuffer = audioBuffer.floatChannelData?[0] else { return nil }
        pcm16Data.withUnsafeBytes { rawSourcePointer in
            for frameIndex in 0..<frameCount {
                let sample = rawSourcePointer.loadUnaligned(
                    fromByteOffset: frameIndex * bytesPerFrame,
                    as: Int16.self
                )
                destinationBuffer[frameIndex] = Float(Int16(littleEndian: sample)) / 32768.0
            }
        }

        return audioBuffer
    }

    /// Whether the player has any unrendered buffers in its queue.
    /// THIS — not `playerNode.isPlaying` — is what the session uses to
    /// decide when the model is finished speaking. `AVAudioPlayerNode`'s
    /// `isPlaying` property reports whether `play()` has been called,
    /// not whether there's still audio to render, so it stays true
    /// forever after the first scheduled buffer.
    var isPlaying: Bool {
        return pendingBufferLock.withLock { playbackQueueState.pendingCount > 0 }
    }

    /// Exposed for sessions that want to inspect the count directly
    /// (e.g. for logging). Same value `isPlaying` checks.
    var pendingBufferCount: Int {
        return pendingBufferLock.withLock { playbackQueueState.pendingCount }
    }
}
