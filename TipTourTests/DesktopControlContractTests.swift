import Foundation
import CoreGraphics
import XCTest
@testable import TipTour

@MainActor
final class DesktopControlContractTests: XCTestCase {
    private let target = DesktopTaskTarget(id: "target-os", label: "os", source: "ax",
        box: [10, 20, 100, 50], display: [0, 0, 1000, 800])

    func testReceiptNeverSpeaksHistoricalActionsAsNewWork() {
        let receipt = DesktopTaskReceipt(goal: "点击 os", status: "needs_clarification", actions: [],
            detail: "没有找到指定目标。", priorActions: ["click By-Your-Side: completed"])
        XCTAssertTrue(receipt.spokenSummary.contains("没有执行"))
        XCTAssertFalse(receipt.spokenSummary.contains("By-Your-Side"))
        XCTAssertFalse(receipt.spokenSummary.contains("已点击"))
    }

    func testReceiptCompletionStatusAloneCannotProduceSuccessSpeech() {
        let record = DesktopActionRecord(id: "attempt", observationID: "obs", app: "fixture", targetID: target.id,
            label: target.label, action: .click, decisionPacket: nil, delivery: .sent, verified: false, detail: "page changed")
        let receipt = DesktopTaskReceipt(goal: "打开 os", status: "completed", actions: [record.summary],
            detail: "model said done", currentActions: [record])
        XCTAssertTrue(receipt.spokenSummary.contains("没有确认"))
        XCTAssertFalse(receipt.spokenSummary.contains("已确认"))
    }

    func testReceiptRoundTripSeparatesHistoricalAndCurrentRecords() throws {
        let receipt = DesktopTaskReceipt(goal: "新目标", status: "paused", actions: [], detail: "尚未执行",
            taskID: "task", turnID: "turn-2", targetVersion: 2, priorActions: ["previous"])
        let decoded = try JSONDecoder().decode(DesktopTaskReceipt.self, from: Data(receipt.toolOutput.utf8))
        XCTAssertEqual(decoded.turnID, "turn-2")
        XCTAssertEqual(decoded.targetVersion, 2)
        XCTAssertEqual(decoded.priorActions, ["previous"])
        XCTAssertTrue(decoded.currentActions.isEmpty)
    }

    func testExplicitLabelAndRegionAreIntersectedRatherThanRankedTogether() {
        let other = DesktopTaskTarget(id: "right-os", label: "os", source: "ax",
            box: [700, 20, 800, 50], display: target.display)
        let unrelated = DesktopTaskTarget(id: "unrelated", label: "项目", source: "ax",
            box: [10, 100, 100, 130], display: target.display)
        let observation = DesktopTaskObservation(app: "fixture", targets: [target, other, unrelated])
        XCTAssertEqual(DesktopActionStep(targetLabel: "OS", region: .left).candidates(in: observation), [target])
        XCTAssertTrue(DesktopActionStep(targetLabel: "missing").candidates(in: observation).isEmpty)
    }

    func testRelativeAnchorMustBeUniqueAndUsesAppKitVerticalDirection() {
        let anchor = DesktopTaskTarget(id: "folder", label: "文件夹", source: "ax",
            box: [10, 60, 100, 90], display: target.display)
        let step = DesktopActionStep(targetLabel: "os", anchorLabel: "文件夹", relation: .below)
        XCTAssertEqual(step.candidates(in: DesktopTaskObservation(app: "fixture", targets: [target, anchor])), [target])
        XCTAssertTrue(step.candidates(in: DesktopTaskObservation(app: "fixture", targets: [target, anchor, anchor])).isEmpty)
    }

    func testPrimitiveParametersMustExistAndRemainBounded() {
        XCTAssertThrowsError(try DesktopActionStep(action: .openApp).validate())
        XCTAssertThrowsError(try DesktopActionStep(action: .type, text: "hello").validate())
        XCTAssertThrowsError(try DesktopActionStep(action: .pressKey).validate())
        XCTAssertThrowsError(try DesktopActionStep(action: .scroll, direction: "down", amount: 100).validate())
        XCTAssertThrowsError(try DesktopActionStep(anchorLabel: "文件夹").validate())
        XCTAssertNoThrow(try DesktopActionStep(action: .openApp, application: "Calculator").validate())
        XCTAssertNoThrow(try DesktopActionStep(action: .type, targetLabel: "输入框", text: "测试").validate())
    }

    func testOpenApplicationUsesLightweightContextInsteadOfScreenPerception() async {
        var screenObservations = 0
        var contextObservations = 0
        var dispatched: [DesktopActionKind] = []
        let runner = DesktopTaskCoordinator(observe: {
            screenObservations += 1
            return DesktopTaskObservation(app: "source", targets: [])
        }, observeContext: {
            contextObservations += 1
            return DesktopTaskObservation(app: "source", targets: [])
        }, decide: { _, _, _, _ in
            XCTFail("open_app must not ask a screen decision model")
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "")
        }, executeStep: { _, _, _, step in
            dispatched.append(step.action)
            return DesktopTaskActionResult(completed: true, detail: "application foreground verified", resultingApp: "target")
        })
        let result = await runner.run(goal: "打开计算器", steps: [
            DesktopActionStep(action: .openApp, application: "计算器")
        ])
        XCTAssertEqual(screenObservations, 0)
        XCTAssertEqual(contextObservations, 1)
        XCTAssertEqual(dispatched, [.openApp])
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.app, "target")
    }

    func testDecisionSelectedPointerActionReachesExecutorAndPacket() async {
        var executedActions: [DesktopActionKind] = []
        var step = DesktopActionStep()
        step.allowsActionDecision = true
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decideWithStep: { _, _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "double_click", completed: false,
                reason: "fanout", source: .jevFanout, actionProbability: 0.82, actionMargin: 0.61,
                targetProbability: 0.91, targetMargin: 0.74)
        }, executeStep: { _, _, _, selectedStep in
            executedActions.append(selectedStep.action)
            return DesktopTaskActionResult(completed: true, detail: "verified")
        })
        let result = await runner.run(goal: "打开那个项目", steps: [step])
        XCTAssertEqual(executedActions, [.doubleClick])
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.currentActions.first?.action, .doubleClick)
        XCTAssertEqual(result.currentActions.first?.decisionPacket?.source, .jevFanout)
        XCTAssertEqual(result.currentActions.first?.decisionPacket?.confidence.action, 0.82)
        XCTAssertEqual(result.currentActions.first?.decisionPacket?.confidence.target, 0.91)
        XCTAssertEqual(result.currentActions.first?.decisionPacket?.evidence.contains("speculative_fanout"), true)
    }

    func testExplicitPointerActionCannotBeOverriddenByDecisionLayer() async {
        var executedActions: [DesktopActionKind] = []
        let step = DesktopActionStep(action: .rightClick)
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target])
        }, decideWithStep: { _, _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false,
                reason: "model disagrees", source: .jevFanout, actionProbability: 0.95,
                targetProbability: 0.88)
        }, executeStep: { _, _, _, selectedStep in
            executedActions.append(selectedStep.action)
            return DesktopTaskActionResult(completed: true, detail: "verified")
        })
        let result = await runner.run(goal: "右键目标", steps: [step])
        XCTAssertEqual(executedActions, [.rightClick])
        XCTAssertEqual(result.currentActions.first?.decisionPacket?.action, .rightClick)
        XCTAssertEqual(result.currentActions.first?.decisionPacket?.confidence.action, 1)
        XCTAssertEqual(result.currentActions.first?.decisionPacket?.confidence.target, 0.88)
        XCTAssertEqual(result.currentActions.first?.decisionPacket?.evidence.contains("action_locked"), true)
    }

    func testGeneralModelSelectionDoesNotInventConfidence() {
        let modelDecision = DesktopTaskDecision(targetID: target.id, action: "click", completed: false,
            reason: "selected", source: .generalModel)
        let packet = DesktopDecisionPacket.make(
            step: DesktopActionStep(action: .click),
            target: target,
            intent: .new,
            scope: .single,
            modelDecision: modelDecision
        )
        XCTAssertEqual(packet.confidence.action, 1, "Explicit action is code-owned")
        XCTAssertNil(packet.confidence.target, "A generative selector supplied no calibrated target probability")
        XCTAssertNil(packet.confidence.whereValue)
    }

    func testDeterministicExactTargetCarriesDeterministicConfidence() {
        let packet = DesktopDecisionPacket.make(
            step: DesktopActionStep(action: .click, targetLabel: target.label),
            target: target,
            intent: .new,
            scope: .single,
            modelDecision: nil
        )
        XCTAssertEqual(packet.source, .deterministic)
        XCTAssertEqual(packet.confidence.action, 1)
        XCTAssertEqual(packet.confidence.target, 1)
        XCTAssertEqual(packet.confidence.whereValue, 1)
    }

    func testLocalizedApplicationNamesResolveToOneStableBundleIdentity() {
        let weChat = DesktopApplicationCandidate(
            bundleIdentifier: "com.tencent.xinWeChat",
            url: URL(fileURLWithPath: "/Applications/WeChat.app"),
            names: ["WeChat", "微信"]
        )
        for query in ["微信", "微信应用", " WeChat ", "WECHAT.app"] {
            XCTAssertEqual(
                DesktopApplicationResolver.match(query: query, candidates: [weChat]),
                .resolved(weChat)
            )
        }
    }

    func testNestedHelperProcessesBelongToTheInstalledApplicationIdentity() {
        let application = DesktopApplicationCandidate(
            bundleIdentifier: "com.bot.pc.doubao",
            url: URL(fileURLWithPath: "/Applications/Doubao.app"),
            names: ["豆包"]
        )
        XCTAssertTrue(application.contains(bundleURL: URL(fileURLWithPath: "/Applications/Doubao.app")))
        XCTAssertTrue(application.contains(bundleURL: URL(fileURLWithPath:
            "/Applications/Doubao.app/Contents/Helpers/Doubao Browser.app")))
        XCTAssertFalse(application.contains(bundleURL: URL(fileURLWithPath: "/Applications/Other.app")))
    }

    func testUnverifiedOpenApplicationSpeechNeverClaimsSuccess() {
        let record = DesktopActionRecord(id: "attempt", observationID: "obs", app: "fixture", targetID: nil,
            label: "豆包", action: .openApp, decisionPacket: nil, delivery: .sent, verified: false,
            detail: "目标应用进程已运行，但当前没有可见窗口，不能报告已打开。")
        let receipt = DesktopTaskReceipt(goal: "打开豆包", status: "paused", actions: [record.summary],
            detail: record.detail, currentActions: [record])
        XCTAssertTrue(receipt.spokenSummary.contains("不能说已经打开"))
        XCTAssertFalse(receipt.spokenSummary.contains("已确认"))
    }

    func testExplicitBrandAliasStillRequiresThatApplicationToBeInstalled() {
        let chrome = DesktopApplicationCandidate(
            bundleIdentifier: "com.google.Chrome",
            url: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            names: ["Google Chrome", "Chrome"]
        )
        XCTAssertEqual(
            DesktopApplicationResolver.match(
                query: "谷歌浏览器",
                candidates: [chrome],
                aliases: ["谷歌浏览器": "com.google.Chrome"]
            ),
            .resolved(chrome)
        )
        XCTAssertEqual(
            DesktopApplicationResolver.match(
                query: "谷歌浏览器",
                candidates: [],
                aliases: ["谷歌浏览器": "com.google.Chrome"]
            ),
            .notFound
        )
    }

    func testAmbiguousApplicationNameDoesNotPickTheFirstInstalledBundle() {
        let first = DesktopApplicationCandidate(bundleIdentifier: "example.one",
            url: URL(fileURLWithPath: "/Applications/One.app"), names: ["工具"])
        let second = DesktopApplicationCandidate(bundleIdentifier: "example.two",
            url: URL(fileURLWithPath: "/Applications/Two.app"), names: ["工具"])
        let result = DesktopApplicationResolver.match(query: "工具", candidates: [first, second])
        guard case .ambiguous(let matches) = result else {
            return XCTFail("Expected a real ambiguity instead of arbitrary selection")
        }
        XCTAssertEqual(Set(matches.map(\.bundleIdentifier)), ["example.one", "example.two"])
    }

    func testMissingNamedTargetDoesNotCallSemanticModelEvenAtHighConfidence() async {
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
            decide: { _, _, _, _ in
                XCTFail("An empty constrained candidate set must not reach the model")
                return DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "1.0")
            }, execute: { _, _, _, _ in
                XCTFail("No unrelated click")
                return DesktopTaskActionResult(completed: false, detail: "unexpected")
            })
        let result = await runner.run(goal: "点击不存在的目标", namedTarget: "missing")
        XCTAssertEqual(result.status, "needs_clarification")
        XCTAssertTrue(result.currentActions.isEmpty)
    }

    func testSameNameAtTwoPositionsDoesNotPickTheFirst() async {
        let other = DesktopTaskTarget(id: "other", label: "os", source: "ax", box: [300, 20, 390, 50], display: target.display)
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target, other]) },
            decide: { _, _, _, _ in
                XCTFail("Literal ambiguity requires a constraint, not arbitrary ranking")
                return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "")
            }, execute: { _, _, _, _ in
                dispatches += 1
                return DesktopTaskActionResult(completed: true, detail: "unexpected")
            })
        let result = await runner.run(goal: "点击 os", namedTarget: "os")
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(result.status, "needs_clarification")
    }

    func testReusedIDWithChangedLabelCannotPassDecisionRevalidation() async {
        var observations = 0
        let changed = DesktopTaskTarget(id: target.id, label: "其他任务", source: "ax", box: target.box, display: target.display)
        let runner = DesktopTaskCoordinator(observe: {
            observations += 1
            return DesktopTaskObservation(app: "fixture", targets: [observations == 1 ? self.target : changed])
        }, decide: { _, _, _, _ in
            DesktopTaskDecision(targetID: self.target.id, action: "click", completed: false, reason: "chosen")
        }, execute: { _, _, _, _ in
            XCTFail("A recycled ID is not the same target")
            return DesktopTaskActionResult(completed: false, detail: "unexpected")
        })
        let result = await runner.run(goal: "点击刚才那个")
        XCTAssertEqual(result.status, "paused")
        XCTAssertTrue(result.currentActions.isEmpty)
    }

    func testUnverifiedFirstStepPreventsAllFollowingSteps() async {
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
            decide: { _, _, _, _ in
                XCTFail("Exact target should bypass model")
                return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "")
            }, execute: { _, _, _, _ in
                dispatches += 1
                return DesktopTaskActionResult(completed: false, detail: "driver sent but goal unverified", delivery: .sent)
            })
        let result = await runner.run(goal: "执行两个明确步骤", steps: [
            DesktopActionStep(targetLabel: target.label), DesktopActionStep(targetLabel: target.label)
        ])
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(result.status, "uncertain_effect")
    }

    func testResumingSamePlanDoesNotRepeatItsVerifiedFirstStep() async {
        let second = DesktopTaskTarget(id: "next", label: "第二步", source: "ax", box: [10, 100, 100, 130], display: target.display)
        var secondVisible = false
        var clicked: [String] = []
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: secondVisible ? [self.target, second] : [self.target])
        }, decide: { _, _, _, _ in
            XCTFail("Exact steps do not need a model")
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "")
        }, execute: { _, _, target, _ in
            clicked.append(target.id)
            return DesktopTaskActionResult(completed: true, detail: "independent state confirmed")
        })
        _ = await runner.run(goal: "两个步骤", steps: [DesktopActionStep(targetLabel: target.label), DesktopActionStep(targetLabel: second.label)])
        secondVisible = true
        let resumed = await runner.run(goal: "两个步骤", intent: .resume)
        XCTAssertEqual(clicked, [target.id, second.id])
        XCTAssertEqual(resumed.status, "completed")
        XCTAssertEqual(resumed.actions.count, 1)
        XCTAssertEqual(resumed.priorActions.count, 1)
    }

    func testUnknownTargetlessActionCannotBeReplayedOnResume() async {
        var dispatches = 0
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: []) },
            decide: { _, _, _, _ in
                XCTFail("Key actions do not rank screen controls")
                return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "")
            }, executeStep: { _, _, _, _ in
                dispatches += 1
                return DesktopTaskActionResult(completed: false, detail: "unknown", delivery: .unknown)
            })
        _ = await runner.run(goal: "向下滚动", steps: [DesktopActionStep(action: .scroll, direction: "down")])
        let resumed = await runner.run(goal: "向下滚动", intent: .resume)
        XCTAssertEqual(dispatches, 1)
        XCTAssertTrue(resumed.actions.isEmpty)
    }

    func testRejectedBeforeDispatchHasNoNewActionClaim() async {
        let runner = DesktopTaskCoordinator(observe: { DesktopTaskObservation(app: "fixture", targets: [self.target]) },
            decide: { _, _, _, _ in DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "") },
            execute: { _, _, _, _ in DesktopTaskActionResult(completed: false, detail: "权限不足。", delivery: .notSent) })
        let result = await runner.run(goal: "点击 os", namedTarget: "os")
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.spokenSummary.contains("没有执行"))
        XCTAssertTrue(result.spokenSummary.contains("权限不足"))
    }

    func testVerifiedActionInterruptedBeforeReceiptIsNotRepeatedOnResume() async {
        let second = DesktopTaskTarget(id: "next", label: "第二步", source: "ax",
            box: [10, 100, 100, 130], display: target.display)
        var clicked: [String] = []
        var runner: DesktopTaskCoordinator!
        runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: [self.target, second])
        }, decide: { _, _, _, _ in
            XCTFail("Exact steps should not need a model")
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "")
        }, execute: { _, _, selected, _ in
            clicked.append(selected.id)
            if clicked.count == 1 { runner.interrupt() }
            return DesktopTaskActionResult(completed: true, detail: "独立结果已确认")
        })
        let interrupted = await runner.run(goal: "两个明确步骤", steps: [
            DesktopActionStep(targetLabel: target.label), DesktopActionStep(targetLabel: second.label)
        ])
        XCTAssertEqual(interrupted.status, "paused")
        XCTAssertEqual(interrupted.currentActions.first?.verified, true)
        let resumed = await runner.run(goal: "两个明确步骤", intent: .resume)
        XCTAssertEqual(clicked, [target.id, second.id])
        XCTAssertEqual(resumed.actions.count, 1)
        XCTAssertEqual(resumed.status, "completed")
    }

    func testRejectedNewTaskCannotResumeAnUnrelatedOldPlan() async {
        let second = DesktopTaskTarget(id: "next", label: "旧任务第二步", source: "ax",
            box: [10, 100, 100, 130], display: target.display)
        var secondVisible = false
        var clicked: [String] = []
        let runner = DesktopTaskCoordinator(observe: {
            DesktopTaskObservation(app: "fixture", targets: secondVisible ? [self.target, second] : [self.target])
        }, decide: { _, _, _, _ in
            XCTFail("An invalid resume must not be turned into a new model decision")
            return DesktopTaskDecision(targetID: nil, action: "none", completed: false, reason: "")
        }, execute: { _, _, selected, _ in
            clicked.append(selected.id)
            return DesktopTaskActionResult(completed: true, detail: "独立结果已确认")
        })
        _ = await runner.run(goal: "旧任务", steps: [
            DesktopActionStep(targetLabel: target.label), DesktopActionStep(targetLabel: second.label)
        ])
        let rejected = await runner.run(goal: "参数无效的新任务", steps: [])
        XCTAssertEqual(rejected.status, "failed")
        secondVisible = true
        let resumed = await runner.run(goal: "参数无效的新任务", intent: .resume)
        XCTAssertEqual(clicked, [target.id])
        XCTAssertTrue(resumed.currentActions.isEmpty)
        XCTAssertNotEqual(resumed.status, "completed")
    }
}

@MainActor
final class DesktopObservedWindowIdentityTests: XCTestCase {
    private let identity = DesktopObservedWindowIdentity(
        bundleIdentifier: "com.example.app", processIdentifier: 42, windowID: 7,
        frame: CGRect(x: 100, y: 100, width: 800, height: 600),
        capturedAt: Date(), contentVersion: 3, contentFingerprint: 0x0123456789ABCDEF)

    private func makeImage(fill: UInt8, marks: [CGPoint] = []) -> CGImage {
        let width = 32, height = 32
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: CGFloat(fill) / 255, green: CGFloat(fill) / 255, blue: CGFloat(fill) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        for mark in marks {
            context.fill(CGRect(x: mark.x, y: mark.y, width: 8, height: 8))
        }
        return context.makeImage()!
    }

    func testVisionAnswerSurvivesWhenTheSameWindowIsUnchanged() {
        XCTAssertTrue(identity.isStillCurrent(
            frontmostBundleIdentifier: "com.example.app", frontmostWindowID: 7,
            currentWindowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            observedProcessStillExists: true, currentContentVersion: 3, maximumAge: 20))
    }

    func testVisionAnswerIsDiscardedWhenTheAppShowsADifferentWindow() {
        // Same app, same process, unchanged content version — but the frontmost
        // window is no longer the captured one. The description must not answer
        // for a window it never saw.
        XCTAssertFalse(identity.isStillCurrent(
            frontmostBundleIdentifier: "com.example.app", frontmostWindowID: 8,
            currentWindowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            observedProcessStillExists: true, currentContentVersion: 3, maximumAge: 20))
    }

    func testVisionAnswerIsDiscardedWhenTheWindowMovedOrClosed() {
        XCTAssertFalse(identity.isStillCurrent(
            frontmostBundleIdentifier: "com.example.app", frontmostWindowID: 7,
            currentWindowFrame: CGRect(x: 260, y: 100, width: 800, height: 600),
            observedProcessStillExists: true, currentContentVersion: 3, maximumAge: 20))
        XCTAssertFalse(identity.isStillCurrent(
            frontmostBundleIdentifier: "com.example.app", frontmostWindowID: 7,
            currentWindowFrame: nil,
            observedProcessStillExists: true, currentContentVersion: 3, maximumAge: 20))
    }

    func testVisionAnswerIsDiscardedWhenAppContentOrProcessChangedOrCaptureAgedOut() {
        XCTAssertFalse(identity.isStillCurrent(
            frontmostBundleIdentifier: "com.example.other", frontmostWindowID: 7,
            currentWindowFrame: identity.frame,
            observedProcessStillExists: true, currentContentVersion: 3, maximumAge: 20))
        XCTAssertFalse(identity.isStillCurrent(
            frontmostBundleIdentifier: "com.example.app", frontmostWindowID: 7,
            currentWindowFrame: identity.frame,
            observedProcessStillExists: false, currentContentVersion: 3, maximumAge: 20))
        XCTAssertFalse(identity.isStillCurrent(
            frontmostBundleIdentifier: "com.example.app", frontmostWindowID: 7,
            currentWindowFrame: identity.frame,
            observedProcessStillExists: true, currentContentVersion: 4, maximumAge: 20))
        let agedOut = DesktopObservedWindowIdentity(
            bundleIdentifier: identity.bundleIdentifier, processIdentifier: identity.processIdentifier,
            windowID: identity.windowID, frame: identity.frame,
            capturedAt: Date().addingTimeInterval(-60), contentVersion: identity.contentVersion,
            contentFingerprint: identity.contentFingerprint)
        XCTAssertFalse(agedOut.isStillCurrent(
            frontmostBundleIdentifier: "com.example.app", frontmostWindowID: 7,
            currentWindowFrame: identity.frame,
            observedProcessStillExists: true, currentContentVersion: 3, maximumAge: 20))
    }

    // MARK: Content fingerprint

    func testSameWindowContentChangeIsRejected() {
        // The app navigated inside the same window: no window event, no bundle
        // or process change, but the answer was computed for different pixels.
        // The 9×8 reduction cannot see a one-control repaint, but a navigated
        // page or a new dialog moves far more than the noise tolerance.
        let before = makeImage(fill: 255, marks: [CGPoint(x: 4, y: 4)])
        let after = makeImage(fill: 255, marks: [
            CGPoint(x: 4, y: 4), CGPoint(x: 16, y: 16), CGPoint(x: 24, y: 4), CGPoint(x: 8, y: 24)
        ])
        let observed = DesktopObservedWindowIdentity(
            bundleIdentifier: identity.bundleIdentifier, processIdentifier: identity.processIdentifier,
            windowID: identity.windowID, frame: identity.frame, capturedAt: Date(),
            contentVersion: identity.contentVersion,
            contentFingerprint: DesktopWindowContentFingerprint.hash(of: before))
        XCTAssertFalse(observed.contentStillMatches(DesktopWindowContentFingerprint.hash(of: after)),
                       "same-window-content-change: stale answer rejected")
    }

    func testUnchangedWindowContentSurvives() {
        let image = makeImage(fill: 200, marks: [CGPoint(x: 8, y: 8), CGPoint(x: 20, y: 4)])
        let observed = DesktopObservedWindowIdentity(
            bundleIdentifier: identity.bundleIdentifier, processIdentifier: identity.processIdentifier,
            windowID: identity.windowID, frame: identity.frame, capturedAt: Date(),
            contentVersion: identity.contentVersion,
            contentFingerprint: DesktopWindowContentFingerprint.hash(of: image))
        XCTAssertTrue(observed.contentStillMatches(DesktopWindowContentFingerprint.hash(of: image)))
    }

    func testFingerprintIsStableAndToleratesRenderingNoise() {
        let image = makeImage(fill: 180, marks: [CGPoint(x: 6, y: 6)])
        let observed = DesktopObservedWindowIdentity(
            bundleIdentifier: identity.bundleIdentifier, processIdentifier: identity.processIdentifier,
            windowID: identity.windowID, frame: identity.frame, capturedAt: Date(),
            contentVersion: identity.contentVersion,
            contentFingerprint: DesktopWindowContentFingerprint.hash(of: image))
        // Stable across identical re-renders.
        XCTAssertEqual(DesktopWindowContentFingerprint.hash(of: image),
                       DesktopWindowContentFingerprint.hash(of: image))
        // A global brightness shift (recompression/rendering noise) moves no
        // comparison bits, so it must not read as a content change.
        let brighter = makeImage(fill: 190, marks: [CGPoint(x: 6, y: 6)])
        XCTAssertTrue(observed.contentStillMatches(DesktopWindowContentFingerprint.hash(of: brighter)))
    }
}

@MainActor
final class DesktopVerificationTests: XCTestCase {
    private let target = DesktopTaskTarget(id: "field", label: "输入框", source: "ax", box: [10, 20, 100, 50], display: [0, 0, 1000, 800])
    private var field: DesktopAccessibleControl {
        DesktopAccessibleControl(label: target.label, role: "AXTextField", box: target.box, focused: true, value: "旧")
    }

    func testGenericChangedTargetsDoNotProveAClickSucceeded() {
        let afterTarget = DesktopTaskTarget(id: "changed", label: "其他内容", source: "ocr", box: target.box, display: target.display)
        XCTAssertFalse(DesktopActionVerifier.verify(step: DesktopActionStep(), target: target,
            before: [], after: [], beforeTargets: [target], afterTargets: [afterTarget]))
    }

    func testExpectedLabelMustBeNewlyVisible() {
        let step = DesktopActionStep(expectedLabel: target.label)
        XCTAssertFalse(DesktopActionVerifier.verify(step: step, target: target,
            before: [], after: [], beforeTargets: [target], afterTargets: [target]))
        XCTAssertTrue(DesktopActionVerifier.verify(step: step, target: target,
            before: [], after: [], beforeTargets: [], afterTargets: [target]))
    }

    func testOnlyCorrectTargetsSelectedStateCounts() {
        let wrong = DesktopAccessibleControl(label: target.label, role: "AXRow", box: [500, 20, 600, 50], selected: true)
        let correct = DesktopAccessibleControl(label: target.label, role: "AXRow", box: target.box, selected: true)
        XCTAssertFalse(DesktopActionVerifier.verify(step: DesktopActionStep(), target: target,
            before: [], after: [wrong], beforeTargets: [target], afterTargets: [target]))
        XCTAssertTrue(DesktopActionVerifier.verify(step: DesktopActionStep(), target: target,
            before: [], after: [correct], beforeTargets: [target], afterTargets: [target]))
    }

    func testExactUnicodeInsertionUsesTheObservedSelection() {
        var before = field
        before.value = "你好🌱世界"
        before.selectionStart = 2
        before.selectionLength = 2
        var after = field
        after.value = "你好测试世界"
        let step = DesktopActionStep(action: .type, targetLabel: target.label, text: "测试")
        XCTAssertTrue(DesktopActionVerifier.verify(step: step, target: target,
            before: [before], after: [after], beforeTargets: [target], afterTargets: [target]))
        after.value = "你好测试其他"
        XCTAssertFalse(DesktopActionVerifier.verify(step: step, target: target,
            before: [before], after: [after], beforeTargets: [target], afterTargets: [target]))
    }

    func testExpectedLabelCannotHideIncorrectTypedContent() {
        var after = field
        after.value = "写错了"
        XCTAssertFalse(DesktopActionVerifier.verify(
            step: DesktopActionStep(action: .type, targetLabel: target.label, text: "正确", expectedLabel: target.label),
            target: target, before: [field], after: [after], beforeTargets: [], afterTargets: [target]))
    }

    func testExistingFocusDoesNotProveAnotherClick() {
        XCTAssertFalse(DesktopActionVerifier.verify(step: DesktopActionStep(), target: target,
            before: [field], after: [field], beforeTargets: [target], afterTargets: [target]))
    }
}

@MainActor
final class DesktopVoiceBoundaryTests: XCTestCase {
    func testVerifiedReceiptAcceptsOnlyPunctuationAndSpacingDifferences() {
        XCTAssertTrue(StepFunVerifiedReceiptSpeech.matches(
            expected: "已确认「系统设置」已启动。",
            transcript: " 已确认 系统设置, 已启动 "
        ))
    }

    func testVerifiedReceiptRejectsAddedSuccessClaim() {
        XCTAssertFalse(StepFunVerifiedReceiptSpeech.matches(
            expected: "这次没有执行操作。",
            transcript: "这次没有执行操作，但已经帮你完成了。"
        ))
    }

    func testVerifiedReceiptRejectsMissingUncertainty() {
        XCTAssertFalse(StepFunVerifiedReceiptSpeech.matches(
            expected: "操作结果还不确定，已停下。",
            transcript: "操作结果已确定。"
        ))
    }

    func testCancelledResponseCannotDispatchLateCallsOrRevive() {
        var boundary = StepFunResponseBoundary()
        XCTAssertTrue(boundary.begin(id: "old"))
        boundary.cancel()
        XCTAssertFalse(boundary.acceptCall(id: "late", responseID: "old"))
        XCTAssertFalse(boundary.begin(id: "old"))
        XCTAssertTrue(boundary.begin(id: "new"))
        XCTAssertFalse(boundary.accepts(responseID: "old"))
        XCTAssertTrue(boundary.accepts(responseID: "new"))
    }

    func testManifestAndStreamCannotDispatchTheSameToolTwice() {
        var boundary = StepFunResponseBoundary()
        XCTAssertTrue(boundary.begin(id: "response"))
        XCTAssertTrue(boundary.acceptCall(id: "call", responseID: "response"))
        XCTAssertFalse(boundary.acceptCall(id: "call", responseID: "response"))
        boundary.complete()
        XCTAssertFalse(boundary.acceptCall(id: "another", responseID: "response"))
    }

    func testDefaultTraceDoesNotContainSensitivePayload() {
        let record = DesktopVoiceTrace.encodedEvent("tool", turnID: "turn", fields: ["status": "paused"],
            privateFields: ["transcript": "私人原话", "arguments": "私人文件名"], includePrivate: false)
        XCTAssertTrue(record.contains("paused"))
        XCTAssertFalse(record.contains("私人"))
        let diagnostic = DesktopVoiceTrace.encodedEvent("tool", turnID: "turn", fields: [:],
            privateFields: ["transcript": "私人原话"], includePrivate: true)
        XCTAssertTrue(diagnostic.contains("私人原话"))
    }
}
