import Foundation

struct DesktopTaskTarget: Equatable {
    let id: String
    let label: String
    let source: String
    let box: [Double]
    let display: [Double]
}

struct DesktopTaskObservation {
    let app: String
    let targets: [DesktopTaskTarget]
    var windowID: Int? = nil
    var id: String = UUID().uuidString
    var capturedAt: Date = Date()
    var contentVersion: Int = 0
    var imageDataURL: String? = nil
}

struct DesktopTaskDecision {
    let targetID: String?
    let action: String
    let completed: Bool
    let reason: String
    var declined: Bool = false
    var source: DesktopDecisionSource = .generalModel
    var actionProbability: Double? = nil
    var actionMargin: Double? = nil
    var targetProbability: Double? = nil
    var targetMargin: Double? = nil
}

struct DesktopTaskActionResult {
    /// True only after an independent readback of the requested state.
    let completed: Bool
    let detail: String
    var delivery: DesktopActionDelivery = .unknown
    var resultingApp: String? = nil
    var failureStage: String? = nil
    var reasonCode: String? = nil
}

/// One owner for goal revisions, side-effect budgets and action evidence.
/// A single target gets one attempt; a workflow is an explicit list of steps.
@MainActor
final class DesktopTaskCoordinator {
    typealias Observe = () async throws -> DesktopTaskObservation
    typealias Decide = (String, DesktopTaskObservation, [String], Bool) async throws -> DesktopTaskDecision
    typealias DecideWithStep = (String, DesktopActionStep, DesktopTaskObservation, [String], Bool) async throws -> DesktopTaskDecision
    typealias Execute = (String, DesktopTaskObservation, DesktopTaskTarget, String) async throws -> DesktopTaskActionResult
    typealias ExecuteStep = (String, DesktopTaskObservation, DesktopTaskTarget?, DesktopActionStep) async throws -> DesktopTaskActionResult

    private let observe: Observe
    private let observeContext: Observe
    private let decideWithStep: DecideWithStep
    private let executeStep: ExecuteStep
    private var generation = 0
    private var previousPlan: [DesktopActionStep] = []
    private var nextStepIndex = 0
    private var uncertainTargets: [(app: String, target: DesktopTaskTarget)] = []
    private var uncertainTargetlessSteps: [(app: String, step: DesktopActionStep)] = []
    private(set) var isRunning = false
    private(set) var lastReceipt: DesktopTaskReceipt?

    init(observe: @escaping Observe, observeContext: Observe? = nil,
         decide: @escaping Decide, executeStep: @escaping ExecuteStep) {
        self.observe = observe
        self.observeContext = observeContext ?? observe
        self.decideWithStep = { goal, _, observation, history, useGeneralReasoning in
            try await decide(goal, observation, history, useGeneralReasoning)
        }
        self.executeStep = executeStep
    }

    init(observe: @escaping Observe, observeContext: Observe? = nil,
         decideWithStep: @escaping DecideWithStep, executeStep: @escaping ExecuteStep) {
        self.observe = observe
        self.observeContext = observeContext ?? observe
        self.decideWithStep = decideWithStep
        self.executeStep = executeStep
    }

    convenience init(observe: @escaping Observe, decide: @escaping Decide, execute: @escaping Execute) {
        self.init(observe: observe, decide: decide, executeStep: { goal, observation, target, step in
            guard let target else { throw DesktopTaskContractError.invalid("此执行器需要明确目标。") }
            return try await execute(goal, observation, target, step.action.rawValue)
        })
    }

    func interrupt() { generation += 1 }

    func run(goal: String, namedTarget: String? = nil, exactTarget: DesktopTaskTarget? = nil,
             action: String? = nil, resumePrevious: Bool = false, maximumActions: Int = 6,
             steps: [DesktopActionStep]? = nil, intent: DesktopTaskIntent? = nil,
             turnID: String = UUID().uuidString) async -> DesktopTaskReceipt {
        guard !isRunning else {
            return DesktopTaskReceipt(goal: goal, status: "busy", actions: [], detail: "前一个操作正在停止，请稍后重试。", turnID: turnID)
        }
        isRunning = true
        generation += 1
        let runGeneration = generation
        defer { isRunning = false }

        let previous = lastReceipt
        let effectiveIntent: DesktopTaskIntent = intent ?? (resumePrevious ? .resume : .new)
        let wantsResume = intent == .resume || (intent == nil && resumePrevious)
        let sameGoal = previous.map { DesktopActionStep.normalized($0.goal) == DesktopActionStep.normalized(goal) } ?? false
        let resumesSameTask = wantsResume && sameGoal && !previousPlan.isEmpty
        let isCorrection = intent == .correct || (wantsResume && !sameGoal)
        let priorActions = (wantsResume || isCorrection) ? Array(((previous?.priorActions ?? []) + (previous?.actions ?? [])).suffix(32)) : []
        let taskID = (resumesSameTask || isCorrection) ? previous?.taskID ?? UUID().uuidString : UUID().uuidString
        let targetVersion = isCorrection ? (previous?.targetVersion ?? 0) + 1 : (resumesSameTask ? previous?.targetVersion ?? 1 : 1)
        var pinnedApp = resumesSameTask ? previous?.app : nil
        var records: [DesktopActionRecord] = []

        func checkCurrent() throws {
            try Task.checkCancellation()
            guard runGeneration == generation else { throw CancellationError() }
        }
        func finish(_ status: String, _ detail: String) -> DesktopTaskReceipt {
            let receipt = DesktopTaskReceipt(goal: goal, status: status,
                actions: records.filter { $0.delivery != .notSent }.map(\.summary), detail: detail,
                app: pinnedApp, taskID: taskID, turnID: turnID, targetVersion: targetVersion,
                priorActions: priorActions, currentActions: records)
            lastReceipt = receipt
            DesktopVoiceTrace.event("task_finished", turnID: turnID,
                fields: ["task_id": taskID, "status": status, "target_version": String(targetVersion),
                         "new_action_count": String(receipt.actions.count)])
            return receipt
        }

        // An invalid replacement request must not leave the old plan attached
        // to the new receipt's goal, where a later resume could execute it.
        if !resumesSameTask {
            previousPlan = []
            nextStepIndex = 0
        }
        do {
            guard intent != .resume || resumesSameTask else {
                return finish("paused", "没有与这个目标对应的可续接计划，未执行。")
            }
            guard !DesktopActionStep.normalized(goal).isEmpty, maximumActions > 0 else {
                return finish("failed", "任务或操作预算无效。")
            }
            let singleAction: DesktopActionKind
            if let action {
                guard let parsed = DesktopActionKind(rawValue: action) else { return finish("failed", "动作类型不受支持。") }
                singleAction = parsed
            } else { singleAction = .click }
            let requestedPlan = steps ?? [DesktopActionStep(action: singleAction, targetLabel: namedTarget)]
            guard !requestedPlan.isEmpty, requestedPlan.count <= min(maximumActions, 6),
                  exactTarget == nil || requestedPlan.count == 1 else {
                return finish("failed", "任务必须包含一到六个明确步骤；旧观察编号只能用于单目标操作。")
            }
            for step in requestedPlan { try step.validate() }
            if resumesSameTask {
                guard steps == nil || requestedPlan == previousPlan else { return finish("paused", "续接任务的步骤发生变化，请作为纠正提交。") }
            } else {
                previousPlan = requestedPlan
                nextStepIndex = 0
            }
            guard nextStepIndex < previousPlan.count else {
                return finish("paused", "此前步骤已结束；本轮没有重新执行，也没有重新验证。")
            }
            let plan = previousPlan
            while nextStepIndex < plan.count {
                try checkCurrent()
                var step = plan[nextStepIndex]
                if step.expectedLabel == nil, nextStepIndex + 1 < plan.count {
                    step.expectedLabel = plan[nextStepIndex + 1].targetLabel
                }
                var observation = step.action == .openApp ? try await observeContext() : try await observe()
                try checkCurrent()
                if let pinnedApp, pinnedApp != observation.app { return finish("paused", "前台应用已改变，已暂停原任务。") }
                pinnedApp = observation.app
                var selectedTarget: DesktopTaskTarget?
                var modelDecision: DesktopTaskDecision?

                if step.action.needsTarget {
                    var candidates = step.candidates(in: observation)
                    if let exactTarget { candidates = candidates.filter { Self.sameTarget($0, exactTarget) } }
                    if candidates.isEmpty {
                        observation = try await observe()
                        try checkCurrent()
                        guard pinnedApp == observation.app else { return finish("paused", "重新观察时应用已变化。") }
                        candidates = step.candidates(in: observation)
                        if let exactTarget { candidates = candidates.filter { Self.sameTarget($0, exactTarget) } }
                    }
                    guard !candidates.isEmpty else { return finish("needs_clarification", "重新观察后仍未定位到指定目标，没有用其他控件替代。") }
                    if step.targetLabel != nil || exactTarget != nil {
                        guard candidates.count == 1 else { return finish("needs_clarification", "存在多个符合限定的同名目标，需要进一步区分位置。") }
                        selectedTarget = candidates[0]
                    } else {
                        var narrowed = observation
                        narrowed = DesktopTaskObservation(app: observation.app, targets: candidates, windowID: observation.windowID,
                            id: observation.id, capturedAt: observation.capturedAt, contentVersion: observation.contentVersion,
                            imageDataURL: observation.imageDataURL)
                        let decision: DesktopTaskDecision
                        do {
                            decision = try await decideWithStep(goal, step, narrowed, resumesSameTask ? priorActions : [], false)
                        } catch {
                            try checkCurrent()
                            observation = try await observe()
                            try checkCurrent()
                            guard observation.app == pinnedApp else { return finish("paused", "恢复观察时应用已变化。") }
                            let recoveredCandidates = step.candidates(in: observation)
                            guard !recoveredCandidates.isEmpty else { return finish("needs_clarification", "恢复观察后没有合适目标。") }
                            narrowed = DesktopTaskObservation(app: observation.app, targets: recoveredCandidates, windowID: observation.windowID,
                                id: observation.id, capturedAt: observation.capturedAt, contentVersion: observation.contentVersion,
                                imageDataURL: observation.imageDataURL)
                            decision = try await decideWithStep(goal, step, narrowed, resumesSameTask ? priorActions : [], true)
                        }
                        try checkCurrent()
                        modelDecision = decision
                        guard !decision.completed else { return finish("paused", "模型判断完成，但没有独立结果证据，不能确认任务完成。") }
                        guard !decision.declined, let identifier = decision.targetID else {
                            return finish("needs_clarification", "当前没有可确认的目标，没有继续尝试其他控件。")
                        }
                        guard let proposed = narrowed.targets.first(where: { $0.id == identifier }) else {
                            return finish("failed", "模型选择不在当前受限候选内，未执行。")
                        }
                        if step.allowsActionDecision {
                            guard let decidedAction = DesktopActionKind(rawValue: decision.action),
                                  [.click, .doubleClick, .rightClick].contains(decidedAction) else {
                                return finish("failed", "决策返回了不允许的动作类型，未执行。")
                            }
                            step.action = decidedAction
                        }
                        // A slow decision must not carry old geometry into a new scene.
                        let fresh = try await observe()
                        try checkCurrent()
                        guard fresh.app == narrowed.app, fresh.windowID == narrowed.windowID else {
                            return finish("paused", "决策期间窗口已变化，旧选择未执行。")
                        }
                        let matches = step.candidates(in: fresh).filter { Self.sameTarget($0, proposed) }
                        guard matches.count == 1 else { return finish("paused", "决策期间目标已变化，旧选择未执行。") }
                        observation = fresh
                        selectedTarget = matches[0]
                    }
                }

                if let selectedTarget, uncertainTargets.contains(where: { $0.app == observation.app && Self.sameTarget($0.target, selectedTarget) }) {
                    return finish("paused", "此前对此目标的操作结果仍未确认，不能自动重复。")
                }
                if selectedTarget == nil, uncertainTargetlessSteps.contains(where: { $0.app == observation.app && $0.step == step }) {
                    return finish("paused", "此前同一操作的结果仍未确认，不能自动重复。")
                }
                guard uncertainTargets.count + uncertainTargetlessSteps.count < 32 else { return finish("paused", "未确认操作过多，请先检查现有结果。") }
                try checkCurrent()
                let label = selectedTarget?.label ?? step.application ?? step.key ?? step.direction ?? step.action.rawValue
                let packet = DesktopDecisionPacket.make(
                    step: step,
                    target: selectedTarget,
                    intent: effectiveIntent,
                    scope: plan.count > 1 ? .workflow : .single,
                    modelDecision: modelDecision
                )
                records.append(DesktopActionRecord(id: observation.id, observationID: observation.id,
                    app: observation.app, targetID: selectedTarget?.id, label: label, action: step.action,
                    decisionPacket: packet, delivery: .unknown, verified: false, detail: "已尝试下发，结果未确认"))
                if let selectedTarget { uncertainTargets.append((observation.app, selectedTarget)) }
                else { uncertainTargetlessSteps.append((observation.app, step)) }
                DesktopVoiceTrace.event("action_attempt_started", turnID: turnID,
                    fields: ["task_id": taskID, "trace_id": observation.id, "action": step.action.rawValue,
                             "decision_source": packet.source.rawValue, "scope": packet.scope.rawValue,
                             "action_confidence": packet.confidence.action.map { String($0) } ?? "unavailable",
                             "target_confidence": packet.confidence.target.map { String($0) } ?? "unavailable"],
                    privateFields: ["target": label])
                let result = try await executeStep(goal, observation, selectedTarget, step)
                records[records.count - 1].delivery = result.completed ? .sent : result.delivery
                records[records.count - 1].verified = result.completed
                records[records.count - 1].detail = result.detail
                DesktopVoiceTrace.event("action_evidence", turnID: turnID,
                    fields: ["task_id": taskID, "trace_id": observation.id,
                             "delivery": records[records.count - 1].delivery.rawValue,
                             "verified": String(result.completed),
                             "failure_stage": result.failureStage ?? "none",
                             "reason_code": result.reasonCode ?? "none"])
                if result.completed || result.delivery == .notSent, let selectedTarget {
                    uncertainTargets.removeAll { $0.app == observation.app && Self.sameTarget($0.target, selectedTarget) }
                }
                if result.completed || result.delivery == .notSent {
                    uncertainTargetlessSteps.removeAll { $0.app == observation.app && $0.step == step }
                }
                // Cancellation stops future work, not factual bookkeeping.
                // A verified effect remains completed even when interruption
                // arrives before this invocation returns its receipt.
                if result.completed {
                    if step.action == .openApp { pinnedApp = result.resultingApp }
                    nextStepIndex += 1
                }
                try checkCurrent()
                if result.delivery == .notSent { return finish("paused", result.detail) }
                guard result.completed else { return finish("paused", "操作结果未确认，已停止；页面变化不等于目标完成。") }
            }
            return finish("completed", "本轮步骤均已通过独立结果检查。")
        } catch is CancellationError {
            return finish("paused", "已中断；保留可能已经发生的操作，未下发步骤不会继续。")
        } catch {
            return finish("failed", "任务未能完成，已停止，详情请查看诊断记录。")
        }
    }

    static func sameTarget(_ target: DesktopTaskTarget, _ previous: DesktopTaskTarget) -> Bool {
        // IDs alone are not proof: a provider may reuse one after a refresh.
        LocalTargetContinuity.matches(label: target.label, source: target.source, box: target.box, display: target.display,
            previousLabel: previous.label, previousSource: previous.source, previousBox: previous.box, previousDisplay: previous.display)
    }
}
