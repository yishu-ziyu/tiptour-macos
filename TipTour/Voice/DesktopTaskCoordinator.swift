import Foundation

struct DesktopTaskTarget: Equatable {
    let id: String
    let label: String
    let source: String
    let box: [Double]
    let display: [Double]
}

struct DesktopTaskSceneIdentity: Equatable {
    let app: String
    let windowID: Int?
    let contentVersion: Int
}

struct DesktopTaskObservation {
    let app: String
    let targets: [DesktopTaskTarget]
    var windowID: Int? = nil
    var id: String = UUID().uuidString
    var capturedAt: Date = Date()
    var contentVersion: Int = 0
    var imageDataURL: String? = nil
    var actionAttemptID: String? = nil

    var sceneIdentity: DesktopTaskSceneIdentity {
        DesktopTaskSceneIdentity(app: app, windowID: windowID, contentVersion: contentVersion)
    }
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

// DesktopTaskActionResult now lives in DesktopTaskContract.swift, alongside
// the delivery/evidence fact types it reports.

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
    private var resumeScene: DesktopTaskSceneIdentity?
    /// One side effect that was sent but whose result was never verified.
    /// Scoped to one task chain: a brand-new instruction is explicit user
    /// authorization and must not inherit an older task's blocks, while a
    /// resume of the same task must never quietly switch to another candidate.
    private struct UncertainEffect {
        let app: String
        let target: DesktopTaskTarget?
        let step: DesktopActionStep
        let label: String
        /// Facts needed to rebuild the attempt record when the user later
        /// confirms what the system could not verify on its own.
        let attemptID: String
        let observationID: String
        let targetID: String?
        var delivery: DesktopActionDelivery
    }
    private var uncertainEffects: [UncertainEffect] = []
    private var uncertainEffectsTaskID: String?
    private(set) var isRunning = false
    private(set) var lastReceipt: DesktopTaskReceipt?
    let executionOwnerID = UUID()
    private var ownedExecution: Task<DesktopTaskReceipt, Never>?
    private struct PendingContinuation {
        let taskID: String
        let targetVersion: Int
        let turnID: String
        let onlyAfterUserInput: Bool
    }
    private var pendingContinuation: PendingContinuation?
    private var admissionWaiter: CheckedContinuation<DesktopTaskReceipt, Never>?
    private var cancelledTaskID: String?
    private var currentUserTurnID: String?
    private var activeRunGeneration: Int?
    private var journal: DesktopTaskJournal?
    private var journalUnavailable = false
    private(set) var pausedForUserInput = false
    private(set) var hasPersistentReservation = false
    var onReceiptChanged: ((DesktopTaskReceipt) -> Void)?
    var canReserveDesktop: () -> Bool = { true }
    var mayDispatch: Bool { isRunning && activeRunGeneration == generation && !journalUnavailable }

    func configureJournal(_ journal: DesktopTaskJournal) {
        self.journal = journal
        do {
            guard let snapshot = try journal.load() else { return }
            let terminal = ["completed", "cancelled"].contains(snapshot.status)
            let receipt = DesktopTaskReceipt(goal: "历史任务（正文未保存）",
                status: terminal ? snapshot.status : "recovery_required", actions: [],
                detail: terminal ? "已恢复上次任务状态。" : "上次任务执行中断；没有自动恢复操作，请先核查已发生的部分。",
                taskID: snapshot.taskID, targetVersion: snapshot.targetVersion,
                completedStepCount: snapshot.completedStepCount, totalStepCount: snapshot.totalStepCount)
            hasPersistentReservation = !terminal
            if !terminal { _ = DesktopTaskAdmission.reserve(for: self) }
            publish(receipt)
        } catch {
            journalUnavailable = true
            hasPersistentReservation = true
            _ = DesktopTaskAdmission.reserve(for: self)
            // Keep unreadable recovery bytes intact. An empty replacement
            // would erase evidence of effects we may still need to inspect.
            let receipt = DesktopTaskReceipt(goal: "任务恢复记录不可用", status: "storage_failed", actions: [],
                detail: "无法读取上次任务记录，桌面操作已暂停；原记录保留，不能假定没有执行过。")
            lastReceipt = receipt
            onReceiptChanged?(receipt)
        }
    }

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

    func beginUserTurn(_ turnID: String) {
        if currentUserTurnID != turnID { pendingContinuation = nil }
        currentUserTurnID = turnID
    }
    func endUserTurn() {
        currentUserTurnID = nil
        pendingContinuation = nil
    }

    func pauseForUserInput() {
        guard hasPersistentReservation else { return }
        // New speech cannot clear a pause caused by a disconnect, changed
        // window, or uncertain effect. Only interrupting a live run creates
        // the permission to continue after a progress-only question.
        if isRunning, activeRunGeneration == generation {
            pausedForUserInput = true
        }
        interrupt()
        if var receipt = lastReceipt, receipt.status == "running" {
            receipt.status = "pausing"
            receipt.detail = "用户正在说话，后续操作暂停；已下发部分继续核查。"
            publish(receipt)
        }
    }

    func pauseForDisconnection() {
        pauseForUserInput()
        pausedForUserInput = false
        pendingContinuation = nil
    }

    func cancelTask(taskID: String, targetVersion: Int, turnID: String) -> DesktopTaskReceipt? {
        guard turnID == currentUserTurnID, let receipt = lastReceipt,
              receipt.taskID == taskID, receipt.targetVersion == targetVersion,
              hasPersistentReservation else { return nil }
        cancelledTaskID = taskID
        pendingContinuation = nil
        pausedForUserInput = false
        interrupt()
        var cancelled = receipt
        cancelled.status = isRunning ? "cancelling" : "cancelled"
        cancelled.detail = "已停止后续操作；保留已经发生的事实。"
        if !isRunning { hasPersistentReservation = false }
        publish(cancelled)
        return cancelled
    }

    /// The caller waits only for admission. Execution belongs to this
    /// application-scoped coordinator, so cancelling a voice waiter cannot
    /// cancel the task or suppress independent after-state bookkeeping.
    func submit(_ request: DesktopTaskSubmission) async -> DesktopTaskReceipt {
        // Reject expired controls before they can pause an existing execution.
        // The second check below still fences a turn change while awaiting it.
        guard !Task.isCancelled, request.turnID == currentUserTurnID else {
            return DesktopTaskReceipt(goal: request.goal, status: "paused", actions: [],
                detail: "请求所属发言已过期，未执行。", turnID: request.turnID)
        }
        guard !journalUnavailable else {
            return DesktopTaskReceipt(goal: request.goal, status: "storage_failed", actions: [],
                detail: "任务记录当前不可用，未启动新操作。", turnID: request.turnID)
        }
        if request.intent == .new, hasPersistentReservation {
            return DesktopTaskReceipt(goal: request.goal, status: "busy", actions: [],
                detail: "当前任务仍待继续、纠正或取消，未覆盖它。", turnID: request.turnID)
        }
        if lastReceipt?.status == "recovery_required" {
            return lastReceipt!
        }
        if request.intent == .correct, let ownedExecution {
            pendingContinuation = nil
            interrupt()
            _ = await ownedExecution.value
        }
        guard !Task.isCancelled, request.turnID == currentUserTurnID else {
            return DesktopTaskReceipt(goal: request.goal, status: "paused", actions: [],
                detail: "请求所属发言已过期，未执行。", turnID: request.turnID)
        }
        guard ownedExecution == nil, !isRunning,
              (hasPersistentReservation || canReserveDesktop()), DesktopTaskAdmission.reserve(for: self) else {
            return DesktopTaskReceipt(goal: request.goal, status: "busy", actions: [],
                detail: "前一个任务尚未收尾，未执行新请求。", turnID: request.turnID)
        }
        if request.intent != .new, lastReceipt?.status == "cancelled" {
            return lastReceipt!
        }
        let previousReservation = hasPersistentReservation
        hasPersistentReservation = true
        pausedForUserInput = false
        let admittedGeneration = generation
        return await withCheckedContinuation { continuation in
            admissionWaiter = continuation
            ownedExecution = Task { [self] in
                let result: DesktopTaskReceipt
                if generation != admittedGeneration || request.turnID != currentUserTurnID {
                    result = lastReceipt ?? DesktopTaskReceipt(goal: request.goal, status: "paused", actions: [],
                        detail: "接收期间出现新发言，没有下发操作。", turnID: request.turnID)
                    publish(result)
                    hasPersistentReservation = previousReservation
                } else {
                    result = await run(goal: request.goal, exactTarget: request.exactTarget,
                        steps: request.steps, intent: request.intent,
                        uncertainResolution: request.uncertainResolution, turnID: request.turnID,
                        expectedResumeScene: request.expectedResumeScene)
                }
                ownedExecution = nil
                // A progress query receives a snapshot immediately. Its
                // continuation is reconsidered only after the old action has
                // settled, using the same turn, task and revision checks.
                if let pending = pendingContinuation {
                    pendingContinuation = nil
                    _ = await continueTask(taskID: pending.taskID, targetVersion: pending.targetVersion,
                        turnID: pending.turnID, onlyAfterUserInput: pending.onlyAfterUserInput)
                }
                return result
            }
        }
    }

    func continueTask(taskID: String, targetVersion: Int, turnID: String,
                      onlyAfterUserInput: Bool) async -> DesktopTaskReceipt? {
        guard !Task.isCancelled, turnID == currentUserTurnID,
              let current = lastReceipt, current.taskID == taskID, current.targetVersion == targetVersion,
              !onlyAfterUserInput || pausedForUserInput else { return nil }
        if ownedExecution != nil {
            guard ["running", "pausing"].contains(current.status) else { return current }
            pendingContinuation = PendingContinuation(taskID: taskID, targetVersion: targetVersion,
                turnID: turnID, onlyAfterUserInput: onlyAfterUserInput)
            return current
        }
        guard !Task.isCancelled, turnID == currentUserTurnID, let receipt = lastReceipt,
              receipt.taskID == taskID, receipt.targetVersion == targetVersion,
              receipt.status == "paused", uncertainEffects.isEmpty,
              nextStepIndex < previousPlan.count else { return lastReceipt }
        if onlyAfterUserInput, resumeScene == nil { return receipt }
        return await submit(DesktopTaskSubmission(goal: receipt.goal, intent: .resume, turnID: turnID,
            expectedResumeScene: onlyAfterUserInput ? resumeScene : nil))
    }

    func waitUntilSettled() async {
        while let execution = ownedExecution { _ = await execution.value }
    }

    private func publish(_ originalReceipt: DesktopTaskReceipt) {
        var receipt = originalReceipt
        if let journal {
            do { try journal.save(receipt) }
            catch {
                journalUnavailable = true
                generation += 1
                hasPersistentReservation = true
                receipt.status = "storage_failed"
                receipt.detail = "任务记录保存失败，后续操作已停止；已发生的部分需要核查。"
            }
        }
        lastReceipt = receipt
        let waiter = admissionWaiter
        admissionWaiter = nil
        waiter?.resume(returning: receipt)
        onReceiptChanged?(receipt)
    }

    func run(goal: String, namedTarget: String? = nil, exactTarget: DesktopTaskTarget? = nil,
             action: String? = nil, resumePrevious: Bool = false, maximumActions: Int = 6,
             steps: [DesktopActionStep]? = nil, intent: DesktopTaskIntent? = nil,
             uncertainResolution: DesktopTaskUncertainResolution? = nil,
             turnID: String = UUID().uuidString,
             expectedResumeScene: DesktopTaskSceneIdentity? = nil) async -> DesktopTaskReceipt {
        guard !isRunning else {
            return DesktopTaskReceipt(goal: goal, status: "busy", actions: [], detail: "前一个操作正在停止，请稍后重试。", turnID: turnID)
        }
        isRunning = true
        generation += 1
        let runGeneration = generation
        activeRunGeneration = runGeneration
        defer { isRunning = false; activeRunGeneration = nil }

        let previous = lastReceipt
        let effectiveIntent: DesktopTaskIntent = intent ?? (resumePrevious ? .resume : .new)
        let wantsResume = intent == .resume || (intent == nil && resumePrevious)
        let sameGoal = previous.map { DesktopActionStep.normalized($0.goal) == DesktopActionStep.normalized(goal) } ?? false
        let resumesSameTask = wantsResume && sameGoal && !previousPlan.isEmpty
        let isCorrection = intent == .correct || (wantsResume && !sameGoal)
        let priorActions = (wantsResume || isCorrection) ? Array(((previous?.priorActions ?? []) + (previous?.actions ?? [])).suffix(32)) : []
        /// Only independently verified effects enter the verified history;
        /// user-confirmed and delivery-confirmed steps stay in the satisfied
        /// history, which is the list the decision model reads as already-done.
        var priorVerifiedActions = (wantsResume || isCorrection) ? (previous?.verifiedActionHistory ?? []) : []
        var priorSatisfiedActions = (wantsResume || isCorrection) ? (previous?.satisfiedActionHistory ?? []) : []
        let taskID = (resumesSameTask || isCorrection) ? previous?.taskID ?? UUID().uuidString : UUID().uuidString
        if uncertainEffectsTaskID != taskID {
            uncertainEffects = []
            uncertainEffectsTaskID = taskID
        }
        let targetVersion = isCorrection ? (previous?.targetVersion ?? 0) + 1 : (resumesSameTask ? previous?.targetVersion ?? 1 : 1)
        var pinnedApp = resumesSameTask ? previous?.app : nil
        var records: [DesktopActionRecord] = []
        var requiredScene = expectedResumeScene

        func checkCurrent() throws {
            try Task.checkCancellation()
            guard runGeneration == generation, !journalUnavailable else { throw CancellationError() }
        }
        func finish(_ status: String, _ detail: String) -> DesktopTaskReceipt {
            let finalStatus = cancelledTaskID == taskID ? "cancelled" : status
            let receipt = DesktopTaskReceipt(goal: goal, status: finalStatus,
                actions: records.filter { $0.delivery != .notSent }.map(\.summary), detail: detail,
                app: pinnedApp, taskID: taskID, turnID: turnID, targetVersion: targetVersion,
                priorActions: priorActions, currentActions: records,
                verifiedActionHistory: Array((priorVerifiedActions + records.filter(\.verified).map(\.summary)).suffix(32)),
                satisfiedActionHistory: Array((priorSatisfiedActions + records.filter(\.satisfied).map(\.summary)).suffix(32)),
                completedStepCount: nextStepIndex, totalStepCount: previousPlan.count)
            if ["completed", "cancelled"].contains(finalStatus)
                || (finalStatus == "failed" && uncertainEffects.isEmpty) { hasPersistentReservation = false }
            publish(receipt)
            DesktopVoiceTrace.event("task_finished", turnID: turnID,
                fields: ["task_id": taskID, "status": lastReceipt?.status ?? finalStatus, "target_version": String(targetVersion),
                         "new_action_count": String(receipt.actions.count)])
            return lastReceipt ?? receipt
        }

        func reportProgress() {
            guard ownedExecution != nil else { return }
            let status = cancelledTaskID == taskID ? "cancelling"
                : (generation != runGeneration ? "pausing" : "running")
            publish(DesktopTaskReceipt(goal: goal, status: status,
                actions: records.filter { $0.delivery != .notSent }.map(\.summary), detail: "执行状态，尚非完成声明。",
                app: pinnedApp, taskID: taskID, turnID: turnID, targetVersion: targetVersion,
                priorActions: priorActions, currentActions: records,
                verifiedActionHistory: Array((priorVerifiedActions + records.filter(\.verified).map(\.summary)).suffix(32)),
                satisfiedActionHistory: Array((priorSatisfiedActions + records.filter(\.satisfied).map(\.summary)).suffix(32)),
                completedStepCount: nextStepIndex, totalStepCount: previousPlan.count))
        }

        // An invalid replacement request must not leave the old plan attached
        // to the new receipt's goal, where a later resume could execute it.
        if !resumesSameTask {
            previousPlan = []
            nextStepIndex = 0
            resumeScene = nil
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
            var pinnedRetryTarget: DesktopTaskTarget?
            if !uncertainEffects.isEmpty {
                // An unconfirmed side effect owns this task until the user
                // resolves it explicitly. A plain resume or correction must not
                // ask the model for the next-best candidate — that is how one
                // uncertain click turned into a click on something else.
                guard let resolution = uncertainResolution else {
                    return finish("uncertain_effect", "上一轮操作的结果仍未确认，已停在这里，不会改试其他目标。请确认实际结果，或用 uncertain_resolution 明确指示：confirmed_succeeded / confirmed_failed / retry_same / replace_target。")
                }
                switch resolution {
                case .confirmedSucceeded:
                    // The user confirms the attempt landed: that is
                    // user-confirmed outcome evidence. It satisfies the step
                    // and enters satisfied history with user-confirmed
                    // wording, but it is never a system verification, so it
                    // must not enter the verified history. A user confirming
                    // success also settles delivery affirmatively.
                    for effect in uncertainEffects {
                        records.append(DesktopActionRecord(id: effect.attemptID,
                            observationID: effect.observationID, app: effect.app,
                            targetID: effect.targetID, label: effect.label, action: effect.step.action,
                            decisionPacket: nil,
                            completionPolicy: DesktopStepCompletionPolicy(step: effect.step),
                            delivery: .sent, outcomeEvidence: .userConfirmed,
                            detail: "用户确认该操作已经生效"))
                    }
                    uncertainEffects = []
                    DesktopVoiceTrace.event("uncertain_resolved", turnID: turnID,
                        fields: ["task_id": taskID, "resolution": resolution.rawValue,
                                 "user_confirmed": "true", "promoted_to_verified": "false"])
                    if resumesSameTask {
                        nextStepIndex += 1
                        if nextStepIndex >= plan.count {
                            return finish("completed", "你已确认上一轮操作的结果生效，任务完成。")
                        }
                    }
                case .confirmedFailed:
                    // Acknowledged failure: the attempt stays in
                    // attempted-unverified history, the block lifts.
                    uncertainEffects = []
                    DesktopVoiceTrace.event("uncertain_resolved", turnID: turnID,
                        fields: ["task_id": taskID, "resolution": resolution.rawValue,
                                 "promoted_to_verified": "false"])
                case .retrySame:
                    guard resumesSameTask else {
                        return finish("uncertain_effect", "retry_same 只能用于同一目标的续接；更换目标请用 correct 加 replace_target。")
                    }
                    // Pin the recorded target so the retry cannot let the
                    // decision layer quietly pick the runner-up candidate.
                    if let recordedTarget = uncertainEffects.first(where: { $0.target != nil })?.target,
                       plan[nextStepIndex].action.needsTarget,
                       plan[nextStepIndex].targetLabel == nil,
                       plan[nextStepIndex].region == nil,
                       plan[nextStepIndex].anchorLabel == nil {
                        pinnedRetryTarget = recordedTarget
                    }
                    uncertainEffects = []
                    DesktopVoiceTrace.event("uncertain_resolved", turnID: turnID,
                        fields: ["task_id": taskID, "resolution": resolution.rawValue,
                                 "pinned_target": String(pinnedRetryTarget != nil)])
                case .replaceTarget:
                    guard isCorrection else {
                        return finish("uncertain_effect", "replace_target 需要 corrective 指令（intent=correct）和明确的新目标。")
                    }
                    let explicitlyTargeted = requestedPlan.allSatisfy { step in
                        !step.action.needsTarget || step.targetLabel != nil || step.region != nil
                            || (step.anchorLabel != nil && step.relation != nil)
                    }
                    guard explicitlyTargeted else {
                        return finish("needs_clarification", "replace_target 需要明确的新目标名称或位置，不能交给模型重新挑选。")
                    }
                    uncertainEffects = []
                    DesktopVoiceTrace.event("uncertain_resolved", turnID: turnID,
                        fields: ["task_id": taskID, "resolution": resolution.rawValue,
                                 "replaced_target": "true"])
                }
            }
            let pinnedTarget = pinnedRetryTarget ?? exactTarget
            reportProgress()
            while nextStepIndex < plan.count {
                try checkCurrent()
                var step = plan[nextStepIndex]
                if step.expectedLabel == nil, nextStepIndex + 1 < plan.count {
                    step.expectedLabel = plan[nextStepIndex + 1].targetLabel
                }
                var observation = step.action == .openApp ? try await observeContext() : try await observe()
                try checkCurrent()
                if let requiredScene, observation.sceneIdentity != requiredScene {
                    return finish("paused", "窗口或页面上下文已变化，询问进度没有授权在新界面继续操作。")
                }
                requiredScene = nil
                resumeScene = observation.sceneIdentity
                if let pinnedApp, pinnedApp != observation.app { return finish("paused", "前台应用已改变，已暂停原任务。") }
                pinnedApp = observation.app
                var selectedTarget: DesktopTaskTarget?
                var modelDecision: DesktopTaskDecision?

                if step.action.needsTarget {
                    var candidates = step.candidates(in: observation)
                    if let pinnedTarget { candidates = candidates.filter { Self.sameTarget($0, pinnedTarget) } }
                    if candidates.isEmpty {
                        observation = try await observe()
                        try checkCurrent()
                        guard pinnedApp == observation.app else { return finish("paused", "重新观察时应用已变化。") }
                        candidates = step.candidates(in: observation)
                        if let pinnedTarget { candidates = candidates.filter { Self.sameTarget($0, pinnedTarget) } }
                    }
                    guard !candidates.isEmpty else { return finish("needs_clarification", "重新观察后仍未定位到指定目标，没有用其他控件替代。") }
                    if step.targetLabel != nil || pinnedTarget != nil {
                        guard candidates.count == 1 else { return finish("needs_clarification", "存在多个符合限定的同名目标，需要进一步区分位置。") }
                        selectedTarget = candidates[0]
                    } else {
                        var narrowed = observation
                        narrowed = DesktopTaskObservation(app: observation.app, targets: candidates, windowID: observation.windowID,
                            id: observation.id, capturedAt: observation.capturedAt, contentVersion: observation.contentVersion,
                            imageDataURL: observation.imageDataURL)
                        let decision: DesktopTaskDecision
                        do {
                            decision = try await decideWithStep(goal, step, narrowed, resumesSameTask ? priorSatisfiedActions : [], false)
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
                            decision = try await decideWithStep(goal, step, narrowed, resumesSameTask ? priorSatisfiedActions : [], true)
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

                if let selectedTarget, uncertainEffects.contains(where: { $0.app == observation.app && $0.target != nil && Self.sameTarget($0.target!, selectedTarget) }) {
                    return finish("uncertain_effect", "此前对此目标的操作结果仍未确认，不能自动重复。")
                }
                if selectedTarget == nil, uncertainEffects.contains(where: { $0.app == observation.app && $0.target == nil && $0.step == step }) {
                    return finish("uncertain_effect", "此前同一操作的结果仍未确认，不能自动重复。")
                }
                guard uncertainEffects.count < 32 else { return finish("paused", "未确认操作过多，请先检查现有结果。") }
                try checkCurrent()
                let label = selectedTarget?.label ?? step.application ?? step.key ?? step.direction ?? step.action.rawValue
                let packet = DesktopDecisionPacket.make(
                    step: step,
                    target: selectedTarget,
                    intent: effectiveIntent,
                    scope: plan.count > 1 ? .workflow : .single,
                    modelDecision: modelDecision
                )
                let attemptID = UUID().uuidString
                observation.actionAttemptID = attemptID
                records.append(DesktopActionRecord(id: attemptID, observationID: observation.id,
                    app: observation.app, targetID: selectedTarget?.id, label: label, action: step.action,
                    decisionPacket: packet, completionPolicy: DesktopStepCompletionPolicy(step: step),
                    delivery: .unknown, outcomeEvidence: .notObserved, detail: "已尝试下发，结果未确认"))
                uncertainEffects.append(UncertainEffect(app: observation.app, target: selectedTarget,
                    step: step, label: label, attemptID: attemptID, observationID: observation.id,
                    targetID: selectedTarget?.id, delivery: .unknown))
                DesktopVoiceTrace.event("action_attempt_started", turnID: turnID,
                    fields: ["task_id": taskID, "trace_id": attemptID, "observation_id": observation.id, "action": step.action.rawValue,
                             "decision_source": packet.source.rawValue, "scope": packet.scope.rawValue,
                             "action_confidence": packet.confidence.action.map { String($0) } ?? "unavailable",
                             "target_confidence": packet.confidence.target.map { String($0) } ?? "unavailable"],
                    privateFields: ["target": label])
                reportProgress()
                try checkCurrent()
                let result = try await DesktopTaskExecutionContext.$ownerID.withValue(executionOwnerID) {
                    try await executeStep(goal, observation, selectedTarget, step)
                }
                // The executor owns the two facts; the coordinator never
                // rewrites delivery or evidence from a completion flag.
                records[records.count - 1].delivery = result.delivery
                records[records.count - 1].outcomeEvidence = result.outcomeEvidence
                records[records.count - 1].detail = result.detail
                let evidence = records[records.count - 1]
                if let effectIndex = uncertainEffects.lastIndex(where: { $0.attemptID == attemptID }) {
                    uncertainEffects[effectIndex].delivery = result.delivery
                }
                DesktopVoiceTrace.event("action_evidence", turnID: turnID,
                    fields: ["task_id": taskID, "trace_id": attemptID, "observation_id": observation.id,
                             "delivery": evidence.delivery.rawValue,
                             "verified": String(evidence.verified),
                             "failure_stage": result.failureStage ?? "none",
                             "reason_code": result.reasonCode ?? "none"])
                // Cancellation stops future work, not factual bookkeeping.
                // A satisfied step remains done even when interruption
                // arrives before this invocation returns its receipt.
                if evidence.satisfied || evidence.delivery == .notSent, let selectedTarget {
                    uncertainEffects.removeAll { $0.app == observation.app && $0.target.map { Self.sameTarget($0, selectedTarget) } == true }
                }
                if evidence.satisfied || evidence.delivery == .notSent {
                    uncertainEffects.removeAll { $0.app == observation.app && $0.target == nil && $0.step == step }
                }
                if evidence.satisfied {
                    if step.action == .openApp { pinnedApp = result.resultingApp }
                    resumeScene = result.resultingScene ?? observation.sceneIdentity
                    nextStepIndex += 1
                }
                reportProgress()
                if ownedExecution != nil {
                    // Speech ends a response, not the already-observed fact.
                    // There is nothing to pause after the last satisfied step.
                    if evidence.satisfied, nextStepIndex == plan.count {
                        return finish("completed", "任务步骤均已结束；各步完成依据已记录在操作历史中。")
                    }
                    if evidence.uncertainEffect {
                        return finish("uncertain_effect", "操作结果未确认，已停止；不会自动重复。")
                    }
                }
                try checkCurrent()
                if evidence.delivery == .notSent { return finish("paused", result.detail) }
                guard evidence.satisfied else { return finish("uncertain_effect", "操作结果未确认，已停止；页面变化不等于目标完成。") }
            }
            return finish("completed", "本轮步骤均已结束；各步完成依据已记录在操作历史中。")
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
