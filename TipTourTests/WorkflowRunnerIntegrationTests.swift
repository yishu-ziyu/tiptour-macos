import XCTest
@testable import TipTour

@MainActor
final class WorkflowRunnerIntegrationTests: XCTestCase {
    private func plan(_ goal: String) -> WorkflowPlan {
        let step = WorkflowStep(id: UUID().uuidString, type: .observe, label: nil,
            targetID: nil, targetMark: nil, value: nil, direction: nil, amount: nil, by: nil,
            targetContext: nil, hint: goal, hintX: nil, hintY: nil,
            box2DNormalized: nil, screenNumber: nil)
        return WorkflowPlan(goal: goal, app: nil, steps: [step], traceID: UUID().uuidString)
    }

    // No suspension between start and termination: the real runner's queued
    // perception task sees its retired identity before it can capture a screen.
    func testNaturalAdvanceReportsCompleted() async {
        let runner = WorkflowRunner()
        runner.start(plan: plan("observe fixture"), pointHandler: { _ in }, latestCapture: nil)
        let operationID = runner.currentOperationID
        runner.advance(pointHandler: { _ in }, latestCapture: nil)
        XCTAssertNil(runner.activePlan)
        XCTAssertEqual(runner.lastSettlement?.operationID, operationID)
        XCTAssertEqual(runner.lastSettlement?.status, .completed)
    }

    func testExplicitStopDoesNotReportCompletion() async {
        let runner = WorkflowRunner()
        runner.start(plan: plan("stop fixture"), pointHandler: { _ in }, latestCapture: nil)
        let operationID = runner.currentOperationID
        runner.stop()
        XCTAssertNil(runner.activePlan)
        XCTAssertEqual(runner.lastSettlement?.operationID, operationID)
        XCTAssertEqual(runner.lastSettlement?.status, .stopped)
        XCTAssertEqual(runner.delivery(for: operationID!), .notSent)
    }

    func testBusyStartPreservesOriginalOperation() async {
        let runner = WorkflowRunner()
        runner.start(plan: plan("first task"), pointHandler: { _ in }, latestCapture: nil)
        let operationID = runner.currentOperationID
        runner.start(plan: plan("unrelated task"), pointHandler: { _ in }, latestCapture: nil)
        XCTAssertEqual(runner.currentOperationID, operationID)
        XCTAssertEqual(runner.activePlan?.goal, "first task")
        runner.stop()
    }

    func testSkipNeverReportsCompleted() async {
        let runner = WorkflowRunner()
        runner.start(plan: plan("skip fixture"), pointHandler: { _ in }, latestCapture: nil)
        runner.skipCurrentStep()
        XCTAssertNil(runner.activePlan)
        XCTAssertNotEqual(runner.lastSettlement?.status, .completed)
    }

    func testStoppingAnOldIdentityCannotCancelAnotherOperation() async {
        let runner = WorkflowRunner()
        runner.start(plan: plan("old"), pointHandler: { _ in }, latestCapture: nil)
        let oldID = runner.currentOperationID!
        runner.stop()
        runner.start(plan: plan("new"), pointHandler: { _ in }, latestCapture: nil)
        let newID = runner.currentOperationID
        runner.stop(operationID: oldID)
        XCTAssertEqual(runner.currentOperationID, newID)
        XCTAssertEqual(runner.activePlan?.goal, "new")
        runner.stop()
    }

    func testStoppedDriverMustReturnBeforeDesktopCanBeReassigned() async throws {
        let runner = WorkflowRunner(captureScreens: {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return []
        })
        runner.start(plan: plan("first"), pointHandler: { _ in }, latestCapture: nil)
        let operationID = runner.currentOperationID!
        let entered = expectation(description: "fake driver entered")
        var releaseDriver: CheckedContinuation<Void, Never>?
        let delivery = Task { @MainActor in
            try await runner.performAction(operationID: operationID) {
                await withCheckedContinuation { continuation in
                    releaseDriver = continuation
                    entered.fulfill()
                }
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        runner.stop()
        XCTAssertTrue(runner.isBusy, "Cancellation is not proof that the driver stopped")
        runner.start(plan: plan("must wait"), pointHandler: { _ in }, latestCapture: nil)
        XCTAssertNil(runner.currentOperationID)
        releaseDriver?.resume()
        try await delivery.value
        XCTAssertFalse(runner.isBusy)
        XCTAssertEqual(runner.settlement(for: operationID)?.status, .stopped)
        XCTAssertEqual(runner.delivery(for: operationID), .sent, "Late driver return is a fact, not task revival")
        runner.start(plan: plan("next"), pointHandler: { _ in }, latestCapture: nil)
        XCTAssertNotNil(runner.currentOperationID)
        runner.stop()
    }

    func testActualEngineReadsTheRequestedOperationNotLatestSettlement() async throws {
        let runner = WorkflowRunner.shared
        runner.start(plan: plan("stopped"), pointHandler: { _ in }, latestCapture: nil)
        let stopped = try XCTUnwrap(runner.currentOperationID)
        runner.stop()
        runner.start(plan: plan("completed"), pointHandler: { _ in }, latestCapture: nil)
        let completed = try XCTUnwrap(runner.currentOperationID)
        runner.advance(pointHandler: { _ in }, latestCapture: nil)
        let engine = TipTourEngine(isAutopilotEnabledProvider: { true }, isScreenshotStreamingEnabledProvider: { false },
            isAccurateGroundingEnabledProvider: { false }, isCuaActionDriverEnabledProvider: { true },
            detectionElementCountProvider: { 0 }, refreshLocalPerception: { _ in },
            normalizeWorkflowSteps: { steps, _ in steps }, startWorkflowPlan: { _ in })
        let first = await engine.waitForWorkflowSettlement(operationID: stopped)
        let second = await engine.waitForWorkflowSettlement(operationID: completed)
        XCTAssertEqual(first.status, "stopped")
        XCTAssertEqual(second.status, "completed")
    }

    func testTaskOwnedPausedOperationIsRetiredWithoutClaimingCompletion() async throws {
        let runner = WorkflowRunner.shared
        defer { runner.stop() }
        let engine = TipTourEngine(isAutopilotEnabledProvider: { true }, isScreenshotStreamingEnabledProvider: { false },
            isAccurateGroundingEnabledProvider: { false }, isCuaActionDriverEnabledProvider: { true },
            detectionElementCountProvider: { 0 }, refreshLocalPerception: { _ in XCTFail("Observe fixture needs no refresh") },
            normalizeWorkflowSteps: { steps, _ in steps }, startWorkflowPlan: { plan in
                runner.start(plan: plan, pointHandler: { _ in }, latestCapture: nil)
                runner.pause(.userSpeaking)
            })
        let result = await DesktopTaskExecutionContext.$ownerID.withValue(UUID()) {
            await engine.submitSingleActionWorkflowPlanAndWait(plan("pause before delivery"))
        }
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.workflowOutcome?.status, "paused")
        XCTAssertEqual(result.workflowOutcome?.delivery, .notSent)
        XCTAssertNil(runner.currentOperationID, "The task owner, not an abandoned workflow, decides the next step")
        XCTAssertFalse(runner.isBusy)
    }

    func testLegacyToolCannotTakeTheDesktopFromAPersistentTask() async throws {
        let coordinator = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: []) },
            decide: { _, _, _, _ in DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unused") },
            executeStep: { _, _, _, _ in
                DesktopTaskActionResult(delivery: .notSent, outcomeEvidence: .notObserved,
                    detail: "fixture not delivered")
            })
        coordinator.beginUserTurn("owner")
        let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "retained task",
            steps: [DesktopActionStep(action: .openApp, application: "Fixture")], turnID: "owner"))
        await coordinator.waitUntilSettled()
        // Construct only; do not start monitors, UI, microphone or providers.
        let manager = CompanionManager()
        let rejection = manager.rejectIfToolCallShouldNotRun(id: "legacy-note", toolName: "create_note")
        XCTAssertEqual(rejection?["reason"] as? String, "desktop_task_busy")
        XCTAssertEqual(coordinator.lastReceipt?.taskID, admitted.taskID)
        _ = coordinator.cancelTask(taskID: admitted.taskID, targetVersion: admitted.targetVersion, turnID: "owner")
        XCTAssertNil(manager.rejectIfToolCallShouldNotRun(id: "legacy-note", toolName: "create_note"),
            "Rejected work must not consume the next authorized utterance's tool slot")
    }

    func testPointerEntryRejectsBusyDesktopBeforePerception() async {
        let runner = WorkflowRunner.shared
        defer { runner.stop() }
        runner.start(plan: plan("existing operation"), pointHandler: { _ in }, latestCapture: nil)
        runner.pause(.userSpeaking)
        let original = runner.currentOperationID
        var refreshes = 0
        let engine = TipTourEngine(isAutopilotEnabledProvider: { true }, isScreenshotStreamingEnabledProvider: { false },
            isAccurateGroundingEnabledProvider: { false }, isCuaActionDriverEnabledProvider: { true },
            detectionElementCountProvider: { 0 }, refreshLocalPerception: { _ in refreshes += 1 },
            normalizeWorkflowSteps: { steps, _ in steps }, startWorkflowPlan: { _ in XCTFail("A busy request cannot start") })
        let result = await engine.runPointerAction(PointerActionRequest(goal: "find another control", app: nil,
            actionType: .click, targetLabel: "No Such Fixture Control", targetID: nil, targetMark: nil,
            execute: true, allowScreenshotPlanning: false, validateStateChange: true, traceID: "busy-fixture"))
        XCTAssertEqual(result.reason, "desktop_task_busy")
        XCTAssertEqual(refreshes, 0, "Reject before perception can activate another application")
        XCTAssertEqual(runner.currentOperationID, original)
    }
}
