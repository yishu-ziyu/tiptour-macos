import XCTest
@testable import TipTour

@MainActor
final class DesktopTaskCoordinatorTests: XCTestCase {
    private let target = DesktopTaskTarget(id: "target-3", label: "部署状态（3）", source: "ocr",
                                           box: [10, 10, 120, 40], display: [0, 0, 1000, 800])

    // MARK: - Fixture result builders (two-layer facts: delivery vs outcome)

    /// The driver delivered the input and an independent read-back proved the
    /// requested effect.
    private func verifiedResult(_ detail: String) -> DesktopTaskActionResult {
        DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified, detail: detail)
    }

    /// The driver delivered the input; nobody observed what it caused.
    private func deliveredUnverifiedResult(_ detail: String) -> DesktopTaskActionResult {
        DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .notObserved, detail: detail)
    }

    /// The driver never reported whether the input reached the target.
    private func unknownDeliveryResult(_ detail: String) -> DesktopTaskActionResult {
        DesktopTaskActionResult(delivery: .unknown, outcomeEvidence: .notObserved, detail: detail)
    }

    func testActionAttemptsDoNotReuseObservationIdentity() async {
        let observation = DesktopTaskObservation(app: "fixture", targets: [target], id: "one-cached-observation")
        var dispatchedAttemptIDs: [String?] = []
        let runner = DesktopTaskCoordinator(observe: { observation }, decide: { _, _, _, _ in
            XCTFail("Exact targets need no model")
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unexpected")
        }, execute: { _, actionObservation, _, _ in
            dispatchedAttemptIDs.append(actionObservation.actionAttemptID)
            return self.verifiedResult("independent fixture state confirmed")
        })
        let result = await runner.run(goal: "two explicit steps", steps: [
            DesktopActionStep(targetLabel: target.label), DesktopActionStep(targetLabel: target.label)
        ])
        XCTAssertEqual(result.currentActions.count, 2)
        XCTAssertEqual(Set(result.currentActions.map(\.id)).count, 2, "An observation is evidence, not an invocation ID")
        XCTAssertTrue(result.currentActions.allSatisfy { $0.observationID == observation.id })
        XCTAssertEqual(dispatchedAttemptIDs, result.currentActions.map { Optional($0.id) })
        XCTAssertFalse(dispatchedAttemptIDs.contains(observation.id))
    }

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
            return self.verifiedResult("page changed")
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
            return self.verifiedResult("selected task-3")
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
            return self.verifiedResult("selected target")
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
            return self.verifiedResult("unexpected")
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
            return self.verifiedResult("selected task-3")
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
            return self.verifiedResult("changed state \(clicked)")
        })
        let result = await runner.run(goal: "完成两个步骤", steps: [
            DesktopActionStep(targetLabel: target.label), DesktopActionStep(targetLabel: target.label)
        ])
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.actions.count, 2)
        XCTAssertEqual(clicked, 2)
        XCTAssertEqual(result.verifiedActionHistory,
                       ["click「部署状态（3）」：结果已验证", "click「部署状态（3）」：结果已验证"])
        XCTAssertEqual(result.satisfiedActionHistory, result.verifiedActionHistory)
        XCTAssertEqual(result.spokenSummary, "已完成并确认这 2 步操作。")
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
            return self.unknownDeliveryResult("unexpected")
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
            return self.verifiedResult("unexpected")
        })
        let result = await runner.run(goal: "打开不存在的设置")
        XCTAssertEqual(result.status, "needs_clarification")
        XCTAssertEqual(decisions, 1)
        XCTAssertTrue(result.actions.isEmpty)
    }

    /// A pure click carries no expected label, so delivery is sufficient: the
    /// page changed after the input landed, and the task completes on the
    /// action fact alone — never on an outcome claim.
    func testPageChangeWithoutGoalEvidenceDeliveryConfirmsPureClick() async {
        var decisions = 0
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, history, _ in
            decisions += 1
            return DesktopTaskDecision(targetID: history.isEmpty ? self.target.id : nil, action: "click",
                                       completed: false, reason: "target_absent", declined: !history.isEmpty)
        }, execute: { _, _, _, _ in
            self.deliveredUnverifiedResult("点击已送达且页面变化")
        })
        let result = await runner.run(goal: "点击右边的设置")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(result.actions, ["click「部署状态（3）」：动作已送达"])
        let record = result.currentActions[0]
        XCTAssertEqual(record.completionPolicy, .deliverySufficient)
        XCTAssertEqual(record.delivery, .sent)
        XCTAssertEqual(record.outcomeEvidence, .notObserved)
        XCTAssertEqual(record.completionBasis, .deliveryConfirmed)
        XCTAssertTrue(record.satisfied)
        XCTAssertFalse(record.verified)
        XCTAssertEqual(result.satisfiedActionHistory, ["click「部署状态（3）」：动作已送达"])
        XCTAssertTrue(result.verifiedActionHistory.isEmpty)
        XCTAssertEqual(result.spokenSummary, "已点击「部署状态（3）」。")
        for outcomeWording in ["已生效", "已确认", "没有确认"] {
            XCTAssertFalse(result.spokenSummary.contains(outcomeWording),
                           "Delivery-only speech '\(result.spokenSummary)' must not claim '\(outcomeWording)'")
        }
        XCTAssertFalse(result.detail.contains("target_absent"))
    }

    func testVerifiedSingleActionFinishesWithoutAnotherModelDoneDecision() async {
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, history, _ in
            DesktopTaskDecision(targetID: history.isEmpty ? self.target.id : nil, action: "click",
                                completed: !history.isEmpty, reason: "任务目标已达到", declined: !history.isEmpty)
        }, execute: { _, _, _, _ in
            self.verifiedResult("独立读回显示目标会话已选中")
        })
        let result = await runner.run(goal: "点击右边的设置")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertEqual(result.verifiedActionHistory, ["click「部署状态（3）」：结果已验证"])
        XCTAssertEqual(result.spokenSummary, "已确认「部署状态（3）」的操作结果。")
    }

    func testUnknownModelTargetNeverExecutes() async {
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: "invented", action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            XCTFail("Invented target must not execute")
            return self.verifiedResult("unexpected")
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
            return self.verifiedResult("unexpected")
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
            return self.unknownDeliveryResult("结果未确认")
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
            return self.verifiedResult("step applied")
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
            return self.verifiedResult("step applied")
        })
        let result = await runner.run(goal: "未完成的任务", maximumActions: 2,
            steps: Array(repeating: DesktopActionStep(targetLabel: target.label), count: 3))
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(observations, 0)
    }

    // MARK: - Delivery-confirmed completion (behaviors 1 and 2)

    /// Every direct-input action kind without an expected label is satisfied
    /// by delivery alone: status completed, deliveryConfirmed basis, satisfied
    /// (not verified) history wording, and action-fact speech that never
    /// claims an outcome.
    func testPureDirectInputCompletesOnDeliveryWithoutOutcomeEvidence() async {
        let cases: [(step: DesktopActionStep, expectedSpeech: String, expectedHistory: String)] = [
            (DesktopActionStep(action: .click, targetLabel: target.label),
             "已点击「部署状态（3）」。", "click「部署状态（3）」：动作已送达"),
            (DesktopActionStep(action: .doubleClick, targetLabel: target.label),
             "已双击「部署状态（3）」。", "double_click「部署状态（3）」：动作已送达"),
            (DesktopActionStep(action: .rightClick, targetLabel: target.label),
             "已右键点击「部署状态（3）」。", "right_click「部署状态（3）」：动作已送达"),
            (DesktopActionStep(action: .pressKey, key: "enter"),
             "已按下 enter。", "press_key「enter」：动作已送达"),
            (DesktopActionStep(action: .shortcut, key: "cmd+n"),
             "已执行快捷键 cmd+n。", "shortcut「cmd+n」：动作已送达"),
            (DesktopActionStep(action: .scroll, direction: "down", amount: 1),
             "已向下滚动。", "scroll「down」：动作已送达"),
        ]
        for testCase in cases {
            let runner = DesktopTaskCoordinator(observe: {
                DesktopTaskObservation(app: "fixture", targets: [self.target])
            }, decide: { _, _, _, _ in
                DesktopTaskDecision(targetID: self.target.id, action: testCase.step.action.rawValue,
                                    completed: false, reason: "")
            }, executeStep: { _, _, _, _ in
                self.deliveredUnverifiedResult("输入已送达，未读回结果")
            })
            let result = await runner.run(goal: "单步操作", steps: [testCase.step])
            XCTAssertEqual(result.status, "completed", "\(testCase.step.action.rawValue)")
            XCTAssertEqual(result.completedStepCount, 1, "\(testCase.step.action.rawValue)")
            XCTAssertEqual(result.actions, [testCase.expectedHistory], "\(testCase.step.action.rawValue)")
            let record = result.currentActions[0]
            XCTAssertEqual(record.completionPolicy, .deliverySufficient, "\(testCase.step.action.rawValue)")
            XCTAssertEqual(record.delivery, .sent, "\(testCase.step.action.rawValue)")
            XCTAssertEqual(record.outcomeEvidence, .notObserved, "\(testCase.step.action.rawValue)")
            XCTAssertEqual(record.completionBasis, .deliveryConfirmed, "\(testCase.step.action.rawValue)")
            XCTAssertTrue(record.satisfied, "\(testCase.step.action.rawValue)")
            XCTAssertFalse(record.verified, "\(testCase.step.action.rawValue)")
            XCTAssertFalse(record.uncertainEffect, "\(testCase.step.action.rawValue)")
            XCTAssertEqual(result.satisfiedActionHistory, [testCase.expectedHistory],
                           "\(testCase.step.action.rawValue)")
            XCTAssertTrue(result.verifiedActionHistory.isEmpty, "\(testCase.step.action.rawValue)")
            XCTAssertEqual(result.spokenSummary, testCase.expectedSpeech,
                           "\(testCase.step.action.rawValue)")
            for outcomeWording in ["已生效", "已确认", "没有确认"] {
                XCTAssertFalse(result.spokenSummary.contains(outcomeWording),
                               "\(testCase.step.action.rawValue) speech '\(result.spokenSummary)' must not claim '\(outcomeWording)'")
            }
        }
    }

    // MARK: - Outcome-required actions (behavior 5)

    func testClickWithExpectedLabelRequiresNewlyVisibleOutcome() async {
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            self.deliveredUnverifiedResult("点击已送达，预期标签未出现")
        })
        let result = await runner.run(goal: "点击后出现就绪", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label, expectedLabel: "就绪")
        ])
        XCTAssertEqual(result.status, "uncertain_effect")
        let record = result.currentActions[0]
        XCTAssertEqual(record.completionPolicy, .outcomeRequired)
        XCTAssertEqual(record.delivery, .sent)
        XCTAssertEqual(record.outcomeEvidence, .notObserved)
        XCTAssertNil(record.completionBasis)
        XCTAssertFalse(record.satisfied)
        XCTAssertTrue(record.uncertainEffect)
        XCTAssertTrue(result.satisfiedActionHistory.isEmpty)
        XCTAssertTrue(result.verifiedActionHistory.isEmpty)
    }

    func testClickWithExpectedLabelCompletesWhenOutcomeIsSystemVerified() async {
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            self.verifiedResult("就绪 标签新出现，独立读回确认")
        })
        let result = await runner.run(goal: "点击后出现就绪", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label, expectedLabel: "就绪")
        ])
        XCTAssertEqual(result.status, "completed")
        let record = result.currentActions[0]
        XCTAssertEqual(record.completionPolicy, .outcomeRequired)
        XCTAssertEqual(record.outcomeEvidence, .systemVerified)
        XCTAssertEqual(record.completionBasis, .systemVerifiedOutcome)
        XCTAssertTrue(record.satisfied)
        XCTAssertTrue(record.verified)
        XCTAssertEqual(result.verifiedActionHistory, ["click「部署状态（3）」：结果已验证"])
        XCTAssertEqual(result.satisfiedActionHistory, ["click「部署状态（3）」：结果已验证"])
        XCTAssertEqual(result.spokenSummary, "已确认「部署状态（3）」的操作结果。")
    }

    func testTypeActionAlwaysRequiresOutcomeEvidenceEvenWithoutExpectedLabel() async {
        let field = DesktopTaskTarget(id: "field-1", label: "搜索框", source: "ocr",
                                      box: [10, 100, 200, 130], display: target.display)
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [field])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: field.id, action: "type", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            self.deliveredUnverifiedResult("驱动已送达，字段读回值不一致")
        })
        let result = await runner.run(goal: "输入文字", steps: [
            DesktopActionStep(action: .type, targetLabel: field.label, text: "hello")
        ])
        XCTAssertEqual(result.status, "uncertain_effect")
        let record = result.currentActions[0]
        XCTAssertEqual(record.completionPolicy, .outcomeRequired,
                       "type always requires outcome evidence, expectedLabel or not")
        XCTAssertTrue(record.uncertainEffect)
        XCTAssertEqual(result.spokenSummary, "已向「搜索框」发送操作，但目标结果还没有确认，已停下。")
    }

    func testTypeActionCompletesWhenFieldValueReadBackMatches() async {
        let field = DesktopTaskTarget(id: "field-1", label: "搜索框", source: "ocr",
                                      box: [10, 100, 200, 130], display: target.display)
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [field])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: field.id, action: "type", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            self.verifiedResult("字段读回值与请求文字一致")
        })
        let result = await runner.run(goal: "输入文字", steps: [
            DesktopActionStep(action: .type, targetLabel: field.label, text: "hello")
        ])
        XCTAssertEqual(result.status, "completed")
        let record = result.currentActions[0]
        XCTAssertEqual(record.completionPolicy, .outcomeRequired)
        XCTAssertEqual(record.outcomeEvidence, .systemVerified)
        XCTAssertEqual(record.completionBasis, .systemVerifiedOutcome)
        XCTAssertTrue(record.verified)
        XCTAssertEqual(result.verifiedActionHistory, ["type「搜索框」：结果已验证"])
        XCTAssertEqual(result.satisfiedActionHistory, ["type「搜索框」：结果已验证"])
        XCTAssertEqual(result.spokenSummary, "文字已输入，并已读回确认。")
    }

    func testOpenAppRequiresVisibleForegroundWindow() async {
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unexpected")
        }, executeStep: { _, _, _, _ in
            self.deliveredUnverifiedResult("进程存在但没有可见前台窗口")
        })
        let result = await runner.run(goal: "打开备忘录", steps: [
            DesktopActionStep(action: .openApp, application: "备忘录")
        ])
        XCTAssertEqual(result.status, "uncertain_effect")
        let record = result.currentActions[0]
        XCTAssertEqual(record.completionPolicy, .outcomeRequired,
                       "open_app always requires outcome evidence, expectedLabel or not")
        XCTAssertTrue(record.uncertainEffect)
        XCTAssertEqual(result.spokenSummary,
                       "我发出了打开「备忘录」的请求，但没有确认到它的可见前台窗口，所以不能说已经打开。")
    }

    func testOpenAppCompletesWhenForegroundWindowIsVerified() async {
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "unexpected")
        }, executeStep: { _, _, _, _ in
            DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                                    detail: "可见前台窗口已确认", resultingApp: "fixture")
        })
        let result = await runner.run(goal: "打开备忘录", steps: [
            DesktopActionStep(action: .openApp, application: "备忘录")
        ])
        XCTAssertEqual(result.status, "completed")
        let record = result.currentActions[0]
        XCTAssertEqual(record.completionPolicy, .outcomeRequired)
        XCTAssertEqual(record.outcomeEvidence, .systemVerified)
        XCTAssertEqual(record.completionBasis, .systemVerifiedOutcome)
        XCTAssertTrue(record.verified)
        XCTAssertEqual(result.verifiedActionHistory, ["open_app「备忘录」：结果已验证"])
        XCTAssertEqual(result.satisfiedActionHistory, ["open_app「备忘录」：结果已验证"])
        XCTAssertEqual(result.spokenSummary, "已确认「备忘录」已启动。")
    }

    // MARK: - Delivery facts that never complete (behaviors 3 and 4)

    func testUnknownDeliveryIsUncertainAndNeverAutoRetried() async {
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return self.unknownDeliveryResult("驱动没有返回送达状态")
        })
        let result = await runner.run(goal: "点击目标", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label)
        ])
        XCTAssertEqual(result.status, "uncertain_effect")
        XCTAssertEqual(dispatches, 1, "unknown delivery must not trigger an automatic retry")
        XCTAssertEqual(result.currentActions[0].delivery, .unknown)
        XCTAssertTrue(result.currentActions[0].uncertainEffect)
    }

    func testNotSentDeliveryPausesWithoutCountingTheStep() async {
        var dispatches = 0
        let second = DesktopTaskTarget(id: "next", label: "下一步", source: "ocr",
                                       box: [10, 100, 100, 130], display: target.display)
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, second])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return DesktopTaskActionResult(delivery: .notSent, outcomeEvidence: .notObserved,
                                           detail: "权限不足。", failureStage: "driver",
                                           reasonCode: "not_permitted")
        })
        let result = await runner.run(goal: "完成两个步骤", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label),
            DesktopActionStep(action: .click, targetLabel: second.label)
        ])
        XCTAssertTrue(["paused", "failed"].contains(result.status))
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(result.completedStepCount, 0)
        XCTAssertTrue(result.detail.contains("权限不足"))
        XCTAssertEqual(result.actions, [], "A not-sent input is not a delivered action")
        let record = result.currentActions[0]
        XCTAssertEqual(record.delivery, .notSent)
        XCTAssertFalse(record.satisfied)
        XCTAssertFalse(record.uncertainEffect, "A not-sent input has no side effect to confirm")
        XCTAssertEqual(record.summary, "click「部署状态（3）」：未下发")

        let resumed = await runner.run(goal: "完成两个步骤", intent: .resume)
        XCTAssertNotEqual(resumed.status, "uncertain_effect",
                          "A not-sent input created no uncertain side effect to resolve")
        XCTAssertEqual(resumed.completedStepCount, 0)
    }

    // MARK: - Multi-step advancement and re-observation (behavior 6)

    /// A delivery-confirmed step may only advance after a FRESH observation
    /// for the next step: the loop must call observe() again and honor a
    /// changed target list instead of acting on the stale scene. The second
    /// step carries no target label (so the first step stays a pure
    /// delivery-sufficient click, not an outcome-required one) and is instead
    /// resolved through the decision fixture.
    func testDeliveryConfirmedStepAdvancesOnlyAfterFreshReobservation() async {
        var observationCalls = 0
        let second = DesktopTaskTarget(id: "next", label: "下一步", source: "ocr",
                                       box: [10, 100, 100, 130], display: target.display)
        let runner = DesktopTaskCoordinator(observe: {
            observationCalls += 1
            // The next step's target only exists in the post-action scene.
            return DesktopTaskObservation(app: "fixture",
                targets: observationCalls > 1 ? [self.target, second] : [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: second.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            self.deliveredUnverifiedResult("第一步输入已送达")
        })
        let result = await runner.run(goal: "完成两个步骤", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label),
            DesktopActionStep(action: .click)
        ])
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.completedStepCount, 2)
        // The second target is only visible from the second observation on, so
        // completing both steps proves the coordinator re-observed instead of
        // acting on the stale scene.
        XCTAssertGreaterThanOrEqual(observationCalls, 2,
                       "Advancing past a delivery-confirmed step must re-observe for the next step")
        XCTAssertEqual(result.satisfiedActionHistory,
                       ["click「部署状态（3）」：动作已送达", "click「下一步」：动作已送达"])
        XCTAssertTrue(result.verifiedActionHistory.isEmpty)
    }

    /// The coordinator copies step N+1's targetLabel into step N as an
    /// auto-derived expectedLabel, which makes step N outcomeRequired: a
    /// driver-sent-but-unverified step N must not advance to step N+1.
    func testAutoDerivedExpectedLabelBlocksAdvanceToNextStep() async {
        var dispatches = 0
        let second = DesktopTaskTarget(id: "next", label: "下一步", source: "ocr",
                                       box: [10, 100, 100, 130], display: target.display)
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, second])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return self.deliveredUnverifiedResult("点击已送达，预期目标未出现")
        })
        let result = await runner.run(goal: "先点再点", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label),
            DesktopActionStep(action: .click, targetLabel: second.label)
        ])
        XCTAssertEqual(result.status, "uncertain_effect")
        XCTAssertEqual(dispatches, 1,
                       "Step N was sent but its derived outcome never observed; step N+1 must not run")
        XCTAssertEqual(result.completedStepCount, 0)
        XCTAssertEqual(result.currentActions[0].completionPolicy, .outcomeRequired)
        XCTAssertTrue(result.currentActions[0].uncertainEffect)
    }

    // MARK: - Resume and cancel (behavior 7)

    /// A delivery-confirmed step counts as done forever: resuming the task
    /// never re-dispatches it, and the model receives it as already-done
    /// history through satisfiedActionHistory.
    func testResumingCarriesHistoryAndDoesNotRedispatchDeliveryConfirmedStep() async {
        var dispatches = 0
        var histories: [[String]] = []
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
                                            decide: { _, _, history, _ in
            histories.append(history)
            return DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return self.deliveredUnverifiedResult("点击已送达")
        })
        let first = await runner.run(goal: "点击目标")
        XCTAssertEqual(first.status, "completed")
        XCTAssertEqual(first.satisfiedActionHistory, ["click「部署状态（3）」：动作已送达"])
        XCTAssertTrue(first.verifiedActionHistory.isEmpty)

        let resumed = await runner.run(goal: "点击目标", intent: .resume)
        XCTAssertEqual(dispatches, 1, "A delivery-confirmed step must not be re-dispatched")
        XCTAssertEqual(histories.count, 1, "A finished plan must not consult the model again")
        XCTAssertEqual(resumed.priorActions.count, 1)
        XCTAssertTrue(resumed.currentActions.isEmpty)
        XCTAssertEqual(resumed.targetVersion, first.targetVersion,
                       "A plain resume keeps the task revision; only corrections bump it")
    }

    /// Resuming a plan with a satisfied first step continues with the
    /// remaining steps instead of restarting or skipping ahead. The second
    /// step carries no target label, so the first step is a pure
    /// delivery-sufficient click and the second is resolved through the
    /// decision fixture.
    func testResumeSkipsSatisfiedStepsAndContinuesWithRemainingOnes() async {
        let second = DesktopTaskTarget(id: "next", label: "下一步", source: "ocr",
                                       box: [10, 100, 100, 130], display: target.display)
        var dispatches = 0
        var runner: DesktopTaskCoordinator!
        runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, second])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: second.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            if dispatches == 1 { runner.interrupt() }
            return self.deliveredUnverifiedResult("输入已送达")
        })
        let first = await runner.run(goal: "完成两个步骤", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label),
            DesktopActionStep(action: .click)
        ])
        XCTAssertEqual(first.status, "paused")
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(first.satisfiedActionHistory, ["click「部署状态（3）」：动作已送达"])

        let resumed = await runner.run(goal: "完成两个步骤", intent: .resume)
        XCTAssertEqual(resumed.status, "completed")
        XCTAssertEqual(dispatches, 2,
                       "A satisfied step is not re-dispatched; the remaining step must still run")
        XCTAssertEqual(resumed.completedStepCount, 2)
        XCTAssertEqual(resumed.satisfiedActionHistory,
                       ["click「部署状态（3）」：动作已送达", "click「下一步」：动作已送达"])
        XCTAssertTrue(resumed.verifiedActionHistory.isEmpty)
    }

    /// The model's already-done history is satisfiedActionHistory, not the
    /// verified-only list: a delivery-confirmed first step is fed to the
    /// decision model when the remaining step needs a candidate.
    func testResumeDecisionHistoryReadsSatisfiedActionHistory() async {
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
            selected.id == self.target.id
                ? self.deliveredUnverifiedResult("第一步输入已送达")
                : self.verifiedResult("已确认 \(selected.label)")
        })
        _ = await runner.run(goal: "完成两个步骤", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label),
            DesktopActionStep(action: .click)
        ])
        let resumed = await runner.run(goal: "完成两个步骤", intent: .resume)
        XCTAssertEqual(resumed.status, "completed")
        XCTAssertEqual(resumed.verifiedActionHistory, ["click「下一步」：结果已验证"],
                       "Only the system-verified step enters the verified history")
        XCTAssertEqual(resumed.satisfiedActionHistory,
                       ["click「部署状态（3）」：动作已送达", "click「下一步」：结果已验证"])
        XCTAssertEqual(histories.count, 2)
        XCTAssertEqual(histories.last, ["click「部署状态（3）」：动作已送达"],
                       "The decision model reads satisfiedActionHistory as already-done, delivery-confirmed steps included")
    }

    func testResumeAfterUncertainEffectDoesNotSwitchToAnotherCandidate() async {
        // Reproduction of the candidate-switch accident: an unconfirmed click
        // on A followed by "continue" must not let the model try B instead.
        // The click carries an expected label, so it genuinely stays
        // outcomeRequired-unverified and uncertain.
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
            return self.deliveredUnverifiedResult("点击已送达，结果未确认")
        })
        let first = await runner.run(goal: "打开最新的会话", steps: [
            DesktopActionStep(action: .click, expectedLabel: "就绪")
        ])
        XCTAssertEqual(first.status, "uncertain_effect")
        XCTAssertEqual(first.currentActions[0].completionPolicy, .outcomeRequired)
        XCTAssertEqual(dispatched, [target.id])

        let resumed = await runner.run(goal: "打开最新的会话", intent: .resume)
        XCTAssertEqual(resumed.status, "uncertain_effect")
        XCTAssertEqual(dispatched, [target.id], "An unconfirmed attempt must not turn into a different candidate")
        XCTAssertTrue(resumed.currentActions.isEmpty)
        XCTAssertTrue(resumed.verifiedActionHistory.isEmpty,
                      "An unverified attempt is not part of the verified history")
        XCTAssertTrue(resumed.satisfiedActionHistory.isEmpty,
                      "An unsatisfied attempt is not part of the satisfied history")
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
            return DesktopTaskActionResult(
                delivery: .sent,
                outcomeEvidence: dispatched > 1 ? .systemVerified : .notObserved,
                detail: dispatched > 1 ? "已确认" : "结果未确认")
        })
        let first = await runner.run(goal: "点击目标", steps: [
            DesktopActionStep(action: .click, expectedLabel: "就绪")
        ])
        XCTAssertEqual(first.status, "uncertain_effect")
        XCTAssertEqual(dispatched, 1)

        // A brand-new explicit instruction is the user's authorization; the old
        // task's unconfirmed record must not block it.
        let fresh = await runner.run(goal: "点击部署状态", namedTarget: target.label)
        XCTAssertEqual(fresh.status, "completed")
        XCTAssertEqual(dispatched, 2)
        XCTAssertEqual(fresh.verifiedActionHistory, ["click「部署状态（3）」：结果已验证"])
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
            return dispatched.count == 2
                ? self.verifiedResult("已确认")
                : self.deliveredUnverifiedResult("结果未确认")
        })
        let first = await runner.run(goal: "打开最新的会话", steps: [
            DesktopActionStep(action: .click, expectedLabel: "就绪")
        ])
        XCTAssertEqual(first.status, "uncertain_effect")
        XCTAssertEqual(dispatched, [target.id])

        let corrected = await runner.run(goal: "不对，打开另一个会话", namedTarget: other.label,
            intent: .correct, uncertainResolution: .replaceTarget)
        XCTAssertEqual(corrected.status, "completed")
        XCTAssertEqual(dispatched, [target.id, other.id])
        XCTAssertEqual(corrected.priorActions.count, 1)
        XCTAssertTrue(corrected.priorActions[0].contains("结果未确认"))
        XCTAssertEqual(corrected.verifiedActionHistory, ["click「另一个会话」：结果已验证"])
        XCTAssertEqual(corrected.satisfiedActionHistory, ["click「另一个会话」：结果已验证"])
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
            return self.deliveredUnverifiedResult("结果未确认")
        })
        _ = await runner.run(goal: "打开最新的会话", steps: [
            DesktopActionStep(action: .click, expectedLabel: "就绪")
        ])
        // A correction that carries no resolution is still not authorization:
        // only replace_target (with an explicit new target) may proceed.
        let corrected = await runner.run(goal: "不对，打开另一个会话", namedTarget: other.label, intent: .correct)
        XCTAssertEqual(corrected.status, "uncertain_effect")
        XCTAssertEqual(dispatched, 1)
        XCTAssertTrue(corrected.currentActions.isEmpty)
    }

    func testConfirmedSucceededRecordsUserConfirmationWithoutNewSideEffect() async {
        var dispatched = 0
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatched += 1
            return self.deliveredUnverifiedResult("结果未确认")
        })
        let first = await runner.run(goal: "打开最新的会话", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label, expectedLabel: "就绪")
        ])
        XCTAssertEqual(first.status, "uncertain_effect")

        let resolved = await runner.run(goal: "打开最新的会话", intent: .resume,
            uncertainResolution: .confirmedSucceeded)
        XCTAssertEqual(resolved.status, "completed")
        XCTAssertEqual(dispatched, 1, "A confirmation performs no new side effect")
        // confirmed_succeeded is a USER confirmation: the step is satisfied and
        // joins the satisfied history with the user-confirmed wording, but it
        // never enters the system-verified history.
        XCTAssertEqual(resolved.satisfiedActionHistory, ["click「部署状态（3）」：用户已确认结果"])
        XCTAssertTrue(resolved.verifiedActionHistory.isEmpty,
                      "A user confirmation is not a system verification")
        XCTAssertEqual(resolved.priorActions, ["click「部署状态（3）」：结果未确认"])
        XCTAssertEqual(resolved.completedStepCount, 1)
        XCTAssertEqual(resolved.spokenSummary, "你已确认上一轮操作已经生效。")
    }

    func testConfirmedFailedClearsTheBlockAndKeepsTheAttemptUnverified() async {
        var dispatched: [String] = []
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, selected, _ in
            dispatched.append(selected.id)
            return dispatched.count == 2
                ? self.verifiedResult("已确认")
                : self.deliveredUnverifiedResult("结果未确认")
        })
        _ = await runner.run(goal: "打开最新的会话", steps: [
            DesktopActionStep(action: .click, targetLabel: target.label, expectedLabel: "就绪")
        ])
        XCTAssertEqual(dispatched, [target.id])

        let resolved = await runner.run(goal: "打开最新的会话", intent: .resume,
            uncertainResolution: .confirmedFailed)
        XCTAssertEqual(resolved.status, "completed")
        XCTAssertEqual(dispatched, [target.id, target.id])
        // The failed attempt remains attempted-unverified history; only the
        // retried, now-verified action enters the verified history.
        XCTAssertEqual(resolved.priorActions.count, 1)
        XCTAssertTrue(resolved.priorActions[0].contains("结果未确认"))
        XCTAssertEqual(resolved.verifiedActionHistory, ["click「部署状态（3）」：结果已验证"])
        XCTAssertEqual(resolved.satisfiedActionHistory, ["click「部署状态（3）」：结果已验证"],
                       "Only the retried, verified step counts as done")
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
            return dispatched.count == 2
                ? self.verifiedResult("已确认")
                : self.deliveredUnverifiedResult("结果未确认")
        })
        _ = await runner.run(goal: "打开最新的会话", steps: [
            DesktopActionStep(action: .click, expectedLabel: "就绪")
        ])
        XCTAssertEqual(dispatched, [target.id])

        // retry_same must re-run the SAME target, not let the decision layer
        // pick the runner-up candidate.
        let resolved = await runner.run(goal: "打开最新的会话", intent: .resume,
            uncertainResolution: .retrySame)
        XCTAssertEqual(resolved.status, "completed")
        XCTAssertEqual(dispatched, [target.id, target.id])
    }

    /// Cancel keeps the delivered facts on record and never executes the
    /// remaining steps.
    func testCancelKeepsDeliveredFactsAndSkipsRemainingSteps() async {
        let second = DesktopTaskTarget(id: "next", label: "下一步", source: "ocr",
                                       box: [10, 100, 100, 130], display: target.display)
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, second])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "")
        }, execute: { _, _, _, _ in
            dispatches += 1
            return self.deliveredUnverifiedResult("点击已送达，结果未确认")
        })
        runner.beginUserTurn("turn-cancel")
        _ = await runner.submit(DesktopTaskSubmission(
            goal: "完成两个步骤",
            steps: [
                DesktopActionStep(action: .click, targetLabel: target.label),
                DesktopActionStep(action: .click, targetLabel: second.label)
            ],
            turnID: "turn-cancel"))
        await runner.waitUntilSettled()
        let first = runner.lastReceipt
        XCTAssertEqual(first?.status, "uncertain_effect")
        XCTAssertEqual(dispatches, 1)

        let cancelled = runner.cancelTask(taskID: first!.taskID, targetVersion: first!.targetVersion,
                                          turnID: "turn-cancel")
        XCTAssertEqual(cancelled?.status, "cancelled")
        XCTAssertEqual(cancelled?.currentActions.count, 1, "Delivered facts stay on the record")
        XCTAssertEqual(cancelled?.currentActions.first?.label, target.label)
        XCTAssertEqual(cancelled?.spokenSummary, "任务已取消，已经发生的操作记录保留。")
        XCTAssertEqual(dispatches, 1, "Cancel stops the remaining steps from executing")
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
            return self.verifiedResult("菜单已打开")
        })
        let result = await runner.run(goal: "右键目标", action: "right_click")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(routes, [false, true])
        XCTAssertEqual(dispatchedAction, "right_click")
        XCTAssertEqual(observations, 3)
    }
}
