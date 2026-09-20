//
//  StepFunRealtimeSessionLifecycleTests.swift
//  TipTourTests
//
//  Tests for the StepFun voice turn lifecycle: when a reply counts as finished,
//  whether an interrupted turn may still report its tool result, and that a
//  late `response.done` cannot restart a turn the user cancelled.
//
//  Pure state — no microphone, no network, no AVAudioEngine. Run with
//  `scripts/test-stepfun-voice-lifecycle.sh`, which compiles these sources into
//  an isolated package, so running them cannot reset the app's TCC permissions.
//

import Foundation
import Testing

@testable import TipTour

@MainActor
@Suite("StepFun turn lifecycle")
struct StepFunTurnLifecycleTests {

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

        lifecycle.recordToolResultReported()
        #expect(lifecycle.phase == .idle)
        #expect(lifecycle.hasPendingToolCall == false)
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

        lifecycle.recordToolResultReported()
        #expect(lifecycle.phase == .idle)
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

    @Test func newResponseRetiresAnInterruptedTurn() {
        var lifecycle = StepFunTurnLifecycle()
        lifecycle.recordAudioChunkArrived()
        #expect(lifecycle.recordUserStartedSpeaking() == .interruptModelResponse)

        // The server never sent the cancelled response's completion, but it did
        // start the next response; the session must not stay deaf.
        lifecycle.recordResponseCreated()
        #expect(lifecycle.phase == .idle)
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
