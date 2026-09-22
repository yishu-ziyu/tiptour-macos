import XCTest
@testable import TipTour

@MainActor
final class TaskRouterIntegrationTests: XCTestCase {
    private func engine() -> TipTourEngine {
        TipTourEngine(isAutopilotEnabledProvider: { true }, isScreenshotStreamingEnabledProvider: { false },
            isAccurateGroundingEnabledProvider: { false }, isCuaActionDriverEnabledProvider: { true },
            detectionElementCountProvider: { 0 }, refreshLocalPerception: { _ in XCTFail("No real perception in fixture") },
            normalizeWorkflowSteps: { steps, _ in steps }, startWorkflowPlan: { _ in XCTFail("No real actions in fixture") })
    }

    private func control(_ action: String, receipt: DesktopTaskReceipt, turn: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["action": action,
            "task_id": receipt.taskID, "target_version": receipt.targetVersion, "turn_id": turn]), as: UTF8.self)
    }

    private func receipt(_ json: String) throws -> DesktopTaskReceipt {
        try JSONDecoder().decode(DesktopTaskReceipt.self, from: Data(json.utf8))
    }

    func testRealRouterKeepsTaskAcrossVoiceBindingsAndRejectsOldConnection() async throws {
        let target = DesktopTaskTarget(id: "a", label: "Alpha", source: "fixture",
            box: [0, 0, 40, 30], display: [0, 0, 800, 600])
        var dispatches = 0
        var coordinator: DesktopTaskCoordinator!
        coordinator = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [target]) },
            decide: { _, _, _, _ in
                XCTFail("Exact fixture target needs no planner")
                return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unused")
            }, executeStep: { _, _, _, _ in
                dispatches += 1
                if dispatches == 1 { coordinator.pauseForUserInput() }
                return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                    detail: "independent fixture state")
            })
        let router = StepFunRealtimeToolRouter(engine: engine(), visionClient: StepFunVisionClient(apiKey: "fixture-not-a-key"),
            preservesTaskLifetime: true, coordinator: coordinator)
        let old = router.makeSessionHandler()
        old.beginUserTurn("one")
        let admission = try receipt(await old.handleToolCall(name: "act_on_screen", argumentsJSON:
            #"{"goal":"two fixture steps","intent":"new","steps":[{"action":"click","target_label":"Alpha"},{"action":"click","target_label":"Alpha"}]}"#))
        await coordinator.waitUntilSettled()
        XCTAssertEqual(dispatches, 1)
        old.interrupt()
        router.invalidateSessionBinding()
        let replacement = router.makeSessionHandler()
        replacement.beginUserTurn("two")
        old.beginUserTurn("stale")
        old.interrupt()
        let status = try receipt(await replacement.handleToolCall(name: "task_control", argumentsJSON: #"{"action":"status"}"#))
        XCTAssertEqual(status.taskID, admission.taskID)
        XCTAssertEqual(status.completedStepCount, 1)
        XCTAssertTrue(replacement.taskContext?.contains("two") == true)
        let oldOutput = try await old.handleToolCall(name: "task_control",
            argumentsJSON: control("resume", receipt: status, turn: "one"))
        XCTAssertTrue(oldOutput.contains("过期"))
        _ = try await replacement.handleToolCall(name: "task_control",
            argumentsJSON: control("status_and_continue", receipt: status, turn: "two"))
        XCTAssertEqual(dispatches, 1, "A disconnect is not a speech-only pause")
        _ = try await replacement.handleToolCall(name: "task_control",
            argumentsJSON: control("resume", receipt: status, turn: "two"))
        await coordinator.waitUntilSettled()
        XCTAssertEqual(dispatches, 2)
        XCTAssertEqual(coordinator.lastReceipt?.taskID, admission.taskID)
        XCTAssertEqual(coordinator.lastReceipt?.status, "completed")
        coordinator = nil
    }

    func testProgressControlUsesCurrentTurnAndSameTask() async throws {
        var coordinator: DesktopTaskCoordinator!
        coordinator = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: []) },
            decide: { _, _, _, _ in DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unused") },
            executeStep: { _, _, _, _ in
                coordinator.pauseForUserInput()
                return DesktopTaskActionResult(delivery: .notSent, outcomeEvidence: .notObserved,
                    detail: "not dispatched")
            })
        let router = StepFunRealtimeToolRouter(engine: engine(), visionClient: StepFunVisionClient(apiKey: "fixture-not-a-key"),
            preservesTaskLifetime: true, coordinator: coordinator)
        let binding = router.makeSessionHandler()
        binding.beginUserTurn("one")
        _ = try await binding.handleToolCall(name: "act_on_screen", argumentsJSON:
            #"{"goal":"fixture launch","action":"open_app","application":"Fixture"}"#)
        await coordinator.waitUntilSettled()
        let status = try XCTUnwrap(coordinator.lastReceipt)
        binding.beginUserTurn("two")
        _ = try await binding.handleToolCall(name: "task_control", argumentsJSON: control("cancel", receipt: status, turn: "one"))
        XCTAssertEqual(coordinator.lastReceipt?.status, "paused")
        _ = try await binding.handleToolCall(name: "task_control", argumentsJSON: control("cancel", receipt: status, turn: "two"))
        XCTAssertEqual(coordinator.lastReceipt?.status, "cancelled")
        coordinator = nil
    }

    func testResumeCannotSilentlyDropANewTargetConstraint() async throws {
        let target = DesktopTaskTarget(id: "a", label: "Alpha", source: "fixture",
            box: [0, 0, 40, 30], display: [0, 0, 800, 600])
        var dispatches = 0
        var coordinator: DesktopTaskCoordinator!
        coordinator = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [target]) },
            decide: { _, _, _, _ in
                XCTFail("The changed resume must be rejected before planning")
                return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unused")
            }, executeStep: { _, _, _, _ in
                dispatches += 1
                if dispatches == 1 { coordinator.pauseForUserInput() }
                return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                    detail: "fixture readback")
            })
        defer { coordinator = nil }
        let router = StepFunRealtimeToolRouter(engine: engine(), visionClient: StepFunVisionClient(apiKey: "fixture-not-a-key"),
            preservesTaskLifetime: true, coordinator: coordinator)
        let binding = router.makeSessionHandler()
        binding.beginUserTurn("first")
        _ = try await binding.handleToolCall(name: "act_on_screen", argumentsJSON:
            #"{"goal":"two fixture steps","intent":"new","steps":[{"action":"click","target_label":"Alpha"},{"action":"click","target_label":"Alpha"}]}"#)
        await coordinator.waitUntilSettled()
        let original = try XCTUnwrap(coordinator.lastReceipt)
        binding.beginUserTurn("second")
        _ = try await binding.handleToolCall(name: "act_on_screen", argumentsJSON:
            #"{"goal":"two fixture steps","intent":"resume","region":"right"}"#)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(dispatches, 1, "Do not discard the new region and execute the old plan")
        XCTAssertEqual(coordinator.lastReceipt?.taskID, original.taskID)
        XCTAssertNotEqual(coordinator.lastReceipt?.status, "completed")
        _ = coordinator.cancelTask(taskID: original.taskID, targetVersion: original.targetVersion, turnID: "second")
    }
}
