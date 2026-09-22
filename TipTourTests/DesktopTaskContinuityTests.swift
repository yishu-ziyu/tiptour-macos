import XCTest
@testable import TipTour

@MainActor
final class DesktopTaskContinuityTests: XCTestCase {
    private let target = DesktopTaskTarget(id: "fixture-a", label: "Alpha", source: "fixture",
        box: [0, 0, 40, 30], display: [0, 0, 800, 600])

    private func makeCoordinator(execute: @escaping DesktopTaskCoordinator.ExecuteStep) -> DesktopTaskCoordinator {
        let observation = DesktopTaskObservation(app: "fixture", targets: [target])
        return DesktopTaskCoordinator(observe: { observation }, decide: { _, _, _, _ in
            XCTFail("Exact fixture target needs no model")
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unexpected")
        }, executeStep: execute)
    }

    func testSpeechPauseKeepsIdentityAndDoesNotRepeatVerifiedStep() async throws {
        var dispatches = 0
        var coordinator: DesktopTaskCoordinator!
        coordinator = makeCoordinator { _, _, _, _ in
            dispatches += 1
            if dispatches == 1 { coordinator.pauseForUserInput() }
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                detail: "fixture state read back")
        }
        coordinator.beginUserTurn("first")
        let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "two steps", steps: [
            DesktopActionStep(targetLabel: "Alpha"), DesktopActionStep(targetLabel: "Alpha")
        ], turnID: "first"))
        await coordinator.waitUntilSettled()
        let paused = try XCTUnwrap(coordinator.lastReceipt)
        XCTAssertEqual(paused.taskID, admitted.taskID)
        XCTAssertEqual(paused.status, "paused")
        XCTAssertEqual(paused.completedStepCount, 1)
        XCTAssertEqual(dispatches, 1)
        coordinator.beginUserTurn("progress-question")
        _ = await coordinator.continueTask(taskID: paused.taskID, targetVersion: paused.targetVersion,
            turnID: "progress-question", onlyAfterUserInput: true)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(coordinator.lastReceipt?.taskID, admitted.taskID)
        XCTAssertEqual(coordinator.lastReceipt?.status, "completed")
        XCTAssertEqual(coordinator.lastReceipt?.completedStepCount, 2)
        XCTAssertEqual(dispatches, 2)
    }

    func testCancelKeepsLateReadbackAndPreventsRemainingSteps() async throws {
        var dispatches = 0
        var coordinator: DesktopTaskCoordinator!
        coordinator = makeCoordinator { _, _, _, _ in
            dispatches += 1
            let current = try XCTUnwrap(coordinator.lastReceipt)
            _ = coordinator.cancelTask(taskID: current.taskID, targetVersion: current.targetVersion, turnID: "cancel")
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                detail: "effect already happened")
        }
        coordinator.beginUserTurn("cancel")
        _ = await coordinator.submit(DesktopTaskSubmission(goal: "two steps", steps: [
            DesktopActionStep(targetLabel: "Alpha"), DesktopActionStep(targetLabel: "Alpha")
        ], turnID: "cancel"))
        await coordinator.waitUntilSettled()
        let cancelled = try XCTUnwrap(coordinator.lastReceipt)
        XCTAssertEqual(cancelled.status, "cancelled")
        XCTAssertEqual(cancelled.currentActions.filter(\.verified).count, 1)
        XCTAssertEqual(dispatches, 1)
        XCTAssertFalse(coordinator.hasPersistentReservation)
        coordinator.beginUserTurn("late-resume")
        _ = await coordinator.continueTask(taskID: cancelled.taskID, targetVersion: cancelled.targetVersion,
            turnID: "late-resume", onlyAfterUserInput: false)
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(coordinator.lastReceipt?.status, "cancelled")
    }

    func testPausedTaskExcludesOtherEntrypointsAndRejectsStaleControls() async throws {
        var coordinator: DesktopTaskCoordinator!
        coordinator = makeCoordinator { _, _, _, _ in
            coordinator.pauseForUserInput()
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified, detail: "fixture verified")
        }
        coordinator.beginUserTurn("owner")
        _ = await coordinator.submit(DesktopTaskSubmission(goal: "two steps", steps: [
            DesktopActionStep(targetLabel: "Alpha"), DesktopActionStep(targetLabel: "Alpha")
        ], turnID: "owner"))
        await coordinator.waitUntilSettled()
        let paused = try XCTUnwrap(coordinator.lastReceipt)
        let other = makeCoordinator { _, _, _, _ in
            XCTFail("Another entrypoint must not obtain the desktop")
            return DesktopTaskActionResult(delivery: .notSent, outcomeEvidence: .notObserved, detail: "unexpected")
        }
        other.beginUserTurn("other")
        let refused = await other.submit(DesktopTaskSubmission(goal: "competing task",
            steps: [DesktopActionStep(targetLabel: "Alpha")], turnID: "other"))
        XCTAssertEqual(refused.status, "busy")
        XCTAssertFalse(DesktopTaskAdmission.allowsCurrentTask)
        coordinator.beginUserTurn("current")
        XCTAssertNil(coordinator.cancelTask(taskID: paused.taskID, targetVersion: paused.targetVersion, turnID: "owner"))
        XCTAssertNil(coordinator.cancelTask(taskID: paused.taskID, targetVersion: paused.targetVersion + 1, turnID: "current"))
        _ = coordinator.cancelTask(taskID: paused.taskID, targetVersion: paused.targetVersion, turnID: "current")
        XCTAssertTrue(DesktopTaskAdmission.allowsCurrentTask)
    }

    func testCancellingAdmissionWaiterDoesNotCancelOwnedWork() async throws {
        let entered = expectation(description: "independent action entered")
        var release: CheckedContinuation<Void, Never>?
        let coordinator = makeCoordinator { _, _, _, _ in
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
            XCTAssertFalse(Task.isCancelled)
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                detail: "late readback")
        }
        coordinator.beginUserTurn("first")
        let waiter = Task { await coordinator.submit(DesktopTaskSubmission(goal: "one step",
            steps: [DesktopActionStep(targetLabel: "Alpha")], turnID: "first")) }
        _ = await waiter.value
        await fulfillment(of: [entered], timeout: 1)
        waiter.cancel()
        release?.resume()
        await coordinator.waitUntilSettled()
        XCTAssertEqual(coordinator.lastReceipt?.status, "completed")
        XCTAssertEqual(coordinator.lastReceipt?.currentActions.first?.verified, true)
    }

    func testJournalIsDurableBeforeDispatchAndContainsNoPrivatePayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DesktopTaskJournal(directory: root)
        var actionCount = 0
        let coordinator = makeCoordinator { _, observation, _, _ in
            let saved = try XCTUnwrap(journal.load())
            XCTAssertEqual(saved.attempts.last?.id, observation.actionAttemptID)
            XCTAssertEqual(saved.attempts.last?.delivery, .unknown)
            actionCount += 1
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified, detail: "readback")
        }
        coordinator.configureJournal(journal)
        coordinator.beginUserTurn("first")
        _ = await coordinator.submit(DesktopTaskSubmission(goal: "PRIVATE-GOAL-MARKER",
            steps: [DesktopActionStep(action: .type, targetLabel: "Alpha", text: "PRIVATE-TEXT-MARKER")], turnID: "first"))
        await coordinator.waitUntilSettled()
        XCTAssertEqual(actionCount, 1)
        let bytes = try String(contentsOf: root.appendingPathComponent("task.json"), encoding: .utf8)
        XCTAssertFalse(bytes.contains("PRIVATE-GOAL-MARKER"))
        XCTAssertFalse(bytes.contains("PRIVATE-TEXT-MARKER"))
        XCTAssertFalse(bytes.contains("Alpha"))
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("task.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try journal.load()?.status, "completed")
    }

    func testJournalFailurePreventsAnyAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let regularFile = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: regularFile)
        var count = 0
        let coordinator = makeCoordinator { _, _, _, _ in
            count += 1
            return DesktopTaskActionResult(delivery: .notSent, outcomeEvidence: .notObserved, detail: "unexpected")
        }
        coordinator.configureJournal(DesktopTaskJournal(directory: regularFile))
        coordinator.beginUserTurn("first")
        let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "no write, no act",
            steps: [DesktopActionStep(targetLabel: "Alpha")], turnID: "first"))
        await coordinator.waitUntilSettled()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(admitted.status, "storage_failed")
    }

    func testRecoveryRequiresInspectionAndCannotResumeFromMetadataAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DesktopTaskJournal(directory: root)
        let pending = DesktopTaskReceipt(goal: "never persisted", status: "running", actions: [], detail: "",
            taskID: "recover-task", targetVersion: 3, completedStepCount: 1, totalStepCount: 2)
        try journal.save(pending)
        var count = 0
        let coordinator = makeCoordinator { _, _, _, _ in
            count += 1
            return DesktopTaskActionResult(delivery: .notSent, outcomeEvidence: .notObserved, detail: "unexpected")
        }
        coordinator.configureJournal(DesktopTaskJournal(directory: root))
        XCTAssertEqual(coordinator.lastReceipt?.taskID, "recover-task")
        XCTAssertEqual(coordinator.lastReceipt?.status, "recovery_required")
        coordinator.beginUserTurn("retry")
        _ = await coordinator.submit(DesktopTaskSubmission(goal: "resume", intent: .resume, turnID: "retry"))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(coordinator.lastReceipt?.targetVersion, 3)
        _ = coordinator.cancelTask(taskID: "recover-task", targetVersion: 3, turnID: "retry")
    }

    func testNewRequestCannotOverwriteAnUnfinishedTask() async throws {
        let coordinator = makeCoordinator { _, _, _, _ in
            return DesktopTaskActionResult(delivery: .unknown, outcomeEvidence: .notObserved, detail: "receipt lost")
        }
        coordinator.beginUserTurn("first")
        let first = await coordinator.submit(DesktopTaskSubmission(goal: "unfinished",
            steps: [DesktopActionStep(targetLabel: "Alpha")], turnID: "first"))
        await coordinator.waitUntilSettled()
        coordinator.beginUserTurn("new")
        let refused = await coordinator.submit(DesktopTaskSubmission(goal: "unrelated",
            steps: [DesktopActionStep(targetLabel: "Alpha")], turnID: "new"))
        XCTAssertEqual(refused.status, "busy")
        XCTAssertEqual(coordinator.lastReceipt?.taskID, first.taskID)
        _ = coordinator.cancelTask(taskID: first.taskID, targetVersion: first.targetVersion, turnID: "new")
    }

    func testStaleCorrectionCannotInterruptTheCurrentTask() async throws {
        let entered = expectation(description: "first action entered")
        let correctionStarted = expectation(description: "stale correction submitted")
        var release: CheckedContinuation<Void, Never>?
        var dispatches = 0
        let coordinator = makeCoordinator { _, _, _, _ in
            dispatches += 1
            if dispatches == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered.fulfill()
                }
            }
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                detail: "fixture readback")
        }
        coordinator.beginUserTurn("first")
        let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "original task", steps: [
            DesktopActionStep(targetLabel: "Alpha"), DesktopActionStep(targetLabel: "Alpha")
        ], turnID: "first"))
        await fulfillment(of: [entered], timeout: 1)
        coordinator.beginUserTurn("current")
        let stale = Task { @MainActor in
            correctionStarted.fulfill()
            return await coordinator.submit(DesktopTaskSubmission(goal: "obsolete correction",
                steps: [DesktopActionStep(targetLabel: "Alpha")], intent: .correct, turnID: "first"))
        }
        await fulfillment(of: [correctionStarted], timeout: 1)
        release?.resume()
        _ = await stale.value
        await coordinator.waitUntilSettled()
        XCTAssertEqual(dispatches, 2, "An expired control must not interrupt the authorized task")
        XCTAssertEqual(coordinator.lastReceipt?.taskID, admitted.taskID)
        XCTAssertEqual(coordinator.lastReceipt?.status, "completed")
        _ = coordinator.cancelTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion, turnID: "current")
    }

    func testNewSpeechCannotTurnADisconnectIntoAutomaticResume() async throws {
        var dispatches = 0
        var coordinator: DesktopTaskCoordinator!
        coordinator = makeCoordinator { _, _, _, _ in
            dispatches += 1
            if dispatches == 1 { coordinator.pauseForDisconnection() }
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                detail: "fixture readback")
        }
        defer { coordinator = nil }
        coordinator.beginUserTurn("first")
        let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "two steps", steps: [
            DesktopActionStep(targetLabel: "Alpha"), DesktopActionStep(targetLabel: "Alpha")
        ], turnID: "first"))
        await coordinator.waitUntilSettled()
        coordinator.pauseForUserInput()
        coordinator.beginUserTurn("after-reconnect")
        _ = await coordinator.continueTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion,
            turnID: "after-reconnect", onlyAfterUserInput: true)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(dispatches, 1, "Asking for progress cannot clear an earlier disconnect pause")
        XCTAssertEqual(coordinator.lastReceipt?.status, "paused")
        _ = await coordinator.continueTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion,
            turnID: "after-reconnect", onlyAfterUserInput: false)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(dispatches, 2)
        XCTAssertEqual(coordinator.lastReceipt?.status, "completed")
    }

    func testProgressQueryDoesNotWaitForInFlightReadback() async throws {
        let entered = expectation(description: "first action awaiting readback")
        let answered = expectation(description: "progress query returned")
        var release: CheckedContinuation<Void, Never>?
        var dispatches = 0
        let coordinator = makeCoordinator { _, _, _, _ in
            dispatches += 1
            if dispatches == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered.fulfill()
                }
            }
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                detail: "fixture readback")
        }
        coordinator.beginUserTurn("first")
        let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "two steps", steps: [
            DesktopActionStep(targetLabel: "Alpha"), DesktopActionStep(targetLabel: "Alpha")
        ], turnID: "first"))
        await fulfillment(of: [entered], timeout: 1)
        coordinator.pauseForUserInput()
        coordinator.beginUserTurn("progress")
        let question = Task { @MainActor in
            let receipt = await coordinator.continueTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion,
                turnID: "progress", onlyAfterUserInput: true)
            answered.fulfill()
            return receipt
        }
        await fulfillment(of: [answered], timeout: 1)
        XCTAssertEqual(dispatches, 1, "A progress answer must not bypass the in-flight verification")
        release?.resume()
        _ = await question.value
        await coordinator.waitUntilSettled()
        XCTAssertEqual(dispatches, 2, "Continue the original task only after the first result is verified")
        XCTAssertEqual(coordinator.lastReceipt?.taskID, admitted.taskID)
        XCTAssertEqual(coordinator.lastReceipt?.status, "completed")
    }

    func testQueuedContinuationIsRevokedBeforeLateReadback() async throws {
        for event in ["cancel", "new-turn", "disconnect", "unverified"] {
            let entered = expectation(description: "readback held for \(event)")
            var release: CheckedContinuation<Void, Never>?
            var dispatches = 0
            let coordinator = makeCoordinator { _, _, _, _ in
                dispatches += 1
                if dispatches == 1 {
                    await withCheckedContinuation { continuation in
                        release = continuation
                        entered.fulfill()
                    }
                }
                return DesktopTaskActionResult(
                    delivery: event == "unverified" ? .unknown : .sent,
                    outcomeEvidence: event == "unverified" ? .notObserved : .systemVerified,
                    detail: "fixture readback")
            }
            coordinator.beginUserTurn("first")
            let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "two steps", steps: [
                DesktopActionStep(targetLabel: "Alpha"), DesktopActionStep(targetLabel: "Alpha")
            ], turnID: "first"))
            await fulfillment(of: [entered], timeout: 1)
            coordinator.pauseForUserInput()
            coordinator.beginUserTurn("progress")
            _ = await coordinator.continueTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion,
                turnID: "progress", onlyAfterUserInput: true)
            var currentTurn = "progress"
            switch event {
            case "cancel":
                _ = coordinator.cancelTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion, turnID: currentTurn)
            case "new-turn":
                coordinator.pauseForUserInput()
                currentTurn = "later"
                coordinator.beginUserTurn(currentTurn)
            case "disconnect": coordinator.pauseForDisconnection()
            default: break
            }
            release?.resume()
            await coordinator.waitUntilSettled()
            XCTAssertEqual(dispatches, 1, event)
            XCTAssertNotEqual(coordinator.lastReceipt?.status, "completed", event)
            XCTAssertEqual(coordinator.lastReceipt?.taskID, admitted.taskID, event)
            _ = coordinator.cancelTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion, turnID: currentTurn)
        }
    }

    func testUnreadableJournalBlocksAdmissionAndReportsTheProblem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("incomplete-journal-fixture".utf8)
        let file = root.appendingPathComponent("task.json")
        try original.write(to: file)
        var dispatches = 0
        let coordinator = makeCoordinator { _, _, _, _ in
            dispatches += 1
            return DesktopTaskActionResult(delivery: .notSent, outcomeEvidence: .notObserved, detail: "unexpected")
        }
        coordinator.configureJournal(DesktopTaskJournal(directory: root))
        XCTAssertEqual(coordinator.lastReceipt?.status, "storage_failed")
        XCTAssertFalse(DesktopTaskAdmission.allowsCurrentTask, "Recovery failure must not leave another entrypoint open")
        coordinator.beginUserTurn("first")
        let refused = await coordinator.submit(DesktopTaskSubmission(goal: "new task",
            steps: [DesktopActionStep(targetLabel: "Alpha")], turnID: "first"))
        XCTAssertEqual(refused.status, "storage_failed")
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(try Data(contentsOf: file), original, "Do not replace an unreadable journal with an empty one")
    }

    func testSpeechDuringFinalReadbackPreservesTheActualOutcome() async throws {
        for verified in [true, false] {
            var dispatches = 0
            var coordinator: DesktopTaskCoordinator!
            coordinator = makeCoordinator { _, _, _, _ in
                dispatches += 1
                coordinator.pauseForUserInput()
                return DesktopTaskActionResult(
                    delivery: verified ? .sent : .unknown,
                    outcomeEvidence: verified ? .systemVerified : .notObserved,
                    detail: "fixture readback")
            }
            coordinator.beginUserTurn("first")
            let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "one step",
                steps: [DesktopActionStep(targetLabel: "Alpha")], turnID: "first"))
            await coordinator.waitUntilSettled()
            XCTAssertEqual(coordinator.lastReceipt?.status, verified ? "completed" : "uncertain_effect")
            XCTAssertEqual(coordinator.lastReceipt?.currentActions.last?.verified, verified)
            coordinator.beginUserTurn("progress")
            _ = await coordinator.continueTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion,
                turnID: "progress", onlyAfterUserInput: true)
            await coordinator.waitUntilSettled()
            XCTAssertEqual(dispatches, 1, "Neither completion nor uncertainty permits a duplicate action")
            _ = coordinator.cancelTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion, turnID: "progress")
            coordinator = nil
        }
    }

    func testProgressQueryCannotResumeInADifferentWindow() async throws {
        var windowID = 1
        var dispatches = 0
        var coordinator: DesktopTaskCoordinator!
        coordinator = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target], windowID: windowID)
        }, decide: { _, _, _, _ in
            XCTFail("Exact fixture target needs no planner")
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unused")
        }, executeStep: { _, _, _, _ in
            dispatches += 1
            if dispatches == 1 { coordinator.pauseForUserInput() }
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                detail: "fixture readback")
        })
        defer { coordinator = nil }
        coordinator.beginUserTurn("first")
        let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "two steps", steps: [
            DesktopActionStep(targetLabel: "Alpha"), DesktopActionStep(targetLabel: "Alpha")
        ], turnID: "first"))
        await coordinator.waitUntilSettled()
        windowID = 2
        coordinator.beginUserTurn("progress")
        _ = await coordinator.continueTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion,
            turnID: "progress", onlyAfterUserInput: true)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(dispatches, 1, "The same label in another window is not authorization to continue")
        XCTAssertEqual(coordinator.lastReceipt?.status, "paused")
        _ = coordinator.cancelTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion, turnID: "progress")
    }

    func testAutomaticResumeUsesTheVerifiedAfterScene() async throws {
        var contentVersion = 0
        var dispatches = 0
        var coordinator: DesktopTaskCoordinator!
        coordinator = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target], windowID: 1, contentVersion: contentVersion)
        }, decide: { _, _, _, _ in
            XCTFail("Exact fixture target needs no planner")
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unused")
        }, executeStep: { _, _, _, _ in
            dispatches += 1
            contentVersion += 1
            if dispatches == 1 { coordinator.pauseForUserInput() }
            return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                detail: "fixture readback",
                resultingScene: DesktopTaskSceneIdentity(app: "fixture", windowID: 1, contentVersion: contentVersion))
        })
        defer { coordinator = nil }
        coordinator.beginUserTurn("first")
        let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "two steps", steps: [
            DesktopActionStep(targetLabel: "Alpha"), DesktopActionStep(targetLabel: "Alpha")
        ], turnID: "first"))
        await coordinator.waitUntilSettled()
        coordinator.beginUserTurn("progress")
        _ = await coordinator.continueTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion,
            turnID: "progress", onlyAfterUserInput: true)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(dispatches, 2, "The task's own verified change must not be mistaken for an unrelated page")
        XCTAssertEqual(coordinator.lastReceipt?.status, "completed")
    }
}
