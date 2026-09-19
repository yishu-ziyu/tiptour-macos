//
//  StepFunRealtimeTools.swift
//  TipTour
//
//  The two tools the realtime voice model is allowed to call, and the handler
//  that turns those calls into desktop actions.
//
//  The shape of these tools is dictated by measurement, not convenience.
//  Vision models do not report usable pixel coordinates — markers placed at
//  known positions in a real screenshot came back up to 2082 px off, with no
//  stable scale factor (see docs/model-research-findings.md §5). So the model is
//  never shown a coordinate and never asked for one. It sees a numbered list of
//  what local perception found and names a number; the label behind that number
//  is then handed to the existing Jev loop, which re-perceives, re-matches, and
//  decides the action kind itself.
//
//  That division is what keeps the voice path inside the engine's boundaries:
//  the model contributes intent, local perception contributes geometry, and JEV
//  contributes the decision.
//

import Foundation

/// The tool declarations sent in `session.update`.
///
/// Deliberately two tools. A voice model that can also invent coordinates or
/// free-form action kinds is a voice model that can click the wrong thing
/// confidently, and the failure is invisible until it happens.
enum StepFunRealtimeToolDeclarations {

    static let all: [[String: Any]] = [describeScreen, actOnScreen]

    /// Asks what is on screen. Returns a numbered list the model chooses from;
    /// the intent is used to prune a full-screen detection down to something a
    /// decision model can rank well and a person can hear read out.
    static let describeScreen: [String: Any] = [
        "type": "function",
        "function": [
            "name": "describe_screen",
            "description": """
                List the interactive controls currently visible on screen, numbered from 1. \
                Call this before act_on_screen whenever the screen may have changed. \
                The intent you pass is used to put the most relevant controls first.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "intent": [
                        "type": "string",
                        "description": "What the user wants to do, in a few words, e.g. 打开新标签页.",
                    ],
                ],
                "required": ["intent"],
            ],
        ],
    ]

    /// Acts on a numbered control from the most recent `describe_screen` result.
    ///
    /// `action` is a hint only. The click kind is decided by JEV's own validated
    /// decision, exactly as in the text-command path, so a misheard "double
    /// click" cannot turn into a double click on something destructive.
    static let actOnScreen: [String: Any] = [
        "type": "function",
        "function": [
            "name": "act_on_screen",
            "description": """
                Click one of the controls returned by the most recent describe_screen call. \
                The screen is re-read before clicking, so a control that moved is still \
                found. If the number is not in the last list, the call fails and you must \
                call describe_screen again.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "index": [
                        "type": "integer",
                        "description": "The number shown by describe_screen, starting at 1.",
                    ],
                    "action": [
                        "type": "string",
                        "description": "What the user asked for, e.g. click, 双击, 右键. Advisory only.",
                        "enum": ["click", "double_click", "right_click"],
                    ],
                ],
                "required": ["index"],
            ],
        ],
    ]
}

/// One row of the numbered list handed to the voice model.
///
/// Carries only what the model may see. Coordinates live in the resolved target
/// and are never put in this structure, so there is no path by which a
/// hallucinated number becomes a hallucinated point.
struct StepFunScreenControlEntry: Equatable {
    let index: Int
    let label: String
    let kind: String
}

/// The result of `describe_screen`, held so `act_on_screen` can translate a
/// number back into something the decision loop can act on.
///
/// Scoped to one description on purpose: a number is only meaningful against
/// the list it came from. A stale number is refused rather than resolved
/// against whatever happens to be on screen now, because "control 3" after the
/// screen changed is a guess, and a guess that clicks is the worst outcome
/// available.
/// No actor annotation on purpose: this is plain data, and the decision
/// function below has to be callable from wherever a tool call arrives. In the app
/// target the project-wide default isolation makes both MainActor-isolated anyway;
/// in the isolated test package both are nonisolated. Either way they stay
/// consistent with each other, which is what matters.
final class StepFunScreenDescription {
    private(set) var entries: [StepFunScreenControlEntry]
    private(set) var activeAppName: String?
    private let capturedAt: Date

    /// A description is only trusted for a short while. Long enough for the
    /// model to name a control in the same breath, short enough that a
    /// conversation pause cannot act on a screen the user has since left.
    static let validitySeconds: TimeInterval = 20

    init(
        entries: [StepFunScreenControlEntry],
        activeAppName: String?,
        capturedAt: Date = Date()
    ) {
        self.entries = entries
        self.activeAppName = activeAppName
        self.capturedAt = capturedAt
    }

    var isExpired: Bool {
        Date().timeIntervalSince(capturedAt) > Self.validitySeconds
    }

    func entry(forIndex index: Int) -> StepFunScreenControlEntry? {
        entries.first { $0.index == index }
    }

    /// The text the model reads. Labels are spoken back to the user too, which
    /// is what makes a wrong pick correctable in one sentence.
    func renderedForVoiceModel() -> String {
        guard !entries.isEmpty else {
            return "No interactive controls were found on screen."
        }
        let lines = entries.map { entry in
            "\(entry.index). \(entry.label.isEmpty ? "unlabelled control" : entry.label) [\(entry.kind)]"
        }
        let header = activeAppName.map { "Active app: \($0)" } ?? "Active app: unknown"
        return ([header] + lines).joined(separator: "\n")
    }
}

/// Why an `act_on_screen` call was refused, or that it may proceed.
///
/// Pure data in, decision out — no engine, no network, no clock beyond the one the
/// caller passes. That is what makes the refusal behaviour verifiable in a test
/// instead of being argued about in review: every way a voice model can ask for
/// the wrong click ends up as one of these cases.
enum StepFunActionResolution: Equatable {
    /// The number names exactly one control in a live description.
    case proceed(StepFunScreenControlEntry)
    /// No usable description at all — expired, or none was ever taken.
    case staleDescription
    /// The number is not in the current list.
    case unknownIndex(availableIndices: [Int])
    /// The named control exists more than once, so "that one" is not a target.
    case ambiguousLabel(label: String, occurrences: Int)
}

/// Decides whether a numbered request may become a click.
///
/// Separated from the router so the rules can be exercised without a live desktop.
func resolveStepFunAction(
    description: StepFunScreenDescription?,
    requestedIndex: Int
) -> StepFunActionResolution {
    guard let description, !description.isExpired else { return .staleDescription }
    guard let entry = description.entry(forIndex: requestedIndex) else {
        return .unknownIndex(availableIndices: description.entries.map(\.index))
    }
    let occurrences = description.entries.filter { $0.label == entry.label }.count
    if occurrences > 1 {
        return .ambiguousLabel(label: entry.label, occurrences: occurrences)
    }
    return .proceed(entry)
}
