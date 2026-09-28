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

    /// Facts one `run` call accumulates; every exit turns them into a receipt.
    private struct TaskRun {
        let goal: String
        let turnID: String
        let generation: Int
        let intent: DesktopTaskIntent
        let resumesSameTask: Bool
        let isCorrection: Bool
        let taskID: String
        let targetVersion: Int
        let priorActions: [String]
        /// Only independently verified effects enter the verified history;
        /// user-confirmed and delivery-confirmed steps stay in the satisfied
        /// history, which is the list the decision model reads as already-done.
        let priorVerifiedActions: [String]
        let priorSatisfiedActions: [String]
        var pinnedApp: String?
        var records: [DesktopActionRecord] = []
    }

    /// Ends a run early with the status and detail its receipt reports.
    private struct TaskRunEnd: Error {
        let status: String
        let detail: String
        init(_ status: String, _ detail: String) {
            self.status = status
            self.detail = detail
        }
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
        activeRunGeneration = generation
        defer { isRunning = false; activeRunGeneration = nil }

        var run = startRun(goal: goal, intent: intent, resumePrevious: resumePrevious, turnID: turnID)
        var requiredScene = expectedResumeScene
        do {
            let requestedPlan = try installPlan(for: run, requestedIntent: intent, namedTarget: namedTarget,
                exactTarget: exactTarget, action: action, maximumActions: maximumActions, steps: steps)
            let plan = previousPlan
            let pinnedRetryTarget = try resolveUncertainEffects(uncertainResolution, run: &run,
                plan: plan, requestedPlan: requestedPlan)
            let pinnedTarget = pinnedRetryTarget ?? exactTarget
            reportProgress(run)
            while nextStepIndex < plan.count {
                try await performNextStep(of: plan, run: &run, pinnedTarget: pinnedTarget, requiredScene: &requiredScene)
            }
            return finish(run, "completed", "本轮步骤均已结束；各步完成依据已记录在操作历史中。")
        } catch let end as TaskRunEnd {
            return finish(run, end.status, end.detail)
        } catch is CancellationError {
            return finish(run, "paused", "已中断；保留可能已经发生的操作，未下发步骤不会继续。")
        } catch {
            return finish(run, "failed", "任务未能完成，已停止，详情请查看诊断记录。")
        }
    }

    private func startRun(goal: String, intent: DesktopTaskIntent?, resumePrevious: Bool, turnID: String) -> TaskRun {
        let previous = lastReceipt
        let wantsResume = intent == .resume || (intent == nil && resumePrevious)
        let sameGoal = previous.map { DesktopActionStep.normalized($0.goal) == DesktopActionStep.normalized(goal) } ?? false
        let resumesSameTask = wantsResume && sameGoal && !previousPlan.isEmpty
        let isCorrection = intent == .correct || (wantsResume && !sameGoal)
        let continuesPrevious = wantsResume || isCorrection
        let taskID = (resumesSameTask || isCorrection) ? previous?.taskID ?? UUID().uuidString : UUID().uuidString
        if uncertainEffectsTaskID != taskID {
            uncertainEffects = []
            uncertainEffectsTaskID = taskID
        }
        // An invalid replacement request must not leave the old plan attached
        // to the new receipt's goal, where a later resume could execute it.
        if !resumesSameTask {
            previousPlan = []
            nextStepIndex = 0
            resumeScene = nil
        }
        return TaskRun(goal: goal, turnID: turnID, generation: generation,
            intent: intent ?? (resumePrevious ? .resume : .new),
            resumesSameTask: resumesSameTask, isCorrection: isCorrection, taskID: taskID,
            targetVersion: isCorrection ? (previous?.targetVersion ?? 0) + 1 : (resumesSameTask ? previous?.targetVersion ?? 1 : 1),
            priorActions: continuesPrevious ? Array(((previous?.priorActions ?? []) + (previous?.actions ?? [])).suffix(32)) : [],
            priorVerifiedActions: continuesPrevious ? (previous?.verifiedActionHistory ?? []) : [],
            priorSatisfiedActions: continuesPrevious ? (previous?.satisfiedActionHistory ?? []) : [],
            pinnedApp: resumesSameTask ? previous?.app : nil)
    }

    private func checkCurrent(_ run: TaskRun) throws {
        try Task.checkCancellation()
        guard run.generation == generation, !journalUnavailable else { throw CancellationError() }
    }

    private func makeReceipt(for run: TaskRun, status: String, detail: String) -> DesktopTaskReceipt {
        DesktopTaskReceipt(goal: run.goal, status: status,
            actions: run.records.filter { $0.delivery != .notSent }.map(\.summary), detail: detail,
            app: run.pinnedApp, taskID: run.taskID, turnID: run.turnID, targetVersion: run.targetVersion,
            priorActions: run.priorActions, currentActions: run.records,
            verifiedActionHistory: Array((run.priorVerifiedActions + run.records.filter(\.verified).map(\.summary)).suffix(32)),
            satisfiedActionHistory: Array((run.priorSatisfiedActions + run.records.filter(\.satisfied).map(\.summary)).suffix(32)),
            completedStepCount: nextStepIndex, totalStepCount: previousPlan.count)
    }

    private func finish(_ run: TaskRun, _ status: String, _ detail: String) -> DesktopTaskReceipt {
        let finalStatus = cancelledTaskID == run.taskID ? "cancelled" : status
        let receipt = makeReceipt(for: run, status: finalStatus, detail: detail)
        if ["completed", "cancelled"].contains(finalStatus)
            || (finalStatus == "failed" && uncertainEffects.isEmpty) { hasPersistentReservation = false }
        publish(receipt)
        DesktopVoiceTrace.event("task_finished", turnID: run.turnID,
            fields: ["task_id": run.taskID, "status": lastReceipt?.status ?? finalStatus, "target_version": String(run.targetVersion),
                     "new_action_count": String(receipt.actions.count)])
        return lastReceipt ?? receipt
    }

    private func reportProgress(_ run: TaskRun) {
        guard ownedExecution != nil else { return }
        let status = cancelledTaskID == run.taskID ? "cancelling"
            : (generation != run.generation ? "pausing" : "running")
        publish(makeReceipt(for: run, status: status, detail: "执行状态，尚非完成声明。"))
    }

    /// Validates the request and installs its plan; a resume keeps the plan it continues.
    private func installPlan(for run: TaskRun, requestedIntent: DesktopTaskIntent?, namedTarget: String?,
                             exactTarget: DesktopTaskTarget?, action: String?, maximumActions: Int,
                             steps: [DesktopActionStep]?) throws -> [DesktopActionStep] {
        guard requestedIntent != .resume || run.resumesSameTask else {
            throw TaskRunEnd("paused", "没有与这个目标对应的可续接计划，未执行。")
        }
        guard !DesktopActionStep.normalized(run.goal).isEmpty, maximumActions > 0 else {
            throw TaskRunEnd("failed", "任务或操作预算无效。")
        }
        let singleAction = try Self.singleAction(action)
        let requestedPlan = steps ?? [DesktopActionStep(action: singleAction, targetLabel: namedTarget)]
        guard !requestedPlan.isEmpty, requestedPlan.count <= min(maximumActions, 6),
              exactTarget == nil || requestedPlan.count == 1 else {
            throw TaskRunEnd("failed", "任务必须包含一到六个明确步骤；旧观察编号只能用于单目标操作。")
        }
        for step in requestedPlan { try step.validate() }
        if run.resumesSameTask {
            guard steps == nil || requestedPlan == previousPlan else { throw TaskRunEnd("paused", "续接任务的步骤发生变化，请作为纠正提交。") }
        } else {
            previousPlan = requestedPlan
            nextStepIndex = 0
        }
        guard nextStepIndex < previousPlan.count else {
            throw TaskRunEnd("paused", "此前步骤已结束；本轮没有重新执行，也没有重新验证。")
        }
        return requestedPlan
    }

    private static func singleAction(_ action: String?) throws -> DesktopActionKind {
        guard let action else { return .click }
        guard let parsed = DesktopActionKind(rawValue: action) else { throw TaskRunEnd("failed", "动作类型不受支持。") }
        return parsed
    }

    // MARK: - Unconfirmed side effects

    /// An unconfirmed side effect owns this task until the user resolves it
    /// explicitly. A plain resume or correction must not ask the model for the
    /// next-best candidate — that is how one uncertain click turned into a
    /// click on something else. Returns the target a retry must reuse.
    private func resolveUncertainEffects(_ resolution: DesktopTaskUncertainResolution?, run: inout TaskRun,
                                         plan: [DesktopActionStep], requestedPlan: [DesktopActionStep]) throws -> DesktopTaskTarget? {
        guard !uncertainEffects.isEmpty else { return nil }
        guard let resolution else {
            throw TaskRunEnd("uncertain_effect", "上一步的结果还未确认，已停下，不会换别的目标去试。你看一眼它生效了没有，告诉我成了还是没成；要重试或者换目标，也直接说。")
        }
        switch resolution {
        case .confirmedSucceeded:
            try acceptUserConfirmedSuccess(run: &run, plan: plan)
        case .confirmedFailed:
            // Acknowledged failure: the attempt stays in
            // attempted-unverified history, the block lifts.
            clearUncertainEffects(run, .confirmedFailed, ["promoted_to_verified": "false"])
        case .retrySame:
            return try pinnedTargetForRetry(run: run, plan: plan)
        case .replaceTarget:
            try acceptExplicitReplacement(run: run, requestedPlan: requestedPlan)
        }
        return nil
    }

    private func clearUncertainEffects(_ run: TaskRun, _ resolution: DesktopTaskUncertainResolution,
                                       _ traceFields: [String: String]) {
        uncertainEffects = []
        DesktopVoiceTrace.event("uncertain_resolved", turnID: run.turnID,
            fields: ["task_id": run.taskID, "resolution": resolution.rawValue].merging(traceFields) { current, _ in current })
    }

    /// The user confirms the attempt landed: that is user-confirmed outcome
    /// evidence. It satisfies the step and enters satisfied history with
    /// user-confirmed wording, but it is never a system verification, so it
    /// must not enter the verified history. A user confirming success also
    /// settles delivery affirmatively.
    private func acceptUserConfirmedSuccess(run: inout TaskRun, plan: [DesktopActionStep]) throws {
        for effect in uncertainEffects {
            run.records.append(DesktopActionRecord(id: effect.attemptID,
                observationID: effect.observationID, app: effect.app,
                targetID: effect.targetID, label: effect.label, action: effect.step.action,
                decisionPacket: nil,
                completionPolicy: DesktopStepCompletionPolicy(step: effect.step),
                delivery: .sent, outcomeEvidence: .userConfirmed,
                detail: "用户确认该操作已经生效"))
        }
        clearUncertainEffects(run, .confirmedSucceeded, ["user_confirmed": "true", "promoted_to_verified": "false"])
        guard run.resumesSameTask else { return }
        nextStepIndex += 1
        if nextStepIndex >= plan.count {
            throw TaskRunEnd("completed", "你已确认上一轮操作的结果生效，任务完成。")
        }
    }

    /// Pins the recorded target so the retry cannot let the decision layer
    /// quietly pick the runner-up candidate.
    private func pinnedTargetForRetry(run: TaskRun, plan: [DesktopActionStep]) throws -> DesktopTaskTarget? {
        guard run.resumesSameTask else {
            throw TaskRunEnd("uncertain_effect", "上一步的结果还未确认，已停下。重试只能针对同一个目标；要换目标，请直接说换成哪个。")
        }
        let step = plan[nextStepIndex]
        let stepLeavesTargetOpen = step.action.needsTarget && step.targetLabel == nil
            && step.region == nil && step.anchorLabel == nil
        let pinnedTarget = stepLeavesTargetOpen ? uncertainEffects.first(where: { $0.target != nil })?.target : nil
        clearUncertainEffects(run, .retrySame, ["pinned_target": String(pinnedTarget != nil)])
        return pinnedTarget
    }

    private func acceptExplicitReplacement(run: TaskRun, requestedPlan: [DesktopActionStep]) throws {
        guard run.isCorrection else {
            throw TaskRunEnd("uncertain_effect", "上一步的结果还未确认，已停下。要换目标，请说清换成哪一个。")
        }
        let explicitlyTargeted = requestedPlan.allSatisfy { step in
            !step.action.needsTarget || step.targetLabel != nil || step.region != nil
                || (step.anchorLabel != nil && step.relation != nil)
        }
        guard explicitlyTargeted else {
            throw TaskRunEnd("needs_clarification", "要换成哪个目标？请说出它的名字或位置，我不会自己挑。")
        }
        clearUncertainEffects(run, .replaceTarget, ["replaced_target": "true"])
    }

    private func refuseRepeatingUncertainEffect(of step: DesktopActionStep, on target: DesktopTaskTarget?,
                                                in app: String) throws {
        if let target, uncertainEffects.contains(where: { $0.app == app && $0.target != nil && Self.sameTarget($0.target!, target) }) {
            throw TaskRunEnd("uncertain_effect", "此前对此目标的操作结果仍未确认，不能自动重复。")
        }
        if target == nil, uncertainEffects.contains(where: { $0.app == app && $0.target == nil && $0.step == step }) {
            throw TaskRunEnd("uncertain_effect", "此前同一操作的结果仍未确认，不能自动重复。")
        }
        guard uncertainEffects.count < 32 else { throw TaskRunEnd("paused", "未确认操作过多，请先检查现有结果。") }
    }

    // MARK: - One step

    private func performNextStep(of plan: [DesktopActionStep], run: inout TaskRun, pinnedTarget: DesktopTaskTarget?,
                                 requiredScene: inout DesktopTaskSceneIdentity?) async throws {
        try checkCurrent(run)
        var step = plan[nextStepIndex]
        if step.expectedLabel == nil, nextStepIndex + 1 < plan.count {
            step.expectedLabel = plan[nextStepIndex + 1].targetLabel
        }
        var observation = try await observeScene(for: step, run: &run, requiredScene: &requiredScene)
        let (selectedTarget, modelDecision) = try await selectTarget(for: &step, observation: &observation,
            run: run, pinnedTarget: pinnedTarget)
        try refuseRepeatingUncertainEffect(of: step, on: selectedTarget, in: observation.app)
        try checkCurrent(run)
        let packet = DesktopDecisionPacket.make(
            step: step,
            target: selectedTarget,
            intent: run.intent,
            scope: plan.count > 1 ? .workflow : .single,
            modelDecision: modelDecision
        )
        let attemptID = UUID().uuidString
        observation.actionAttemptID = attemptID
        recordAttempt(attemptID, of: step, on: selectedTarget, observation: observation, packet: packet, run: &run)
        reportProgress(run)
        try checkCurrent(run)
        let goal = run.goal
        let result = try await DesktopTaskExecutionContext.$ownerID.withValue(executionOwnerID) {
            try await executeStep(goal, observation, selectedTarget, step)
        }
        let evidence = recordResult(result, attemptID: attemptID, observationID: observation.id, run: &run)
        try settle(evidence, result: result, step: step, target: selectedTarget, observation: observation,
            plan: plan, run: &run)
    }

    private func observeScene(for step: DesktopActionStep, run: inout TaskRun,
                              requiredScene: inout DesktopTaskSceneIdentity?) async throws -> DesktopTaskObservation {
        let observation = step.action == .openApp ? try await observeContext() : try await observe()
        try checkCurrent(run)
        if let requiredScene, observation.sceneIdentity != requiredScene {
            throw TaskRunEnd("paused", "窗口或页面上下文已变化，询问进度没有授权在新界面继续操作。")
        }
        requiredScene = nil
        resumeScene = observation.sceneIdentity
        if let pinnedApp = run.pinnedApp, pinnedApp != observation.app { throw TaskRunEnd("paused", "前台应用已改变，已暂停原任务。") }
        run.pinnedApp = observation.app
        return observation
    }

    private func selectTarget(for step: inout DesktopActionStep, observation: inout DesktopTaskObservation,
                              run: TaskRun, pinnedTarget: DesktopTaskTarget?) async throws -> (DesktopTaskTarget?, DesktopTaskDecision?) {
        guard step.action.needsTarget else { return (nil, nil) }
        let candidates = try await locateCandidates(for: step, observation: &observation, run: run, pinnedTarget: pinnedTarget)
        if step.targetLabel != nil || pinnedTarget != nil {
            guard candidates.count == 1 else { throw TaskRunEnd("needs_clarification", "存在多个符合限定的同名目标，需要进一步区分位置。") }
            return (candidates[0], nil)
        }
        return try await decideTarget(for: &step, among: candidates, observation: &observation, run: run)
    }

    private func matchingCandidates(for step: DesktopActionStep, in observation: DesktopTaskObservation,
                                    pinnedTarget: DesktopTaskTarget?) -> [DesktopTaskTarget] {
        let candidates = step.candidates(in: observation)
        guard let pinnedTarget else { return candidates }
        return candidates.filter { Self.sameTarget($0, pinnedTarget) }
    }

    private func locateCandidates(for step: DesktopActionStep, observation: inout DesktopTaskObservation,
                                  run: TaskRun, pinnedTarget: DesktopTaskTarget?) async throws -> [DesktopTaskTarget] {
        var candidates = matchingCandidates(for: step, in: observation, pinnedTarget: pinnedTarget)
        if candidates.isEmpty {
            observation = try await observe()
            try checkCurrent(run)
            guard run.pinnedApp == observation.app else { throw TaskRunEnd("paused", "重新观察时应用已变化。") }
            candidates = matchingCandidates(for: step, in: observation, pinnedTarget: pinnedTarget)
        }
        guard !candidates.isEmpty else { throw TaskRunEnd("needs_clarification", "重新观察后仍未定位到指定目标，没有用其他控件替代。") }
        return candidates
    }

    private func decideTarget(for step: inout DesktopActionStep, among candidates: [DesktopTaskTarget],
                              observation: inout DesktopTaskObservation,
                              run: TaskRun) async throws -> (DesktopTaskTarget?, DesktopTaskDecision?) {
        let satisfiedHistory = run.resumesSameTask ? run.priorSatisfiedActions : []
        var narrowed = observation.limited(to: candidates)
        let decision: DesktopTaskDecision
        do {
            decision = try await decideWithStep(run.goal, step, narrowed, satisfiedHistory, false)
        } catch {
            try checkCurrent(run)
            observation = try await observe()
            try checkCurrent(run)
            guard observation.app == run.pinnedApp else { throw TaskRunEnd("paused", "恢复观察时应用已变化。") }
            let recoveredCandidates = step.candidates(in: observation)
            guard !recoveredCandidates.isEmpty else { throw TaskRunEnd("needs_clarification", "恢复观察后没有合适目标。") }
            narrowed = observation.limited(to: recoveredCandidates)
            decision = try await decideWithStep(run.goal, step, narrowed, satisfiedHistory, true)
        }
        try checkCurrent(run)
        let proposed = try Self.proposedTarget(of: decision, in: narrowed)
        if step.allowsActionDecision {
            step.action = try Self.decidedPointerAction(decision)
        }
        // A slow decision must not carry old geometry into a new scene.
        let fresh = try await observe()
        try checkCurrent(run)
        guard fresh.app == narrowed.app, fresh.windowID == narrowed.windowID else {
            throw TaskRunEnd("paused", "决策期间窗口已变化，旧选择未执行。")
        }
        let matches = step.candidates(in: fresh).filter { Self.sameTarget($0, proposed) }
        guard matches.count == 1 else { throw TaskRunEnd("paused", "决策期间目标已变化，旧选择未执行。") }
        observation = fresh
        return (matches[0], decision)
    }

    private static func proposedTarget(of decision: DesktopTaskDecision,
                                       in narrowed: DesktopTaskObservation) throws -> DesktopTaskTarget {
        guard !decision.completed else { throw TaskRunEnd("paused", "模型判断完成，但没有独立结果证据，不能确认任务完成。") }
        guard !decision.declined, let identifier = decision.targetID else {
            throw TaskRunEnd("needs_clarification", "当前没有可确认的目标，没有继续尝试其他控件。")
        }
        guard let proposed = narrowed.targets.first(where: { $0.id == identifier }) else {
            throw TaskRunEnd("failed", "模型选择不在当前受限候选内，未执行。")
        }
        return proposed
    }

    private static func decidedPointerAction(_ decision: DesktopTaskDecision) throws -> DesktopActionKind {
        guard let decidedAction = DesktopActionKind(rawValue: decision.action),
              [.click, .doubleClick, .rightClick].contains(decidedAction) else {
            throw TaskRunEnd("failed", "决策返回了不允许的动作类型，未执行。")
        }
        return decidedAction
    }

    private func recordAttempt(_ attemptID: String, of step: DesktopActionStep, on target: DesktopTaskTarget?,
                               observation: DesktopTaskObservation, packet: DesktopDecisionPacket, run: inout TaskRun) {
        let label = target?.label ?? step.application ?? step.key ?? step.direction ?? step.action.rawValue
        run.records.append(DesktopActionRecord(id: attemptID, observationID: observation.id,
            app: observation.app, targetID: target?.id, label: label, action: step.action,
            decisionPacket: packet, completionPolicy: DesktopStepCompletionPolicy(step: step),
            delivery: .unknown, outcomeEvidence: .notObserved, detail: "已尝试下发，结果未确认"))
        uncertainEffects.append(UncertainEffect(app: observation.app, target: target,
            step: step, label: label, attemptID: attemptID, observationID: observation.id,
            targetID: target?.id, delivery: .unknown))
        DesktopVoiceTrace.event("action_attempt_started", turnID: run.turnID,
            fields: ["task_id": run.taskID, "trace_id": attemptID, "observation_id": observation.id, "action": step.action.rawValue,
                     "decision_source": packet.source.rawValue, "scope": packet.scope.rawValue,
                     "action_confidence": packet.confidence.action.map { String($0) } ?? "unavailable",
                     "target_confidence": packet.confidence.target.map { String($0) } ?? "unavailable"],
            privateFields: ["target": label])
    }

    /// The executor owns the two facts; the coordinator never
    /// rewrites delivery or evidence from a completion flag.
    private func recordResult(_ result: DesktopTaskActionResult, attemptID: String, observationID: String,
                              run: inout TaskRun) -> DesktopActionRecord {
        run.records[run.records.count - 1].delivery = result.delivery
        run.records[run.records.count - 1].outcomeEvidence = result.outcomeEvidence
        run.records[run.records.count - 1].detail = result.detail
        let evidence = run.records[run.records.count - 1]
        if let effectIndex = uncertainEffects.lastIndex(where: { $0.attemptID == attemptID }) {
            uncertainEffects[effectIndex].delivery = result.delivery
        }
        DesktopVoiceTrace.event("action_evidence", turnID: run.turnID,
            fields: ["task_id": run.taskID, "trace_id": attemptID, "observation_id": observationID,
                     "delivery": evidence.delivery.rawValue,
                     "verified": String(evidence.verified),
                     "failure_stage": result.failureStage ?? "none",
                     "reason_code": result.reasonCode ?? "none"])
        return evidence
    }

    private func releaseUncertainEffects(of step: DesktopActionStep, on target: DesktopTaskTarget?, in app: String) {
        if let target {
            uncertainEffects.removeAll { $0.app == app && $0.target.map { Self.sameTarget($0, target) } == true }
        }
        uncertainEffects.removeAll { $0.app == app && $0.target == nil && $0.step == step }
    }

    /// Cancellation stops future work, not factual bookkeeping.
    /// A satisfied step remains done even when interruption
    /// arrives before this invocation returns its receipt.
    private func settle(_ evidence: DesktopActionRecord, result: DesktopTaskActionResult, step: DesktopActionStep,
                        target: DesktopTaskTarget?, observation: DesktopTaskObservation,
                        plan: [DesktopActionStep], run: inout TaskRun) throws {
        if evidence.satisfied || evidence.delivery == .notSent {
            releaseUncertainEffects(of: step, on: target, in: observation.app)
        }
        if evidence.satisfied {
            if step.action == .openApp { run.pinnedApp = result.resultingApp }
            resumeScene = result.resultingScene ?? observation.sceneIdentity
            nextStepIndex += 1
        }
        reportProgress(run)
        if ownedExecution != nil {
            // Speech ends a response, not the already-observed fact.
            // There is nothing to pause after the last satisfied step.
            if evidence.satisfied, nextStepIndex == plan.count {
                throw TaskRunEnd("completed", "任务步骤均已结束；各步完成依据已记录在操作历史中。")
            }
            if evidence.uncertainEffect {
                throw TaskRunEnd("uncertain_effect", "操作结果未确认，已停止；不会自动重复。")
            }
        }
        try checkCurrent(run)
        if evidence.delivery == .notSent { throw TaskRunEnd("paused", result.detail) }
        guard evidence.satisfied else { throw TaskRunEnd("uncertain_effect", "操作结果未确认，已停止；页面变化不等于目标完成。") }
    }

    static func sameTarget(_ target: DesktopTaskTarget, _ previous: DesktopTaskTarget) -> Bool {
        // IDs alone are not proof: a provider may reuse one after a refresh.
        LocalTargetContinuity.matches(label: target.label, source: target.source, box: target.box, display: target.display,
            previousLabel: previous.label, previousSource: previous.source, previousBox: previous.box, previousDisplay: previous.display)
    }
}

private extension DesktopTaskObservation {
    /// The same observation offering only these targets.
    func limited(to targets: [DesktopTaskTarget]) -> DesktopTaskObservation {
        DesktopTaskObservation(app: app, targets: targets, windowID: windowID,
            id: id, capturedAt: capturedAt, contentVersion: contentVersion,
            imageDataURL: imageDataURL)
    }
}
