//  JevGrounding.swift
//  Turning a screen into one question, and an answer back into an action.
//
//  Deliberately free of TipTour types so it can be reasoned about and tested on
//  its own: callers map their detections into `JevCandidate` and map the result
//  back. Everything here is pure.

import CoreGraphics
import Foundation

// MARK: - Candidates

/// One thing on screen the loop is allowed to act on. Built from a detection —
/// never invented — so a decision can only ever name something real.
nonisolated struct JevCandidate: Equatable {
    let id: String
    let label: String
    let source: String          // "ocr" | "yolo" | "ax"
    let confidence: Double
    let centre: CGPoint         // global AppKit points, for the description only

    /// How Jev reads this candidate. It cannot see pixels, so this string is
    /// the entire basis of the decision — label first, because the option key
    /// and value are both read semantically.
    var describedForJev: String {
        let location = centre == .zero ? "" : " at (\(Int(centre.x)),\(Int(centre.y)))"
        return "\(label.isEmpty ? "unlabeled element" : label) [\(source)]\(location)"
    }
}

// MARK: - The decision

/// What one Jev call decided about one screen.
nonisolated struct JevDecision {
    /// Probability the task is already finished.
    let done: Double
    /// Probability that nothing on screen can advance the task.
    let absent: Double
    /// Candidates, most likely first. The `__none__` escape hatch is removed.
    let ranked: [(candidate: JevCandidate, probability: Double)]
    /// How to act on the winner: "click" | "double_click" | "right_click".
    let actionKind: String
    /// Raw winner probability for the action head. Keep this separate from
    /// TypeSafe's chance-corrected `confidence`, which moves as options change.
    let actionProbability: Double
    /// Winner-vs-runner-up separation for the selected action.
    let actionMargin: Double
    /// Probability from the target head that corresponds to `actionKind`.
    let targetProbability: Double
    /// Winner-vs-runner-up separation for that matching target head.
    let targetMargin: Double
    /// True when Jev's own top pick was the "none of these" option.
    let choseNone: Bool
    let metrics: JevCallMetrics

    var stopReason: String? {
        if choseNone { return "target_absent" }
        guard best != nil else { return "no_candidates" }
        return nil
    }

    var best: (candidate: JevCandidate, probability: Double)? { ranked.first }
}

// MARK: - Building the ask

nonisolated enum JevGrounding {
    /// The explicit escape hatch. Measured: without it, when the target is
    /// genuinely absent Jev still picks a wrong element at ~0.71 — high enough
    /// to look right and click. With it, true negatives score ~0.96 and true
    /// positives are unaffected.
    static let noneKey = "__none__"

    /// Leave headroom under the hard 255 cap.
    static let maxCandidates = 200

    static let doneThreshold = 0.70

    /// Identical descriptions must be collapsed before asking: on a true tie
    /// Jev does not report 50/50, it breaks toward the first key and still
    /// reports high confidence, which would read as discrimination it did not do.
    static func deduplicated(_ candidates: [JevCandidate]) -> [JevCandidate] {
        var seen = Set<String>()
        var seenIDs = Set<String>()
        var kept: [JevCandidate] = []
        for candidate in candidates {
            let description = candidate.describedForJev
            if !candidate.id.isEmpty, candidate.id != noneKey, seenIDs.insert(candidate.id).inserted,
               seen.insert(description).inserted { kept.append(candidate) }
        }
        return kept
    }

    /// The whole ask for one loop step. Action and action-conditioned target
    /// heads are asked speculatively in one call. Code consumes only the target
    /// head matching the selected action; unused heads can never cause effects.
    static func request(
        task: String,
        candidates: [JevCandidate],
        history: [String],
        excluding: Set<String>,
        forcedActionKind: String? = nil
    ) -> (state: [String: Any], questions: [String: JevQuestion], pool: [JevCandidate])? {
        let pool = Array(
            deduplicated(candidates).filter { !excluding.contains($0.id) }.prefix(maxCandidates)
        )
        guard !pool.isEmpty else { return nil }

        var criteria = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0.describedForJev) })
        criteria[noneKey] = "None of these would advance the task — the control needed is not on screen"

        // `state` and `criteria` must describe the same world: when an element
        // appeared in one but not the other, answers became unstable between
        // otherwise identical runs.
        let state: [String: Any] = [
            "task": task,
            "step": history.count + 1,
            "already_done": history.isEmpty ? ["nothing yet"] : history,
            "screen_elements": pool.map { ["id": $0.id, "describes": $0.describedForJev] }
        ]

        let targetQuestion: (String) -> JevQuestion = { description in
            .choice(
                instructions: "If the next operation were \(description), which single element should receive it to make progress on the task: \"\(task)\"? Consider what has already been done. Choose none when that operation has no valid target on this screen.",
                criteria: criteria
            )
        }

        let baseQuestions: [String: JevQuestion] = [
            "done": .noul(
                instructions: "Judging only by what is on screen now and the actions already taken, has this task been completed: \"\(task)\"?"
            ),
            "absent": .noul(
                instructions: "Is the control needed to make the next bit of progress on the task missing from the elements on screen?"
            )
        ]
        var questions = baseQuestions
        if let forcedActionKind {
            guard ["click", "double_click", "right_click"].contains(forcedActionKind) else { return nil }
            let descriptions = [
                "click": "a normal single left click",
                "double_click": "a double click",
                "right_click": "a right click"
            ]
            questions["target_\(forcedActionKind)"] = targetQuestion(descriptions[forcedActionKind]!)
        } else {
            questions["action"] = .choice(
                instructions: "Which pointer operation should be used for the next step of the task: \"\(task)\"?",
                criteria: [
                    "click": "A normal single left click — the default for buttons, menus, links, list rows",
                    "double_click": "Double click — opening a file or folder from a list",
                    "right_click": "Right click to open a context menu"
                ]
            )
            questions["target_click"] = targetQuestion("a normal single left click")
            questions["target_double_click"] = targetQuestion("a double click")
            questions["target_right_click"] = targetQuestion("a right click")
        }
        return (state, questions, pool)
    }

    /// Read one Jev response back into a decision.
    static func decision(
        from answers: [String: JevAnswer],
        pool: [JevCandidate],
        metrics: JevCallMetrics,
        forcedActionKind: String? = nil
    ) throws -> JevDecision {
        let supportedActions = ["click", "double_click", "right_click"]
        let actionKind: String
        let actionProbability: Double
        let actionMargin: Double
        if let forcedActionKind {
            guard supportedActions.contains(forcedActionKind) else {
                throw JevError.malformed("unsupported forced action")
            }
            actionKind = forcedActionKind
            actionProbability = 1
            actionMargin = 1
        } else {
            guard let action = answers["action"], let selectedAction = action.choice,
                  supportedActions.contains(selectedAction),
                  let actionProbabilities = action.probabilities, !actionProbabilities.isEmpty,
                  actionProbabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  let selectedProbability = actionProbabilities[selectedAction],
                  selectedProbability == actionProbabilities.values.max(),
                  actionProbabilities.keys.allSatisfy({ supportedActions.contains($0) }) else {
                throw JevError.malformed("invalid action decision")
            }
            actionKind = selectedAction
            actionProbability = selectedProbability
            actionMargin = action.margin
        }

        guard let pick = answers["target_\(actionKind)"], let choice = pick.choice,
              choice == noneKey || pool.contains(where: { $0.id == choice }),
              let done = answers["done"]?.noul, (0...1).contains(done),
              let absent = answers["absent"]?.noul, (0...1).contains(absent),
              let probabilities = pick.probabilities, !probabilities.isEmpty,
              probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let chosenProbability = probabilities[choice],
              chosenProbability == probabilities.values.max(),
              probabilities.keys.allSatisfy({ key in key == noneKey || pool.contains(where: { $0.id == key }) }) else {
            throw JevError.malformed("incomplete or invalid decision")
        }
        let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        let ranked: [(candidate: JevCandidate, probability: Double)] = pick.ranked
            .sorted { lhs, rhs in
                if lhs.probability != rhs.probability { return lhs.probability > rhs.probability }
                if lhs.key == choice { return true }
                if rhs.key == choice { return false }
                return lhs.key < rhs.key
            }
            .compactMap { entry in
                guard let candidate = byID[entry.key] else { return nil }   // drops __none__
                return (candidate: candidate, probability: entry.probability)
            }
        return JevDecision(
            done: done,
            absent: absent,
            ranked: ranked,
            actionKind: actionKind,
            actionProbability: actionProbability,
            actionMargin: actionMargin,
            targetProbability: chosenProbability,
            targetMargin: pick.margin,
            choseNone: choice == noneKey,
            metrics: metrics
        )
    }
}

