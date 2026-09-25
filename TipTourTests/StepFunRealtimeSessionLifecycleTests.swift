//
//  StepFunRealtimeSessionLifecycleTests.swift
//  TipTourTests
//
//  Tests for the StepFun voice turn lifecycle: when a reply counts as finished,
//  whether an interrupted turn may still report its tool result, and that a
//  late `response.done` cannot restart a turn the user cancelled.
//
//  State and audio graph checks — no microphone or network. Run with
//  `scripts/test-stepfun-voice-lifecycle.sh`, which compiles these sources into
//  an isolated package, so running them cannot reset the app's TCC permissions.
//

import AVFoundation
import Foundation
import Testing

@testable import TipTour

@MainActor
@Suite("Realtime audio playback")
struct RealtimeAudioPlaybackTests {
    @Test func responseCreateReliesOnSessionVoiceInsteadOfOverridingItAgain() throws {
        let event = StepFunRealtimeClient.responseCreateEvent(exactSpokenResponse: "已完成。")
        let response = try #require(event["response"] as? [String: Any])
        #expect(response["voice"] == nil)
        #expect((response["modalities"] as? [String]) == ["text", "audio"])
        #expect((response["instructions"] as? String)?.contains("已完成。") == true)
    }

    @Test func verifiedToolReceiptLivesInToolOutputWithoutChangingResponseStyle() throws {
        let raw = #"{"status":"completed","detail":"ok"}"#
        let output = StepFunRealtimeClient.toolOutputForModel(raw, exactSpokenResponse: "已确认豆包已打开。")
        let data = try #require(output.data(using: .utf8))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["spoken_response_exact"] as? String == "已确认豆包已打开。")
        #expect((payload["result"] as? [String: Any])?["status"] as? String == "completed")

        let responseEvent = StepFunRealtimeClient.responseCreateEvent()
        let response = try #require(responseEvent["response"] as? [String: Any])
        #expect(response["instructions"] == nil)
        #expect(response["voice"] == nil)
    }

    @Test func cancelledBuffersCannotFinishTheNextResponse() {
        var queue = AudioPlaybackQueueState()
        let oldGeneration = queue.schedule()
        queue.reset()
        let currentGeneration = queue.schedule()
        queue.complete(generation: oldGeneration)
        #expect(queue.pendingCount == 1)
        queue.complete(generation: currentGeneration)
        #expect(queue.pendingCount == 0)
        queue.complete(generation: currentGeneration)
        #expect(queue.pendingCount == 0)
    }

    @Test func pcm16SamplesPreserveAmplitudeAndFrameCount() throws {
        let player = RealtimeAudioPlayer()
        let buffer = try #require(player.makeAudioBuffer(from:
            Data([0x00, 0x80, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x40, 0xFF, 0x7F])
        ))
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.format.sampleRate == 24_000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.frameLength == 5)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect(Array(UnsafeBufferPointer(start: samples, count: 5)) ==
            [-1, -0.5, 0, 0.5, Float(Int16.max) / 32768.0])
    }

    @Test func malformedOrEmptyPCMIsRejected() {
        let player = RealtimeAudioPlayer()
        #expect(player.makeAudioBuffer(from: Data()) == nil)
        #expect(player.makeAudioBuffer(from: Data([0xFF])) == nil)
    }

    @Test func playerConnectsToAudioEngine() {
        let engine = AVAudioEngine()
        let player = RealtimeAudioPlayer()
        player.attach(to: engine)
        player.detach()
    }
}

@MainActor
@Suite("StepFun turn lifecycle")
struct StepFunTurnLifecycleTests {

    @Test func responseCreatedMarksResponseInFlightBeforeAnyAudioArrives() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordResponseCreated()
        #expect(lifecycle.phase == .awaitingResponseDone)

        // Tool calls can arrive before response.audio.delta. They must not be
        // treated as if playback already drained, or the tool continuation will
        // overlap the still-generating first response.
        #expect(lifecycle.recordToolCallArrived() == .none)
        #expect(lifecycle.hasPendingToolCall)
        #expect(lifecycle.phase == .awaitingResponseDone)
    }

    @Test func responseDoneStartsDrainInsteadOfEndingTheTurn() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.phase == .awaitingResponseDone)

        // response.done is the end of generation, not the end of playback.
        #expect(lifecycle.recordResponseDoneArrived() == .beginPlaybackDrain)
        #expect(lifecycle.phase == .awaitingPlaybackDrain)

        // Only the drained player ends the turn.
        #expect(lifecycle.recordPlaybackDrained() == .finishTurn)
        #expect(lifecycle.phase == .idle)
    }

    @Test func playbackDrainBeforeResponseDoneIsIgnored() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()

        #expect(lifecycle.recordPlaybackDrained() == .none)
        #expect(lifecycle.phase == .awaitingResponseDone)
    }

    @Test func duplicateResponseDoneDoesNotStartASecondDrain() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordResponseDoneArrived()

        #expect(lifecycle.recordResponseDoneArrived() == .none)
        #expect(lifecycle.phase == .awaitingPlaybackDrain)
    }

    @Test func pendingToolCallIsReportedOnlyAfterPlaybackDrains() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordToolCallArrived()

        // The tool call arrives while the model is still speaking; nothing may
        // be reported yet.
        #expect(lifecycle.recordResponseDoneArrived() == .beginPlaybackDrain)
        #expect(lifecycle.recordPlaybackDrained() == .finishTurnWithToolResult)
        #expect(lifecycle.phase == .awaitingToolResult)

        // Sending the result asks the server for a follow-up response; the turn
        // is not idle again until that response is actually created.
        lifecycle.recordToolResultReported(followupResponseExpected: true)
        #expect(lifecycle.phase == .awaitingFollowupResponseCreated)
        #expect(lifecycle.hasPendingToolCall == false)

        lifecycle.recordResponseCreated()
        #expect(lifecycle.phase == .awaitingResponseDone)
    }

    @Test func toolCallArrivingAfterDrainIsReportedWithoutWaitingForAnotherCompletion() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordResponseDoneArrived()
        #expect(lifecycle.recordPlaybackDrained() == .finishTurn)

        // A second call in the same response arrives after the turn already
        // drained; its result must not wait for a completion that already came.
        #expect(lifecycle.recordToolCallArrived() == .finishTurnWithToolResult)
        #expect(lifecycle.hasPendingToolCall)
        #expect(lifecycle.phase == .awaitingToolResult)

        lifecycle.recordToolResultReported(followupResponseExpected: true)
        #expect(lifecycle.phase == .awaitingFollowupResponseCreated)
    }

    @Test func toolCallFromAnInterruptedTurnIsDropped() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordUserStartedSpeaking()

        #expect(lifecycle.recordToolCallArrived() == .ignoreToolCallFromInterruptedTurn)
        #expect(lifecycle.hasPendingToolCall == false)
    }

    @Test func bargeInDuringSpeechCancelsAndLateCompletionIsIgnored() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordToolCallArrived()

        #expect(lifecycle.recordUserStartedSpeaking() == .interruptModelResponse)
        #expect(lifecycle.phase == .interrupted)
        // The interrupted turn's tool result must not be sent.
        #expect(lifecycle.hasPendingToolCall == false)

        // The cancelled response's completion finally arrives; it must not
        // restart the turn.
        #expect(lifecycle.recordResponseDoneArrived() == .ignoreTurnCompletionAfterInterrupt)
        #expect(lifecycle.phase == .idle)
    }

    @Test func lateAudioFromAnInterruptedResponseIsDroppedAndItsCompletionIgnored() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.recordUserStartedSpeaking() == .interruptModelResponse)
        #expect(lifecycle.phase == .interrupted)

        // Audio already in flight from the cancelled response arrives after the
        // interruption. It must not move the machine forward, which is exactly
        // what would make the late completion below look like a live turn.
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.phase == .interrupted)

        // The cancelled response's completion is ignored and starts no drain
        // wait, so the old response cannot revive itself.
        #expect(lifecycle.recordResponseDoneArrived() == .ignoreTurnCompletionAfterInterrupt)
        #expect(lifecycle.phase == .idle)

        // Only the next response's audio opens a new turn.
        lifecycle.recordResponseCreated()
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.phase == .awaitingResponseDone)
    }

    @Test func bargeInDuringPlaybackDrainAbandonsWithoutReporting() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordToolCallArrived()
        _ = lifecycle.recordResponseDoneArrived()

        #expect(lifecycle.recordUserStartedSpeaking() == .abandonCurrentTurn)
        #expect(lifecycle.phase == .idle)
        #expect(lifecycle.hasPendingToolCall == false)
        // A drain wait that had already started can no longer finish the turn.
        #expect(lifecycle.recordPlaybackDrained() == .none)
    }

    @Test func bargeInWhileToolResultIsPendingDropsTheCall() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordToolCallArrived()
        _ = lifecycle.recordResponseDoneArrived()
        #expect(lifecycle.recordPlaybackDrained() == .finishTurnWithToolResult)

        #expect(lifecycle.recordUserStartedSpeaking() == .abandonCurrentTurn)
        #expect(lifecycle.phase == .idle)
        #expect(lifecycle.hasPendingToolCall == false)
    }

    @Test func discardedFollowupNeverBlocksTheUsersNextResponse() {
        // The race: tool result sent (follow-up response requested), and the
        // user starts speaking BEFORE the server answers `response.created`.
        // Probed against the live API: no client token is echoed in
        // response.created, so a pending follow-up cannot be told apart from
        // the user's next response by id — and a cancelled follow-up still
        // emits created+done(incomplete) with no audio. The lifecycle must
        // therefore discard the follow-up WITHOUT eating the next created.
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordToolCallArrived()
        _ = lifecycle.recordResponseDoneArrived()
        #expect(lifecycle.recordPlaybackDrained() == .finishTurnWithToolResult)
        lifecycle.recordToolResultReported(followupResponseExpected: true)
        #expect(lifecycle.phase == .awaitingFollowupResponseCreated)

        #expect(lifecycle.recordUserStartedSpeaking() == .discardPendingFollowupResponse)
        #expect(lifecycle.phase == .interrupted)

        // The server cancelled the follow-up outright: no stale created, no
        // stale audio. The user's own next response must open a new turn.
        lifecycle.recordResponseCreated()
        #expect(lifecycle.phase == .awaitingResponseDone)
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.phase == .awaitingResponseDone)
    }

    @Test func lateCreatedOfACancelledFollowupCannotReviveItsTurn() {
        // When the cancel loses the race the stale follow-up's created still
        // arrives. The session rebuilds its socket at that point (the only
        // deterministic discard), so on the lifecycle's side the created opens
        // a normal turn and the cancelled response's completion is ignored
        // rather than reported as speech.
        var lifecycle = StepFunTurnLifecycle()
        _ = lifecycle.recordToolCallArrived()
        lifecycle.recordToolResultReported(followupResponseExpected: true)
        #expect(lifecycle.recordUserStartedSpeaking() == .discardPendingFollowupResponse)

        lifecycle.recordResponseCreated()
        #expect(lifecycle.phase == .awaitingResponseDone)
        // A cancelled response generates no audio; if any late chunk arrives it
        // still plays only as part of this — now user-owned — turn.
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.recordResponseDoneArrived() == .beginPlaybackDrain)
    }

    @Test func toolResultFollowupCreatedWithoutBargeInStartsTheReceiptTurn() {
        var lifecycle = StepFunTurnLifecycle()
        _ = lifecycle.recordToolCallArrived()
        lifecycle.recordToolResultReported(followupResponseExpected: true)
        #expect(lifecycle.phase == .awaitingFollowupResponseCreated)

        lifecycle.recordResponseCreated()
        #expect(lifecycle.phase == .awaitingResponseDone)
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.phase == .awaitingResponseDone)
    }

    @Test func unsentToolResultReturnsToIdleWithoutAwaitingAFollowup() {
        var lifecycle = StepFunTurnLifecycle()
        _ = lifecycle.recordToolCallArrived()
        #expect(lifecycle.phase == .awaitingToolResult)
        lifecycle.recordToolResultReported(followupResponseExpected: false)
        #expect(lifecycle.phase == .idle)
        #expect(lifecycle.hasPendingToolCall == false)
    }

    @Test func resetAfterDiscardedFollowupAcceptsTheNextCreated() {
        var lifecycle = StepFunTurnLifecycle()
        _ = lifecycle.recordToolCallArrived()
        lifecycle.recordToolResultReported(followupResponseExpected: true)
        #expect(lifecycle.recordUserStartedSpeaking() == .discardPendingFollowupResponse)

        lifecycle.reset()
        #expect(lifecycle.phase == .idle)
        lifecycle.recordResponseCreated()
        #expect(lifecycle.phase == .awaitingResponseDone)
    }

    @Test func newResponseRetiresAnInterruptedTurn() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.recordUserStartedSpeaking() == .interruptModelResponse)

        // The server never sent the cancelled response's completion, but it did
        // start the next response; the session must not stay deaf.
        lifecycle.recordResponseCreated()
        #expect(lifecycle.phase == .awaitingResponseDone)
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.phase == .awaitingResponseDone)
    }

    @Test func audioArrivingAfterDoneDoesNotCancelTheDrainWait() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordResponseDoneArrived()

        // A late chunk still plays, but it must not push the phase back and
        // orphan the drain wait.
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.phase == .awaitingPlaybackDrain)
        #expect(lifecycle.recordPlaybackDrained() == .finishTurn)
    }

    @Test func userSpeakingWhileTheModelIsIdleIsNotAnInterruption() {
        var lifecycle = StepFunTurnLifecycle()
        #expect(lifecycle.recordUserStartedSpeaking() == .none)
        #expect(lifecycle.phase == .idle)
    }

    @Test func resetReturnsAnAbandonedMachineToIdle() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        _ = lifecycle.recordToolCallArrived()
        _ = lifecycle.recordUserStartedSpeaking()

        lifecycle.reset()
        #expect(lifecycle.phase == .idle)
        #expect(lifecycle.hasPendingToolCall == false)
    }
}

/// Her own voice coming back through the MacBook speaker. Each test names the
/// failure it guards against, from the user's side.
@Suite("Own echo and half-duplex fallback")
struct OwnEchoFallbackTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    // F1: her words came back and were not recognized, so she keeps answering herself.
    @Test func herOwnSentenceHeardBackIsEcho() {
        let herSentence = "今天天气不错，要不要出去走走？"
        #expect(OwnSpeechEchoDetector.isEcho(transcript: "天气不错，要不要", ownSpeech: herSentence))
        #expect(OwnSpeechEchoDetector.isEcho(transcript: "今天天气不错要不要出去走走", ownSpeech: herSentence))
        // The transcriber rarely hears her perfectly; one wrong character still counts.
        #expect(OwnSpeechEchoDetector.isEcho(transcript: "天汽不错，要不要", ownSpeech: herSentence))
    }

    // F2: the user's own words are dropped as echo and the user is ignored.
    @Test func userSpeechIsNotEcho() {
        let herSentence = "今天天气不错，要不要出去走走？"
        #expect(!OwnSpeechEchoDetector.isEcho(transcript: "等一下，先别说了", ownSpeech: herSentence))
        #expect(!OwnSpeechEchoDetector.isEcho(transcript: "出去走走？好啊", ownSpeech: herSentence))
        #expect(!OwnSpeechEchoDetector.isEcho(transcript: "好的", ownSpeech: herSentence))
        #expect(!OwnSpeechEchoDetector.isEcho(transcript: "天气不错", ownSpeech: ""))
    }

    // F5: with no echo caught, the microphone must stay open so the user can talk over her.
    @Test func fullDuplexUntilEchoIsCaught() {
        let gate = HalfDuplexMicrophoneGate()
        gate.recordScheduledPlayback(duration: 3, at: start)
        #expect(gate.isWithinOwnSpeech(at: start.addingTimeInterval(1)))
        #expect(!gate.shouldSilenceMicrophone(at: start.addingTimeInterval(1)))
    }

    // F3 and F4: once engaged, silence covers her speech and its tail, then ends
    // by itself even if the player never reports that it finished.
    @Test func halfDuplexSilencesHerSpeechAndTailThenReopensByItself() {
        let gate = HalfDuplexMicrophoneGate()
        gate.engage()
        for chunkIndex in 0..<50 {
            // 50 chunks of 40 ms arriving faster than real time: 2 s of speech.
            gate.recordScheduledPlayback(duration: 0.04, at: start.addingTimeInterval(Double(chunkIndex) * 0.01))
        }
        #expect(gate.shouldSilenceMicrophone(at: start.addingTimeInterval(1.9)))
        #expect(gate.shouldSilenceMicrophone(at: start.addingTimeInterval(2 + HalfDuplexMicrophoneGate.tailAfterPlayback - 0.1)))
        #expect(!gate.shouldSilenceMicrophone(at: start.addingTimeInterval(2 + HalfDuplexMicrophoneGate.tailAfterPlayback + 0.1)))
    }

    // F7: a chunk that arrives after a gap starts from its own arrival, so the
    // silence still covers it.
    @Test func lateChunkAfterGapIsStillCovered() {
        let gate = HalfDuplexMicrophoneGate()
        gate.engage()
        gate.recordScheduledPlayback(duration: 1, at: start)
        #expect(!gate.shouldSilenceMicrophone(at: start.addingTimeInterval(4)))
        gate.recordScheduledPlayback(duration: 1, at: start.addingTimeInterval(5))
        #expect(gate.shouldSilenceMicrophone(at: start.addingTimeInterval(5.5)))
        #expect(gate.shouldSilenceMicrophone(at: start.addingTimeInterval(6 + HalfDuplexMicrophoneGate.tailAfterPlayback - 0.1)))
    }

    // Her reply was cut: the microphone reopens after the tail, not after the
    // speech she will no longer say.
    @Test func clearedPlaybackShortensTheSilence() {
        let gate = HalfDuplexMicrophoneGate()
        gate.engage()
        gate.recordScheduledPlayback(duration: 10, at: start)
        gate.recordPlaybackCleared(at: start.addingTimeInterval(1))
        #expect(!gate.shouldSilenceMicrophone(at: start.addingTimeInterval(1 + HalfDuplexMicrophoneGate.tailAfterPlayback + 0.1)))
    }

    // F6: a session the user starts again begins in full duplex.
    @Test func newSessionStartsInFullDuplex() {
        let gate = HalfDuplexMicrophoneGate()
        gate.engage()
        gate.reset()
        gate.recordScheduledPlayback(duration: 3, at: start)
        #expect(!gate.isEngaged)
        #expect(!gate.shouldSilenceMicrophone(at: start.addingTimeInterval(1)))
    }
}
