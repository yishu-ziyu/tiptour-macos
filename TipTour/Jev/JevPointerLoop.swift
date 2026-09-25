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

    func run(task: String, app: String?, maxSteps: Int = 12) async -> Outcome {
        var history: [String] = []
        var inputTokens = 0
        var snapshot = JevStepSnapshot(
            step: 0, task: task, detected: 0, done: 0, absent: 0, bars: [],
            actionKind: "click", note: "Looking at the screen", finished: false,
            milliseconds: 0, inputTokens: 0
        )
        func finish(ok: Bool = false, reason: String?, message: String) -> Outcome {
            snapshot.finished = true
            snapshot.note = message
            report(snapshot)
            return Outcome(ok: ok, reason: reason, message: message, steps: history.count, inputTokens: inputTokens)
        }
        guard maxSteps > 0 else {
            return finish(reason: "step_budget", message: "No actions allowed.")
        }
        func targetAppChanged() -> Bool {
            guard let app, let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
            return frontmost.localizedName?.caseInsensitiveCompare(app) != .orderedSame
        }
        let traceID = TipTourActionTrace.makeID(source: "jev")
        // The final observation verifies the last allowed action without exceeding the action budget.
        for step in 1...(maxSteps + 1) {
            do {
                try Task.checkCancellation()
                guard !targetAppChanged() else {
                    return finish(reason: "app_changed", message: "App changed. Start a new JEV command in the app you want to use.")
                }
                let observation = engine.observe()
                guard observation.isCuaActionDriverEnabled else {
                    return finish(reason: "action_driver_disabled", message: "Enable desktop actions in Settings first.")
                }
                guard observation.isAutopilotEnabled else {
                    return finish(reason: "autopilot_disabled", message: "Enable auto-click to use JEV.")
                }
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
                    return finish(reason: "no_local_targets", message: "No visible targets found. Check screen permissions and try again.")
                }
                snapshot.note = "JEV is choosing from \(candidates.count) targets"
                report(snapshot)
                let (answers, metrics) = try await client.ask(state: request.state, questions: request.questions)
                try Task.checkCancellation()
                let decision = try JevGrounding.decision(from: answers, pool: request.pool, metrics: metrics)
                inputTokens += metrics.inputTokens
                snapshot.done = decision.done
                snapshot.absent = decision.absent
                snapshot.inputTokens = inputTokens
                snapshot.milliseconds = metrics.milliseconds
                snapshot.actionKind = decision.actionKind
                snapshot.bars = decision.ranked.prefix(5).map { entry in
                    JevStepSnapshot.Bar(id: entry.candidate.id, label: entry.candidate.label,
                        probability: entry.probability, isChosen: entry.candidate.id == decision.best?.candidate.id)
                }
                if decision.done >= JevGrounding.doneThreshold {
                    return finish(ok: true, reason: nil, message: "JEV reports the task complete after \(history.count) actions.")
                }
                if let reason = decision.stopReason {
                    let message = reason == "target_absent"
                        ? "JEV couldn't find the requested control among \(candidates.count) targets. Name a visible button or menu."
                        : "No target is available to click."
                    return finish(reason: reason, message: message)
                }
                guard step <= maxSteps else {
                    return finish(reason: "step_budget", message: "Stopped after \(maxSteps) actions.")
                }
                guard let chosen = decision.best else {
                    return finish(reason: "no_candidates", message: "No target to act on.")
                }
                snapshot.note = "\(decision.actionKind): \(chosen.candidate.label)"
                report(snapshot)
                guard !targetAppChanged() else {
                    return finish(reason: "app_changed", message: "App changed. JEV stopped before clicking.")
                }
                let result = await engine.runPointerAction(PointerActionRequest(
                    goal: task, app: app,
                    actionType: WorkflowStep.StepType.normalized(from: decision.actionKind),
                    targetLabel: chosen.candidate.label, targetID: chosen.candidate.id, targetMark: nil,
                    execute: true, allowScreenshotPlanning: false, validateStateChange: true, traceID: traceID
                ))
                try Task.checkCancellation()
                guard result.ok, result.workflowOutcome?.status == "completed" else {
                    return finish(reason: result.reason ?? "action_not_completed", message: result.message ?? "The action did not complete.")
                }
                history.append("\(decision.actionKind) \(chosen.candidate.label): completed")
                // The engine already waits for settlement and validates the action.
            } catch is CancellationError {
                return finish(reason: "cancelled", message: "Stopped.")
            } catch {
                if Task.isCancelled { return finish(reason: "cancelled", message: "Stopped.") }
                return finish(reason: "jev_error", message: error.localizedDescription)
            }
        }
        return finish(reason: "step_budget", message: "Action limit reached.")
    }
}
