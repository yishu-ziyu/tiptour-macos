import XCTest
@testable import TipTour

@MainActor
final class DesktopTaskCoordinatorTests: XCTestCase {
    private let target = DesktopTaskTarget(id: "target-3", label: "部署状态（3）", source: "ocr",
                                           box: [10, 10, 120, 40], display: [0, 0, 1000, 800])

    // Reproductions of the 2026-09-21 voice failures. A model's preferred
    // candidate and a changing page must not expand the user's command.
    func testMissingExactLabelNeverSubstitutesAnotherControl() async {
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "high confidence")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return DesktopTaskActionResult(completed: true, detail: "page changed")
        })
        let result = await runner.run(goal: "点击 os", namedTarget: "os")
        XCTAssertEqual(dispatches, 0)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(result.status, "needs_clarification")
    }

    func testCorrectionWithNoNewActionDoesNotClaimPreviousClick() async {
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "absent", declined: true)
        }, execute: { _, _, _, _ in
            dispatches += 1
            return DesktopTaskActionResult(completed: true, detail: "selected task-3")
        })
        _ = await runner.run(goal: "点击部署状态", namedTarget: target.label)
        let correction = await runner.run(goal: "不是这个，点击 os", namedTarget: "os", resumePrevious: true)
        XCTAssertEqual(dispatches, 1)
        XCTAssertTrue(correction.actions.isEmpty, "Old clicks are history, not this turn's actions")
        XCTAssertNotEqual(correction.status, "completed")
    }

    func testDefaultSingleTargetCannotKeepClickingOtherCandidates() async {
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "try next")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return DesktopTaskActionResult(completed: true, detail: "selected target")
        })
        _ = await runner.run(goal: "点击左侧那个会话")
        XCTAssertEqual(dispatches, 1)
    }

    func testModelDoneWithoutIndependentEvidenceCannotFinish() async {
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: nil, action: "done", completed: true, reason: "I say it is done")
        }, execute: { _, _, _, _ in
            XCTFail("No target was selected")
            return DesktopTaskActionResult(completed: false, detail: "unexpected")
        })
        let result = await runner.run(goal: "打开这个会话")
        XCTAssertFalse(["completed", "already_complete"].contains(result.status))
        XCTAssertTrue(result.actions.isEmpty)
    }

    func testExactNamedTargetExecutesWithoutModelCall() async {
        var decisions = 0
        var clicked: [String] = []
        let observation = DesktopTaskObservation(app: "fixture", targets: [target])
        let runner = DesktopTaskCoordinator(observe: { observation }, decide: { _, _, _, _ in
            decisions += 1
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unexpected")
        }, execute: { _, _, target, _ in
            clicked.append(target.id)
            return DesktopTaskActionResult(completed: true, detail: "selected task-3")
        })
        let result = await runner.run(goal: "打开任务", namedTarget: "部署状态(3)")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(clicked, [target.id])
        XCTAssertEqual(decisions, 0)
    }

    func testSeveralStepsCompleteUnderOneGoal() async {
        var clicked = 0
        let observation = DesktopTaskObservation(app: "fixture", targets: [target])
        let runner = DesktopTaskCoordinator(observe: { observation }, decide: { _, _, history, _ in
            DesktopTaskDecision(targetID: history.count < 2 ? self.target.id : nil, action: "click",
                                completed: history.count == 2, reason: "目标状态已出现")
        }, execute: { _, _, _, _ in
            clicked += 1
            return DesktopTaskActionResult(completed: true, detail: "changed state \(clicked)")
        })
        let result = await runner.run(goal: "完成两个步骤", steps: [
            DesktopActionStep(targetLabel: target.label), DesktopActionStep(targetLabel: target.label)
        ])
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.actions.count, 2)
        XCTAssertEqual(clicked, 2)
    }

    func testEmptyCandidatesReobserveOnceWithoutAskingAModelToGuess() async {
        var observations = 0
        var escalations: [Bool] = []
        let runner = DesktopTaskCoordinator(observe: {
            observations += 1
            return DesktopTaskObservation(app: "fixture", targets: [])
        },
                                            decide: { _, _, _, general in
            escalations.append(general)
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "目标没有出现")
        }, execute: { _, _, _, _ in
            XCTFail("No action should be sent")
            return DesktopTaskActionResult(completed: false, detail: "unexpected")
        })
        let result = await runner.run(goal: "打开不存在的项目")
        XCTAssertEqual(escalations, [])
        XCTAssertEqual(observations, 2)
        XCTAssertEqual(result.status, "needs_clarification")
    }

    func testExplicitNoneNeverEscalatesToAnotherProviderOrClicks() async {
        var decisions = 0
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, _, _ in
            decisions += 1
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false,
                                       reason: "target_absent", declined: true)
        }, execute: { _, _, _, _ in
            XCTFail("A declined choice must not become another click")
            return DesktopTaskActionResult(completed: true, detail: "unexpected")
        })
        let result = await runner.run(goal: "打开不存在的设置")
        XCTAssertEqual(result.status, "needs_clarification")
        XCTAssertEqual(decisions, 1)
        XCTAssertTrue(result.actions.isEmpty)
    }

    func testPageChangeWithoutGoalEvidencePreservesActionButStops() async {
        var decisions = 0
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, history, _ in
            decisions += 1
            return DesktopTaskDecision(targetID: history.isEmpty ? self.target.id : nil, action: "click",
                                       completed: false, reason: "target_absent", declined: !history.isEmpty)
        }, execute: { _, _, _, _ in
            DesktopTaskActionResult(completed: false, detail: "点击已送达且页面变化", delivery: .sent)
        })
        let result = await runner.run(goal: "点击右边的设置")
        XCTAssertEqual(result.status, "uncertain_effect")
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertFalse(result.currentActions[0].verified)
        XCTAssertEqual(result.currentActions[0].delivery, .sent)
        XCTAssertTrue(result.spokenSummary.contains("没有确认"))
        XCTAssertFalse(result.detail.contains("target_absent"))
    }

    func testVerifiedSingleActionFinishesWithoutAnotherModelDoneDecision() async {
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, history, _ in
            DesktopTaskDecision(targetID: history.isEmpty ? self.target.id : nil, action: "click",
                                completed: !history.isEmpty, reason: "任务目标已达到", declined: !history.isEmpty)
        }, execute: { _, _, _, _ in
            DesktopTaskActionResult(completed: true, detail: "独立读回显示目标会话已选中")
        })
        let result = await runner.run(goal: "点击右边的设置")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.actions.count, 1)
    }

    func testUnknownModelTargetNeverExecutes() async {
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: "invented", action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            XCTFail("Invented target must not execute")
            return DesktopTaskActionResult(completed: true, detail: "unexpected")
        })
        let result = await runner.run(goal: "点击目标")
        XCTAssertEqual(result.status, "failed")
    }

    func testInterruptDuringDecisionPreventsDispatch() async {
        var runner: DesktopTaskCoordinator!
        runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                        decide: { _, _, _, _ in
            runner.interrupt()
            return DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            XCTFail("Interrupted decision must not execute")
            return DesktopTaskActionResult(completed: true, detail: "unexpected")
        })
        let result = await runner.run(goal: "点击目标")
        XCTAssertEqual(result.status, "paused")
        XCTAssertTrue(result.actions.isEmpty)
    }

    func testInterruptAfterDispatchPreservesUncertainTargetAcrossInputTurns() async {
        var runner: DesktopTaskCoordinator!
        var dispatches = 0
        runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                        decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            runner.interrupt()
            throw CancellationError()
        })
        let interrupted = await runner.run(goal: "打开设置")
        XCTAssertEqual(interrupted.status, "paused")
        XCTAssertEqual(interrupted.actions.count, 1)
        XCTAssertTrue(interrupted.actions[0].contains("结果未确认"))
        let resumed = await runner.run(goal: "继续打开设置", resumePrevious: true)
        XCTAssertEqual(resumed.status, "uncertain_effect")
        XCTAssertEqual(dispatches, 1)
    }

    func testUncertainActionIsNotRetriedOrReportedComplete() async {
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return DesktopTaskActionResult(completed: false, detail: "结果未确认")
        })
        let result = await runner.run(goal: "点击目标")
        XCTAssertEqual(result.status, "uncertain_effect")
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(result.actions.count, 1)
    }

    func testAppChangeDuringDecisionStopsBeforeFirstDispatch() async {
        var observations = 0
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: {
            observations += 1
            return DesktopTaskObservation(app: observations == 1 ? "fixture" : "other", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return DesktopTaskActionResult(completed: true, detail: "step applied")
        })
        let result = await runner.run(goal: "继续完成任务")
        XCTAssertEqual(result.status, "paused")
        XCTAssertEqual(dispatches, 0)
    }

    func testExplicitPlanOverBudgetIsRejectedBeforeObservationOrAction() async {
        var observations = 0
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: {
            observations += 1
            return DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return DesktopTaskActionResult(completed: true, detail: "step applied")
        })
        let result = await runner.run(goal: "未完成的任务", maximumActions: 2,
            steps: Array(repeating: DesktopActionStep(targetLabel: target.label), count: 3))
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(observations, 0)
    }

    func testResumingCarriesHistoryAndDoesNotRepeatUncertainAction() async {
        var dispatches = 0
        var histories: [[String]] = []
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, history, _ in
            histories.append(history)
            return DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return DesktopTaskActionResult(completed: false, detail: "结果未知")
        })
        _ = await runner.run(goal: "点击目标")
        let resumed = await runner.run(goal: "继续点击目标", resumePrevious: true)
        XCTAssertEqual(resumed.status, "uncertain_effect")
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(histories.last?.count, 0)
        XCTAssertEqual(resumed.priorActions.count, 1)
        XCTAssertTrue(resumed.currentActions.isEmpty)
        XCTAssertEqual(resumed.targetVersion, 2)
    }

    func testResumeAfterUncertainEffectDoesNotSwitchToAnotherCandidate() async {
        // Reproduction of the candidate-switch accident: an unconfirmed click
        // on A followed by "continue" must not let the model try B instead.
        let other = DesktopTaskTarget(id: "other", label: "另一个会话", source: "ocr",
                                      box: [200, 10, 320, 40], display: [0, 0, 1000, 800])
        var decisions = 0
        var dispatched: [String] = []
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, other])
        }, decide: { _, _, _, _ in
            decisions += 1
            return DesktopTaskDecision(targetID: decisions == 1 ? self.target.id : other.id,
                                       action: "click", completed: false, reason: "")
        }, execute: { _, _, selected, _ in
            dispatched.append(selected.id)
            return DesktopTaskActionResult(completed: false, detail: "点击已送达，结果未确认", delivery: .sent)
        })
        let first = await runner.run(goal: "打开最新的会话")
        XCTAssertEqual(first.status, "uncertain_effect")
        XCTAssertEqual(dispatched, [target.id])

        let resumed = await runner.run(goal: "打开最新的会话", intent: .resume)
        XCTAssertEqual(resumed.status, "uncertain_effect")
        XCTAssertEqual(dispatched, [target.id], "An unconfirmed attempt must not turn into a different candidate")
        XCTAssertTrue(resumed.currentActions.isEmpty)
        XCTAssertTrue(resumed.verifiedActionHistory.isEmpty,
                      "An unverified attempt is not part of the verified history")
        XCTAssertEqual(decisions, 1, "A blocked resume must not ask the model for another candidate")
    }

    func testNewExplicitInstructionIsNotBlockedByPreviousTaskUncertainty() async {
        var dispatched = 0
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatched += 1
            return DesktopTaskActionResult(completed: dispatched > 1,
                                           detail: dispatched > 1 ? "已确认" : "结果未确认", delivery: .sent)
        })
        let first = await runner.run(goal: "点击目标")
        XCTAssertEqual(first.status, "uncertain_effect")
        XCTAssertEqual(dispatched, 1)

        // A brand-new explicit instruction is the user's authorization; the old
        // task's unconfirmed record must not block it.
        let fresh = await runner.run(goal: "点击部署状态", namedTarget: target.label)
        XCTAssertEqual(fresh.status, "completed")
        XCTAssertEqual(dispatched, 2)
        XCTAssertEqual(fresh.verifiedActionHistory.count, 1)
    }

    func testCorrectionWithReplaceTargetExecutesTheNewTarget() async {
        // After an uncertain effect the user explicitly replaces the target.
        // That is the sanctioned way forward: the old attempt stays in
        // attempted-unverified history and never enters verified history.
        let other = DesktopTaskTarget(id: "other", label: "另一个会话", source: "ocr",
                                      box: [200, 10, 320, 40], display: [0, 0, 1000, 800])
        var dispatched: [String] = []
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, other])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, selected, _ in
            dispatched.append(selected.id)
            return DesktopTaskActionResult(completed: dispatched.count == 2,
                                           detail: dispatched.count == 2 ? "已确认" : "结果未确认", delivery: .sent)
        })
        let first = await runner.run(goal: "打开最新的会话")
        XCTAssertEqual(first.status, "uncertain_effect")
        XCTAssertEqual(dispatched, [target.id])

        let corrected = await runner.run(goal: "不对，打开另一个会话", namedTarget: other.label,
            intent: .correct, uncertainResolution: .replaceTarget)
        XCTAssertEqual(corrected.status, "completed")
        XCTAssertEqual(dispatched, [target.id, other.id])
        XCTAssertEqual(corrected.priorActions.count, 1)
        XCTAssertTrue(corrected.priorActions[0].contains("结果未确认"))
        XCTAssertEqual(corrected.verifiedActionHistory, ["click「另一个会话」：目标状态已验证"])
    }

    func testCorrectionWithoutExplicitResolutionStaysBlocked() async {
        let other = DesktopTaskTarget(id: "other", label: "另一个会话", source: "ocr",
                                      box: [200, 10, 320, 40], display: [0, 0, 1000, 800])
        var dispatched = 0
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, other])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatched += 1
            return DesktopTaskActionResult(completed: false, detail: "结果未确认", delivery: .sent)
        })
        _ = await runner.run(goal: "打开最新的会话")
        // A correction that carries no resolution is still not authorization:
        // only replace_target (with an explicit new target) may proceed.
        let corrected = await runner.run(goal: "不对，打开另一个会话", namedTarget: other.label, intent: .correct)
        XCTAssertEqual(corrected.status, "uncertain_effect")
        XCTAssertEqual(dispatched, 1)
        XCTAssertTrue(corrected.currentActions.isEmpty)
    }

    func testConfirmedSucceededPromotesTheAttemptAndCompletesThePlan() async {
        var dispatched = 0
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatched += 1
            return DesktopTaskActionResult(completed: false, detail: "结果未确认", delivery: .sent)
        })
        let first = await runner.run(goal: "打开最新的会话")
        XCTAssertEqual(first.status, "uncertain_effect")

        let resolved = await runner.run(goal: "打开最新的会话", intent: .resume,
            uncertainResolution: .confirmedSucceeded)
        XCTAssertEqual(resolved.status, "completed")
        XCTAssertEqual(dispatched, 1, "A confirmation performs no new side effect")
        // Promoted with the verified wording; the attempt also remains in
        // attempted-unverified history.
        XCTAssertEqual(resolved.verifiedActionHistory, ["click「部署状态（3）」：目标状态已验证"])
        XCTAssertEqual(resolved.priorActions, ["click「部署状态（3）」：结果未确认"])
    }

    func testConfirmedFailedClearsTheBlockAndKeepsTheAttemptUnverified() async {
        var dispatched: [String] = []
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, selected, _ in
            dispatched.append(selected.id)
            return DesktopTaskActionResult(completed: dispatched.count == 2,
                                           detail: dispatched.count == 2 ? "已确认" : "结果未确认", delivery: .sent)
        })
        _ = await runner.run(goal: "打开最新的会话")
        XCTAssertEqual(dispatched, [target.id])

        let resolved = await runner.run(goal: "打开最新的会话", intent: .resume,
            uncertainResolution: .confirmedFailed)
        XCTAssertEqual(resolved.status, "completed")
        XCTAssertEqual(dispatched, [target.id, target.id])
        // The failed attempt remains attempted-unverified history; only the
        // retried, now-verified action enters verified history.
        XCTAssertEqual(resolved.priorActions.count, 1)
        XCTAssertEqual(resolved.verifiedActionHistory, ["click「部署状态（3）」：目标状态已验证"])
    }

    func testRetrySamePinsThePreviouslyUncertainTarget() async {
        let other = DesktopTaskTarget(id: "other", label: "另一个会话", source: "ocr",
                                      box: [200, 10, 320, 40], display: [0, 0, 1000, 800])
        var decisions = 0
        var dispatched: [String] = []
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, other])
        }, decide: { _, _, _, _ in
            decisions += 1
            return DesktopTaskDecision(targetID: decisions == 1 ? self.target.id : other.id,
                                       action: "click", completed: false, reason: "")
        }, execute: { _, _, selected, _ in
            dispatched.append(selected.id)
            return DesktopTaskActionResult(completed: dispatched.count == 2,
                                           detail: dispatched.count == 2 ? "已确认" : "结果未确认", delivery: .sent)
        })
        _ = await runner.run(goal: "打开最新的会话")
        XCTAssertEqual(dispatched, [target.id])

        // retry_same must re-run the SAME target, not let the decision layer
        // pick the runner-up candidate.
        let resolved = await runner.run(goal: "打开最新的会话", intent: .resume,
            uncertainResolution: .retrySame)
        XCTAssertEqual(resolved.status, "completed")
        XCTAssertEqual(dispatched, [target.id, target.id])
    }

    func testResumeDecisionHistoryContainsOnlyVerifiedActions() async {
        let second = DesktopTaskTarget(id: "next", label: "下一步", source: "ocr",
                                       box: [10, 100, 100, 130], display: target.display)
        var histories: [[String]] = []
        var didInterrupt = false
        var runner: DesktopTaskCoordinator!
        runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, second])
        }, decide: { _, _, history, _ in
            histories.append(history)
            if !didInterrupt { didInterrupt = true; runner.interrupt() }
            return DesktopTaskDecision(targetID: second.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, selected, _ in
            DesktopTaskActionResult(completed: true, detail: "已确认 \(selected.label)")
        })
        _ = await runner.run(goal: "完成两个步骤", steps: [
            DesktopActionStep(targetLabel: target.label), DesktopActionStep(action: .click)
        ])
        let resumed = await runner.run(goal: "完成两个步骤", intent: .resume)
        XCTAssertEqual(resumed.status, "completed")
        XCTAssertEqual(resumed.verifiedActionHistory.count, 2)
        XCTAssertEqual(histories.count, 2)
        XCTAssertEqual(histories.last?.count, 1)
        XCTAssertTrue(histories.last?.first?.contains("已验证") == true)
    }

    func testDecisionFailureReobservesAndHandsOffOnce() async {
        var observations = 0
        var routes: [Bool] = []
        var dispatchedAction: String?
        let runner = DesktopTaskCoordinator(observe: {
            observations += 1
            return DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, history, general in
            routes.append(general)
            if !general { throw NSError(domain: "DecisionUnavailable", code: 503) }
            return DesktopTaskDecision(targetID: self.target.id, action: "click", completed: !history.isEmpty, reason: "已完成")
        }, execute: { _, _, _, action in
            dispatchedAction = action
            return DesktopTaskActionResult(completed: true, detail: "菜单已打开")
        })
        let result = await runner.run(goal: "右键目标", action: "right_click")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(routes, [false, true])
        XCTAssertEqual(dispatchedAction, "right_click")
        XCTAssertEqual(observations, 3)
    }
}
