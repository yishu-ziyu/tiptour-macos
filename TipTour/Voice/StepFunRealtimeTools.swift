//
//  StepFunRealtimeTools.swift
//  TipTour
//
//  The two tools the realtime voice model is allowed to call, and the handler
//  that turns those calls into desktop actions.
//
//  Task parameters and observation identities are explicit. This route uses
//  locally grounded targets; it makes no general claim about visual models'
//  ability to produce coordinates. See the corrected model research findings.
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

    private static let stepProperties: [String: Any] = [
        "action": ["type": "string", "enum": ["click", "double_click", "right_click", "open_app", "type", "press_key", "shortcut", "scroll"],
                   "description": "Use the user's explicit operation when known. For a single mouse-target request where click vs double/right click is genuinely unspecified, omit this field and let the local JEV decision layer choose. Other actions such as open_app/type/scroll must be explicit."],
        "target_label": ["type": "string", "description": "Exact visible name from the user or current observation. Preserve corrections; never replace an absent name with another control."],
        "region": ["type": "string", "enum": ["left", "right", "top", "bottom"]],
        "anchor_label": ["type": "string", "description": "Exact visible anchor name for a relative location."],
        "relation": ["type": "string", "enum": ["above", "below", "left_of", "right_of"]],
        "text": ["type": "string", "description": "Complete text to insert. type requires a named, already-focused field; use a preceding click step when needed."],
        "key": ["type": "string", "description": "Explicit key or key combination requested by the user."],
        "application": ["type": "string", "description": "Exact application name for open_app; no visible icon is required."],
        "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
        "amount": ["type": "integer", "minimum": 1, "maximum": 5],
        "expected_label": ["type": "string", "description": "Visible result expected AFTER this step, not a declaration of success."]
    ]

    static let all: [[String: Any]] = [describeScreen, actOnScreen]

    /// Asks what is on screen. Returns a numbered list the model chooses from;
    /// the intent is used to prune a full-screen detection down to something a
    /// decision model can rank well and a person can hear read out.
    static let describeScreen: [String: Any] = [
        "type": "function",
        "function": [
            "name": "describe_screen",
            "description": """
                Answer a question about the meaning of visible text, images or charts. \
                This tool is read-only. Do not use it to locate a button for an action: \
                act_on_screen observes and locates controls itself before executing.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "intent": [
                        "type": "string",
                        "description": "The user's content question, such as 这页在说什么. Not an action request.",
                    ],
                ],
                "required": ["intent"],
            ],
        ],
    ]

    /// A complete user task can start without a prior screen-description call.
    static let actOnScreen: [String: Any] = [
        "type": "function",
        "function": [
            "name": "act_on_screen",
            "description": "Execute an authorized desktop task. By default this attempts ONE action. For a short workflow provide an explicit steps list, at most six, with all known parameters. Each step must pass result checks before the next can run. Call directly for action requests.",
            "parameters": [
                "type": "object",
                "properties": stepProperties.merging([
                    "goal": ["type": "string", "description": "Complete user task, preserving names, location, and corrections already given."],
                    "intent": ["type": "string", "enum": ["new", "resume", "correct"], "description": "correct replaces the old target; resume continues exactly the same goal. Old actions are history, not new work."],
                    "resume_previous": ["type": "boolean", "description": "Legacy continuation flag. Prefer intent. A changed goal is a correction, never completed progress."],
                    "index": ["type": "integer", "description": "Optional control number from the most recent describe_screen result."],
                    "observation_id": ["type": "string", "description": "Required when using index. Copy the exact Observation ID from the same description."],
                    "steps": ["type": "array", "minItems": 1, "maxItems": 6, "description": "Explicit ordered actions. Do not combine with top-level action parameters or index.",
                              "items": ["type": "object", "properties": stepProperties, "required": ["action"], "additionalProperties": false]]
                ], uniquingKeysWith: { _, value in value }),
                "additionalProperties": false,
                "required": ["goal"]
            ]
        ]
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
    let observationID: String

    /// A description is only trusted for a short while. Long enough for the
    /// model to name a control in the same breath, short enough that a
    /// conversation pause cannot act on a screen the user has since left.
    static let validitySeconds: TimeInterval = 20

    init(
        entries: [StepFunScreenControlEntry],
        activeAppName: String?,
        capturedAt: Date = Date(),
        observationID: String = UUID().uuidString
    ) {
        self.entries = entries
        self.activeAppName = activeAppName
        self.capturedAt = capturedAt
        self.observationID = observationID
    }

    var isExpired: Bool {
        Date().timeIntervalSince(capturedAt) > Self.validitySeconds
    }

    func entry(index: Int, observationID: String?) -> StepFunScreenControlEntry? {
        guard !isExpired, observationID == self.observationID else { return nil }
        return entries.first { $0.index == index }
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
        return ([header, "Observation: \(observationID)"] + lines).joined(separator: "\n")
    }
}

/// Decode before resolving a target; JSON booleans and fractional numbers must
/// never be coerced into a valid control index.
struct StepFunActionArguments: Decodable {
    let goal: String?
    let targetLabel: String?
    let index: Int?
    let action: String?
    let resumePrevious: Bool?
    let intent: DesktopTaskIntent?
    let observationID: String?
    let steps: [DesktopActionStep]?
    let region: DesktopTargetRegion?
    let anchorLabel: String?
    let relation: DesktopTargetRelation?
    let text: String?
    let key: String?
    let application: String?
    let direction: String?
    let amount: Int?
    let expectedLabel: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case goal, index, action, intent, steps, region, relation, text, key, application, direction, amount
        case targetLabel = "target_label"
        case resumePrevious = "resume_previous"
        case observationID = "observation_id", anchorLabel = "anchor_label", expectedLabel = "expected_label"
    }

    static func decode(_ data: Data) throws -> StepFunActionArguments {
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw DesktopTaskContractError.invalid("工具参数包含未知字段或过长，未执行。")
        }
        if let rawSteps = object["steps"] {
            guard let steps = rawSteps as? [[String: Any]], steps.allSatisfy({
                Set($0.keys).isSubset(of: Set(DesktopActionStep.CodingKeys.allCases.map(\.rawValue)))
            }) else { throw DesktopTaskContractError.invalid("步骤包含未知字段，未执行。") }
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func validatedSteps() throws -> [DesktopActionStep] {
        guard (index == nil) == (observationID == nil) else {
            throw DesktopTaskContractError.invalid("编号必须绑定同一观察 ID，未执行。")
        }
        if let steps {
            guard !steps.isEmpty, steps.count <= 6, index == nil, action == nil, targetLabel == nil,
                  region == nil, anchorLabel == nil, relation == nil, text == nil, key == nil,
                  application == nil, direction == nil, amount == nil, expectedLabel == nil, observationID == nil else {
                throw DesktopTaskContractError.invalid("多步列表不能与单步参数混用，未执行。")
            }
            for step in steps { try step.validate() }
            return steps
        }
        guard let kind = DesktopActionKind(rawValue: action ?? "click") else {
            throw DesktopTaskContractError.invalid("动作类型无效，未执行。")
        }
        var step = DesktopActionStep(action: kind, targetLabel: targetLabel, region: region,
            anchorLabel: anchorLabel, relation: relation, text: text, key: key,
            application: application, direction: direction, amount: amount, expectedLabel: expectedLabel)
        step.allowsActionDecision = action == nil && kind == .click
        try step.validate()
        return [step]
    }
}
