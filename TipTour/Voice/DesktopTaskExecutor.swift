import AppKit
import Foundation

struct DesktopExecutionContext: Equatable {
    let app: String
    let processIdentifier: pid_t
    let windowID: Int?
    let contentVersion: Int
}

/// Adapter, not a second driver. Every side effect passes through the existing
/// engine; the adapter adds task-specific before/after evidence.
@MainActor
final class DesktopTaskExecutor {
    private let engine: TipTourEngine
    private let currentContext: () -> DesktopExecutionContext?

    init(engine: TipTourEngine, currentContext: @escaping () -> DesktopExecutionContext?) {
        self.engine = engine
        self.currentContext = currentContext
    }

    func execute(goal: String, observation: DesktopTaskObservation,
                 target: DesktopTaskTarget?, step: DesktopActionStep) async throws -> DesktopTaskActionResult {
        try step.validate()
        try Task.checkCancellation()
        let permissions = engine.observe()
        guard permissions.isCuaActionDriverEnabled, permissions.isAutopilotEnabled else {
            return notSent("需要先开启桌面操作和自动操作权限。", stage: "permission", reason: "automation_disabled")
        }
        if step.action == .openApp {
            return await executeOpenApplication(goal: goal, observation: observation, step: step)
        }
        guard let context = currentContext(), context.app == observation.app,
              context.windowID == observation.windowID, context.contentVersion == observation.contentVersion,
              Date().timeIntervalSince(observation.capturedAt) < 20 else {
            return notSent("观察已过期或窗口已改变，未发送操作。", stage: "context", reason: "context_changed")
        }
        let beforeControls = await readAccessibility(processIdentifier: context.processIdentifier)
        try Task.checkCancellation()
        guard currentContext() == context else { return notSent("验证目标期间界面上下文已变化。") }

        if step.action == .type {
            guard let target else { return notSent("输入缺少明确字段。") }
            let matching = DesktopActionVerifier.matchingControls(target, in: beforeControls)
                .filter { $0.isTextField && $0.focused == true }
            guard matching.count == 1 else { return notSent("指定字段尚未获得焦点；请先用明确的点击步骤聚焦。") }
        }

        let delivery: DesktopActionDelivery
        switch step.action {
        case .click, .doubleClick, .rightClick:
            guard let target else { return notSent("没有已绑定的点击目标。") }
            let result = await engine.runPointerAction(PointerActionRequest(goal: goal, app: observation.app,
                actionType: WorkflowStep.StepType.normalized(from: step.action.rawValue), targetLabel: target.label,
                targetID: target.id, targetMark: nil, execute: true, allowScreenshotPlanning: false,
                validateStateChange: true, traceID: observation.id))
            delivery = result.workflowOutcome?.status == "completed" ? .sent
                : ((result.submission?.acceptedSteps ?? 0) > 0 ? .unknown : .notSent)
        case .type, .pressKey, .shortcut, .scroll:
            let workflowType: WorkflowStep.StepType
            switch step.action {
            case .type: workflowType = .type
            case .pressKey: workflowType = .pressKey
            case .shortcut: workflowType = .keyboardShortcut
            case .scroll: workflowType = .scroll
            case .openApp: preconditionFailure("open_app uses its dedicated fast path")
            default: workflowType = .scroll
            }
            let workflowStep = WorkflowStep(id: UUID().uuidString, type: workflowType,
                label: step.application ?? step.key ?? target?.label,
                targetID: step.action == .type ? target?.id : nil, targetMark: nil,
                value: step.text, direction: step.direction, amount: step.amount ?? 1, by: "page",
                targetContext: step.action == .type ? .focusedElement : nil, hint: goal,
                hintX: nil, hintY: nil, box2DNormalized: nil, screenNumber: nil)
            let result = await engine.submitSingleActionWorkflowPlanAndWait(WorkflowPlan(goal: goal,
                app: observation.app, steps: [workflowStep], traceID: observation.id))
            delivery = result.workflowOutcome?.status == "completed" ? .sent : (result.acceptedSteps > 0 ? .unknown : .notSent)
        case .openApp:
            preconditionFailure("open_app uses its dedicated fast path")
        }
        try Task.checkCancellation()
        guard delivery != .notSent else { return notSent("执行引擎没有接受该操作。") }

        guard let afterContext = currentContext(), afterContext.app == context.app else {
            return DesktopTaskActionResult(completed: false, detail: "操作后前台应用改变，结果未确认。", delivery: delivery)
        }
        let afterControls = await readAccessibility(processIdentifier: afterContext.processIdentifier)
        let targets = await engine.localPerceptionTargets(refresh: true, reason: "voice independent result verification")
        try Task.checkCancellation()
        guard currentContext()?.app == context.app, currentContext()?.windowID == afterContext.windowID else {
            return DesktopTaskActionResult(completed: false, detail: "结果读回期间窗口变化，未确认完成。", delivery: delivery)
        }
        let afterTargets = targets.targets.map {
            DesktopTaskTarget(id: $0.id, label: $0.label, source: $0.source, box: $0.globalBox, display: $0.displayFrame)
        }
        let verified = delivery == .sent && DesktopActionVerifier.verify(step: step, target: target,
            before: beforeControls, after: afterControls, beforeTargets: observation.targets, afterTargets: afterTargets)
        return DesktopTaskActionResult(completed: verified,
            detail: verified ? "独立读回已确认目标状态。" : "操作已尝试，但没有足够的目标结果证据。", delivery: delivery)
    }

    private func readAccessibility(processIdentifier: pid_t) async -> [DesktopAccessibleControl] {
        let primaryDisplayTop = Double(NSScreen.screens.first?.frame.maxY ?? 0)
        return await Task.detached {
            DesktopAccessibilityReader.read(processIdentifier: processIdentifier, primaryDisplayTop: primaryDisplayTop)
        }.value
    }

    private func executeOpenApplication(goal: String, observation: DesktopTaskObservation,
                                        step: DesktopActionStep) async -> DesktopTaskActionResult {
        guard let requestedApplication = step.application else {
            return notSent("缺少应用名称，未执行。", stage: "resolve_application", reason: "application_missing")
        }
        let resolution = DesktopApplicationResolver.resolve(requestedApplication)
        let resolvedApplication: DesktopApplicationCandidate
        switch resolution {
        case .resolved(let candidate):
            resolvedApplication = candidate
        case .ambiguous:
            return notSent("匹配到多个已安装应用，需要进一步区分。", stage: "resolve_application", reason: "app_ambiguous")
        case .notFound:
            return notSent("未找到指定应用，没有改为点击其他控件。", stage: "resolve_application", reason: "app_not_found")
        }
        guard !Task.isCancelled else {
            return notSent("任务已取消，未启动应用。", stage: "cancel", reason: "cancelled")
        }

        let workflowStep = WorkflowStep(id: UUID().uuidString, type: .openApp,
            label: resolvedApplication.bundleIdentifier, targetID: nil, targetMark: nil,
            value: nil, direction: nil, amount: nil, by: nil, targetContext: nil,
            hint: goal, hintX: nil, hintY: nil, box2DNormalized: nil, screenNumber: nil)
        let result = await engine.submitSingleActionWorkflowPlanAndWait(WorkflowPlan(
            goal: goal,
            app: observation.app,
            steps: [workflowStep],
            traceID: observation.id
        ))
        guard !Task.isCancelled else {
            return DesktopTaskActionResult(completed: false, detail: "应用启动结果在取消后返回，未继续执行。",
                delivery: result.acceptedSteps > 0 ? .unknown : .notSent,
                failureStage: "cancel", reasonCode: "cancelled_after_dispatch")
        }
        let delivery: DesktopActionDelivery = result.workflowOutcome?.status == "completed"
            ? .sent : (result.acceptedSteps > 0 ? .unknown : .notSent)
        guard delivery != .notSent else {
            return notSent("执行引擎没有接受应用启动操作。", stage: "workflow", reason: result.reason ?? "workflow_rejected")
        }
        var presence = await waitForUserVisibleApplication(resolvedApplication, timeout: 0.8)
        if delivery == .sent, !presence.isUserVisible, !Task.isCancelled {
            // Some Chromium/Electron wrappers keep a background process alive
            // after their last window closes. Launching that bundle can return
            // successfully without reopening a window. Ask LaunchServices to
            // reopen/activate the installed app once, then verify actual user-
            // visible state rather than treating "process exists" as success.
            await requestApplicationReopen(resolvedApplication)
            presence = await waitForUserVisibleApplication(resolvedApplication, timeout: 1.2)
        }
        guard !Task.isCancelled else {
            return DesktopTaskActionResult(completed: false, detail: "应用启动后任务被取消，未继续确认窗口。",
                delivery: delivery, failureStage: "cancel", reasonCode: "cancelled_after_dispatch")
        }

        let verified = delivery == .sent && presence.isUserVisible
        let detail: String
        let reasonCode: String?
        if verified {
            detail = "目标应用已有可见窗口并位于前台。"
            reasonCode = nil
        } else if presence.runningProcessIdentifiers.isEmpty {
            detail = "启动请求已发送，但没有发现目标应用进程。"
            reasonCode = "target_process_missing"
        } else if !presence.hasVisibleWindow {
            detail = "目标应用进程已运行，但当前没有可见窗口，不能报告已打开。"
            reasonCode = "no_visible_window"
        } else {
            detail = "目标应用有可见窗口，但没有位于前台，不能报告已打开。"
            reasonCode = "target_not_foreground"
        }
        return DesktopTaskActionResult(
            completed: verified,
            detail: detail,
            delivery: delivery,
            resultingApp: verified ? resolvedApplication.bundleIdentifier : nil,
            failureStage: verified ? nil : "verify_application",
            reasonCode: reasonCode
        )
    }

    private func waitForUserVisibleApplication(
        _ application: DesktopApplicationCandidate,
        timeout: TimeInterval
    ) async -> DesktopApplicationPresence {
        let deadline = Date().addingTimeInterval(timeout)
        var presence = DesktopApplicationResolver.presence(of: application)
        while !presence.isUserVisible, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            presence = DesktopApplicationResolver.presence(of: application)
        }
        return presence
    }

    private func requestApplicationReopen(_ application: DesktopApplicationCandidate) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.openApplication(at: application.url, configuration: configuration) { runningApplication, _ in
                runningApplication?.unhide()
                runningApplication?.activate(options: [.activateAllWindows])
                continuation.resume()
            }
        }
    }

    private func notSent(_ detail: String, stage: String = "dispatch", reason: String = "not_sent") -> DesktopTaskActionResult {
        DesktopTaskActionResult(completed: false, detail: detail, delivery: .notSent,
            failureStage: stage, reasonCode: reason)
    }
}
