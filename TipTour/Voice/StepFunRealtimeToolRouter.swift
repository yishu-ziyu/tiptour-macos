//
//  StepFunRealtimeToolRouter.swift
//  TipTour
//
//  Turns the voice model's two tool calls into desktop actions.
//
//  The routing is intentionally thin. `describe_screen` only reads what local
//  perception already found and numbers it; `act_on_screen` only translates a
//  number back into the label it stood for and hands that label to
//  `JevPointerLoop`. Everything that actually decides and executes — grounding,
//  target continuity, action kind, post-action validation — stays inside the
//  existing loop, so the voice path has no separate notion of how to click.
//
//  Why a label rather than a coordinate: the model is never given one, so it
//  cannot invent one, and the loop re-perceives before acting so a control that
//  moved in the meantime is still found.
//

import Foundation

@MainActor
final class StepFunRealtimeToolRouter: StepFunRealtimeToolHandling {
    private let engine: TipTourEngine
    private var currentDescription: StepFunScreenDescription?

    /// How many controls to put in front of the model.
    ///
    /// A full desktop can carry hundreds of detections. Jev's own guidance says
    /// accuracy degrades as the state grows, and a spoken list nobody can follow
    /// is worse than a short one. The engine's own ceiling is higher; this is the
    /// number that is actually useful to a person listening.
    static let maximumControlsPresented = 30

    init(engine: TipTourEngine) {
        self.engine = engine
    }

    func handleToolCall(name: String, argumentsJSON: String) async throws -> String {
        switch name {
        case "describe_screen":
            return await describeScreen(argumentsJSON: argumentsJSON)
        case "act_on_screen":
            return await actOnScreen(argumentsJSON: argumentsJSON)
        default:
            // An unknown tool is a configuration error, not something to guess at.
            return "Unknown tool \(name). Available: describe_screen, act_on_screen."
        }
    }

    // MARK: - describe_screen

    private func describeScreen(argumentsJSON: String) async -> String {
        let intent = stringArgument("intent", in: argumentsJSON) ?? ""

        // A fresh refresh is what makes the numbering trustworthy: the whole
        // point of the number is that it refers to what is on screen now.
        let targetList = await engine.localPerceptionTargets(
            refresh: true,
            reason: "voice describe_screen"
        )

        guard targetList.ok, !targetList.targets.isEmpty else {
            currentDescription = nil
            return """
                No interactive controls were detected. Screen recording or accessibility \
                permission may be missing — ask the user to grant it in System Settings.
                """
        }

        let ranked = rankByRelevanceToIntent(targetList.targets, intent: intent)
        let presented = Array(ranked.prefix(Self.maximumControlsPresented))

        let entries = presented.enumerated().map { position, target in
            StepFunScreenControlEntry(
                index: position + 1,
                label: target.label,
                kind: controlKind(for: target)
            )
        }
        currentDescription = StepFunScreenDescription(
            entries: entries,
            activeAppName: targetList.activeAppName
        )

        let rendered = currentDescription?.renderedForVoiceModel() ?? ""
        print("[StepFunRealtimeTools] describe_screen: \(entries.count) of \(targetList.targetCount) controls, intent=\"\(intent)\"")
        return rendered
    }

    /// Orders detections so the ones the user probably means come first.
    ///
    /// Deliberately simple — a substring test against the label, plus the
    /// detector's own confidence. A semantic ranker here would mean a network
    /// call on every description, which is latency this loop cannot afford, and
    /// the confidence floor already keeps junk out of the list.
    private func rankByRelevanceToIntent(
        _ targets: [LocalPerceptionTargetCache.SnapshotTarget],
        intent: String
    ) -> [LocalPerceptionTargetCache.SnapshotTarget] {
        let normalisedIntent = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        return targets.sorted { left, right in
            let leftScore = relevanceScore(of: left, to: normalisedIntent)
            let rightScore = relevanceScore(of: right, to: normalisedIntent)
            if leftScore != rightScore { return leftScore > rightScore }
            return left.confidence > right.confidence
        }
    }

    private func relevanceScore(
        of target: LocalPerceptionTargetCache.SnapshotTarget,
        to intent: String
    ) -> Double {
        guard !intent.isEmpty, !target.label.isEmpty else { return 0 }
        // The label appearing verbatim in what the user said is the strongest
        // signal available without a language model.
        if intent.localizedCaseInsensitiveContains(target.label) { return 3 }
        // A two-character overlap catches Chinese compounds split differently in
        // speech ("新建标签" vs "新标签页") without needing a tokenizer.
        if intent.count >= 2, target.label.count >= 2 {
            let labelPrefix = String(target.label.prefix(2))
            if intent.contains(labelPrefix) { return 1 }
        }
        return 0
    }

    /// What to call a control when reading it back. Local perception sources are
    /// already coarse ("ocr", "yolo", "ax"); this keeps the spoken list honest
    /// about what kind of thing each row is.
    private func controlKind(for target: LocalPerceptionTargetCache.SnapshotTarget) -> String {
        switch target.source {
        case "ax": return "control"
        case "ocr": return "text"
        case "yolo": return "element"
        default: return target.source.isEmpty ? "control" : target.source
        }
    }

    // MARK: - act_on_screen

    private func actOnScreen(argumentsJSON: String) async -> String {
        guard let description = currentDescription, !description.isExpired else {
            return """
                The screen description has expired. Call describe_screen again before \
                choosing a control.
                """
        }

        guard let index = integerArgument("index", in: argumentsJSON) else {
            return "Missing or unreadable index. Pass the number from describe_screen."
        }
        guard let entry = description.entry(forIndex: index) else {
            let available = description.entries.map { String($0.index) }.joined(separator: ", ")
            return """
                Control \(index) is not in the current list (available: \(available)). \
                Call describe_screen again.
                """
        }

        // Consumed the moment it is used: whatever happens next, the numbering on
        // screen is about to change, and acting twice on one description is a bug.
        currentDescription = nil

        let labelForTask = entry.label.isEmpty ? "unlabelled control" : entry.label
        let appName = description.activeAppName

        // One step per spoken request. The text-command path is allowed a long
        // bounded loop because the user is watching a panel; over voice, each
        // extra step is another turn of the user waiting without knowing why.
        let loop = JevPointerLoop(engine: engine) { snapshot in
            // Progress is reported through the session's own channel; the loop
            // itself must not know a voice conversation exists.
            print("[StepFunRealtimeTools] jev step \(snapshot.step): \(snapshot.note)")
        }
        let outcome = await loop.run(task: labelForTask, app: appName, maxSteps: 1)

        let prefix = outcome.ok ? "Done." : "Could not do it."
        return "\(prefix) \(outcome.message)"
    }

    // MARK: - Argument parsing

    private func stringArgument(_ key: String, in json: String) -> String? {
        guard let object = jsonObject(from: json),
              let value = object[key] as? String else { return nil }
        return value
    }

    private func integerArgument(_ key: String, in json: String) -> Int? {
        guard let object = jsonObject(from: json) else { return nil }
        if let value = object[key] as? Int { return value }
        // Models routinely emit a JSON number for an integer parameter.
        if let value = object[key] as? Double { return Int(value) }
        if let value = object[key] as? String { return Int(value) }
        return nil
    }

    private func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
