import AppKit
import Foundation

struct JevStepSnapshot: Equatable {
    struct Bar: Equatable, Identifiable {
        let id: String
        let label: String
        let probability: Double
        let isChosen: Bool
    }

    var step: Int
    var task: String
    var detected: Int
    var done: Double
    var absent: Double
    var bars: [Bar]
    var actionKind: String
    var note: String            // what just happened, one short line
    var finished: Bool
    var milliseconds: Int
    var inputTokens: Int
}

/// JEV selects from fresh local targets; the shared engine owns execution and validation.
@MainActor
final class JevPointerLoop {
    private let engine: TipTourEngine
    private let client: JevClient
    private let report: @MainActor (JevStepSnapshot) -> Void

    init(engine: TipTourEngine, client: JevClient = .shared,
         report: @escaping @MainActor (JevStepSnapshot) -> Void) {
        self.engine = engine
        self.client = client
        self.report = report
    }

    struct Outcome {
        let ok: Bool
        let reason: String?
        let message: String
        let steps: Int
        let inputTokens: Int
    }

    /// Ends a run with what it reports to the user.
    private struct JevStop: Error {
        var ok = false
        let reason: String?
        let message: String
    }

    func run(task: String, app: String?, maxSteps: Int = 12) async -> Outcome {
        var history: [String] = []
        var inputTokens = 0
        var snapshot = JevStepSnapshot(
            step: 0, task: task, detected: 0, done: 0, absent: 0, bars: [],
            actionKind: "click", note: "正在看屏幕", finished: false,
            milliseconds: 0, inputTokens: 0
        )
        func finish(_ stop: JevStop) -> Outcome {
            snapshot.finished = true
            snapshot.note = stop.message
            report(snapshot)
            return Outcome(ok: stop.ok, reason: stop.reason, message: stop.message, steps: history.count, inputTokens: inputTokens)
        }
        guard maxSteps > 0 else {
            return finish(JevStop(reason: "step_budget", message: "这次不允许执行任何动作。"))
        }
        let traceID = TipTourActionTrace.makeID(source: "jev")
        // The final observation verifies the last allowed action without exceeding the action budget.
        for step in 1...(maxSteps + 1) {
            do {
                try await runStep(step, task: task, app: app, maxSteps: maxSteps, traceID: traceID,
                                  history: &history, inputTokens: &inputTokens, snapshot: &snapshot)
            } catch let stop as JevStop {
                return finish(stop)
            } catch is CancellationError {
                return finish(JevStop(reason: "cancelled", message: "停下了。"))
            } catch {
                if Task.isCancelled { return finish(JevStop(reason: "cancelled", message: "停下了。")) }
                return finish(JevStop(reason: "jev_error", message: error.localizedDescription))
            }
        }
        return finish(JevStop(reason: "step_budget", message: "动作次数用完了，先停下。"))
    }

    /// Observes, lets JEV choose, and has the engine perform one action.
    private func runStep(_ step: Int, task: String, app: String?, maxSteps: Int, traceID: String,
                         history: inout [String], inputTokens: inout Int,
                         snapshot: inout JevStepSnapshot) async throws {
        try Task.checkCancellation()
        guard !Self.targetAppChanged(app) else {
            throw JevStop(reason: "app_changed", message: "前台应用变了，已经停下。到要操作的应用里再说一次。")
        }
        try checkDesktopActionsAllowed()
        let list = await engine.localPerceptionTargets(refresh: true, reason: "JEV step \(step)")
        try Task.checkCancellation()
        let candidates = list.targets.map { target in
            JevCandidate(
                id: target.id, label: target.label, source: target.source,
                confidence: target.confidence,
                centre: CGPoint(x: target.globalCenter.first ?? 0,
                                y: target.globalCenter.dropFirst().first ?? 0)
            )
        }
        snapshot.step = step
        snapshot.detected = candidates.count
        guard let request = JevGrounding.request(
            task: task, candidates: candidates, history: history, excluding: []
        ) else {
            throw JevStop(reason: "no_local_targets", message: "屏幕上没找到能点的东西。检查屏幕录制权限后再试。")
        }
        snapshot.note = "JEV is choosing from \(candidates.count) targets"
        report(snapshot)
        let (answers, metrics) = try await client.ask(state: request.state, questions: request.questions)
        try Task.checkCancellation()
        let decision = try JevGrounding.decision(from: answers, pool: request.pool, metrics: metrics)
        inputTokens += metrics.inputTokens
        Self.show(decision, milliseconds: metrics.milliseconds, inputTokens: inputTokens, in: &snapshot)
        try Self.checkDecisionCallsForAction(decision, history: history, candidateCount: candidates.count,
                                             step: step, maxSteps: maxSteps)
        guard let chosen = decision.best else {
            throw JevStop(reason: "no_candidates", message: "没有可以操作的目标。")
        }
        snapshot.note = "\(decision.actionKind): \(chosen.candidate.label)"
        report(snapshot)
        guard !Self.targetAppChanged(app) else {
            throw JevStop(reason: "app_changed", message: "前台应用变了，JEV 在点击前停下了。")
        }
        let result = await engine.runPointerAction(PointerActionRequest(
            goal: task, app: app,
            actionType: WorkflowStep.StepType.normalized(from: decision.actionKind),
            targetLabel: chosen.candidate.label, targetID: chosen.candidate.id, targetMark: nil,
            execute: true, allowScreenshotPlanning: false, validateStateChange: true, traceID: traceID
        ))
        try Task.checkCancellation()
        guard result.ok, result.workflowOutcome?.status == "completed" else {
            throw JevStop(reason: result.reason ?? "action_not_completed", message: result.message ?? "这一步没有完成。")
        }
        history.append("\(decision.actionKind) \(chosen.candidate.label): completed")
        // The engine already waits for settlement and validates the action.
    }

    private static func targetAppChanged(_ app: String?) -> Bool {
        guard let app, let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        return frontmost.localizedName?.caseInsensitiveCompare(app) != .orderedSame
    }

    private func checkDesktopActionsAllowed() throws {
        let observation = engine.observe()
        guard observation.isCuaActionDriverEnabled else {
            throw JevStop(reason: "action_driver_disabled", message: "先在 设置 → 桌面操作 里打开「操作桌面」。")
        }
        guard observation.isAutopilotEnabled else {
            throw JevStop(reason: "autopilot_disabled", message: "先在 设置 → 桌面操作 里打开「自动点击」。")
        }
    }

    private static func show(_ decision: JevDecision, milliseconds: Int, inputTokens: Int,
                             in snapshot: inout JevStepSnapshot) {
        snapshot.done = decision.done
        snapshot.absent = decision.absent
        snapshot.inputTokens = inputTokens
        snapshot.milliseconds = milliseconds
        snapshot.actionKind = decision.actionKind
        snapshot.bars = decision.ranked.prefix(5).map { entry in
            JevStepSnapshot.Bar(id: entry.candidate.id, label: entry.candidate.label,
                probability: entry.probability, isChosen: entry.candidate.id == decision.best?.candidate.id)
        }
    }

    /// Stops when JEV judges the task done, finds nothing to act on, or the
    /// step budget is spent; otherwise the chosen action may run.
    private static func checkDecisionCallsForAction(_ decision: JevDecision, history: [String], candidateCount: Int,
                                                    step: Int, maxSteps: Int) throws {
        if decision.done >= JevGrounding.doneThreshold {
            // "Done" is JEV's own judgement; with no action taken there is nothing it did to point to.
            guard !history.isEmpty else {
                throw JevStop(reason: "done_without_action",
                              message: "JEV 判断已经是想要的样子，但一步都没做，这次不算完成。你看一眼屏幕是不是已经好了。")
            }
            throw JevStop(ok: true, reason: nil,
                          message: "JEV 做了 \(history.count) 步，判断已经完成（这是 JEV 自己的判断，Her 没有另外核验）。")
        }
        if let reason = decision.stopReason {
            let message = reason == "target_absent"
                ? "JEV 在屏幕上 \(candidateCount) 个控件里没找到你说的那个。说一个看得见的按钮或菜单名。"
                : "没有可以点的目标。"
            throw JevStop(reason: reason, message: message)
        }
        guard step <= maxSteps else {
            throw JevStop(reason: "step_budget", message: "做了 \(maxSteps) 步还没完成，先停下了。")
        }
    }
}
