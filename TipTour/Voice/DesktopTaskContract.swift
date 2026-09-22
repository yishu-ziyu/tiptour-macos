import Foundation

enum DesktopActionKind: String, Codable {
    case click, doubleClick = "double_click", rightClick = "right_click"
    case type, pressKey = "press_key", shortcut, scroll, openApp = "open_app"

    var needsTarget: Bool {
        switch self {
        case .click, .doubleClick, .rightClick, .type: return true
        case .pressKey, .shortcut, .scroll, .openApp: return false
        }
    }
}

enum DesktopTaskIntent: String, Codable {
    case new, resume, correct
}

/// How the user resolved an operation whose effect was never independently
/// verified. A task with an unconfirmed side effect stays stopped until one of
/// these is explicit: a plain resume or correction is not authorization to try
/// something else.
enum DesktopTaskUncertainResolution: String, Codable {
    case confirmedSucceeded = "confirmed_succeeded"
    case confirmedFailed = "confirmed_failed"
    case retrySame = "retry_same"
    case replaceTarget = "replace_target"
}

/// Parameters belong to the task, never to the candidate-selection model.
struct DesktopActionStep: Codable, Equatable {
    var action: DesktopActionKind = .click
    var targetLabel: String? = nil
    var region: DesktopTargetRegion? = nil
    var anchorLabel: String? = nil
    var relation: DesktopTargetRelation? = nil
    var text: String? = nil
    var key: String? = nil
    var application: String? = nil
    var direction: String? = nil
    var amount: Int? = nil
    var expectedLabel: String? = nil
    var allowsActionDecision: Bool = false

    enum CodingKeys: String, CodingKey, CaseIterable {
        case action, region, relation, text, key, application, direction, amount
        case targetLabel = "target_label", anchorLabel = "anchor_label", expectedLabel = "expected_label"
    }

    func validate() throws {
        guard (text == nil || action == .type),
              (key == nil || action == .pressKey || action == .shortcut),
              (application == nil || action == .openApp),
              ((direction == nil && amount == nil) || action == .scroll),
              (action.needsTarget || (targetLabel == nil && region == nil && anchorLabel == nil && relation == nil)) else {
            throw DesktopTaskContractError.invalid("动作与参数不匹配，未执行。")
        }
        if (anchorLabel == nil) != (relation == nil) {
            throw DesktopTaskContractError.invalid("相对位置必须同时包含锚点和方向。")
        }
        if let targetLabel, Self.normalized(targetLabel).isEmpty {
            throw DesktopTaskContractError.invalid("目标名称不能为空。")
        }
        switch action {
        case .openApp:
            guard let application, !Self.normalized(application).isEmpty else {
                throw DesktopTaskContractError.invalid("缺少应用名称，未执行。")
            }
        case .type:
            guard let text, !text.isEmpty, text.count <= 20_000, targetLabel != nil else {
                throw DesktopTaskContractError.invalid("输入需要明确字段和完整文字，未执行。")
            }
        case .pressKey, .shortcut:
            guard let key, !Self.normalized(key).isEmpty, key.count <= 80 else {
                throw DesktopTaskContractError.invalid("缺少明确键值，未执行。")
            }
        case .scroll:
            guard ["up", "down", "left", "right"].contains(direction ?? ""),
                  (1...5).contains(amount ?? 1) else {
                throw DesktopTaskContractError.invalid("滚动方向或次数无效，未执行。")
            }
        case .click, .doubleClick, .rightClick: break
        }
    }

    /// Keep literal names as constraints. A missing name never becomes a
    /// request to rank every unrelated item on the screen.
    func candidates(in observation: DesktopTaskObservation) -> [DesktopTaskTarget] {
        var candidates = observation.targets
        if let targetLabel {
            candidates = candidates.filter { Self.normalized($0.label) == Self.normalized(targetLabel) }
        }
        if let region { candidates = candidates.filter { region.contains($0) } }
        if let anchorLabel, let relation {
            let anchors = observation.targets.filter { Self.normalized($0.label) == Self.normalized(anchorLabel) }
            guard anchors.count == 1 else { return [] }
            candidates = candidates.filter { relation.contains($0, relativeTo: anchors[0]) }
        }
        return candidates
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .filter { !$0.isWhitespace }
    }
}

enum DesktopTargetRegion: String, Codable {
    case left, right, top, bottom

    func contains(_ target: DesktopTaskTarget) -> Bool {
        guard target.box.count == 4, target.display.count == 4 else { return false }
        let centerX = (target.box[0] + target.box[2]) / 2
        let centerY = (target.box[1] + target.box[3]) / 2
        let displayCenterX = (target.display[0] + target.display[2]) / 2
        let displayCenterY = (target.display[1] + target.display[3]) / 2
        switch self {
        case .left: return centerX < displayCenterX
        case .right: return centerX >= displayCenterX
        case .top: return centerY >= displayCenterY
        case .bottom: return centerY < displayCenterY
        }
    }
}

enum DesktopTargetRelation: String, Codable {
    case above, below, leftOf = "left_of", rightOf = "right_of"

    func contains(_ target: DesktopTaskTarget, relativeTo anchor: DesktopTaskTarget) -> Bool {
        guard target.box.count == 4, anchor.box.count == 4, target.display == anchor.display,
              target.id != anchor.id else { return false }
        switch self {
        case .above: return target.box[1] >= anchor.box[3]
        case .below: return target.box[3] <= anchor.box[1]
        case .leftOf: return target.box[2] <= anchor.box[0]
        case .rightOf: return target.box[0] >= anchor.box[2]
        }
    }
}

enum DesktopTaskContractError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

// MARK: - Two-layer action facts: "what Her did" vs "what the action caused".
//
// `DesktopActionDelivery` records whether the input reached the target.
// `DesktopActionOutcomeEvidence` records whether an independent read-back
// proved the requested effect. They never substitute for each other:
// a sent click is a delivered click, not a verified state change.

enum DesktopActionDelivery: String, Codable {
    case notSent = "not_sent", unknown, sent
}

/// Code-owned rule for when a step counts as done. The model cannot choose it.
/// Direct input actions without an explicit expected label only need proof of
/// delivery; everything that claims a resulting state needs outcome evidence.
enum DesktopStepCompletionPolicy: String, Codable {
    case deliverySufficient = "delivery_sufficient"
    case outcomeRequired = "outcome_required"

    init(step: DesktopActionStep) {
        switch step.action {
        case .openApp, .type:
            self = .outcomeRequired
        case .click, .doubleClick, .rightClick, .pressKey, .shortcut, .scroll:
            self = step.expectedLabel == nil ? .deliverySufficient : .outcomeRequired
        }
    }
}

/// Independent evidence about the effect, kept distinct from delivery.
enum DesktopActionOutcomeEvidence: String, Codable {
    case notObserved = "not_observed"
    case systemVerified = "system_verified"
    case userConfirmed = "user_confirmed"
}

/// Why a step counts as satisfied, for receipts, speech and telemetry.
enum DesktopActionCompletionBasis: String, Codable {
    case deliveryConfirmed = "delivery_confirmed"
    case systemVerifiedOutcome = "system_verified_outcome"
    case userConfirmedOutcome = "user_confirmed_outcome"
}

/// The single source of truth for step satisfaction. The coordinator, receipt
/// wording and telemetry must all read these predicates instead of re-deriving
/// their own completion rules.
enum DesktopActionCompletion {
    static func isStepSatisfied(policy: DesktopStepCompletionPolicy,
                                delivery: DesktopActionDelivery,
                                outcomeEvidence: DesktopActionOutcomeEvidence) -> Bool {
        if outcomeEvidence == .systemVerified || outcomeEvidence == .userConfirmed { return true }
        return policy == .deliverySufficient && delivery == .sent
    }

    /// `uncertain_effect` has exactly two causes: the delivery itself is
    /// unknown, or the policy demands outcome evidence that never arrived.
    static func isUncertainEffect(policy: DesktopStepCompletionPolicy,
                                  delivery: DesktopActionDelivery,
                                  outcomeEvidence: DesktopActionOutcomeEvidence) -> Bool {
        if delivery == .unknown { return true }
        return delivery == .sent && policy == .outcomeRequired && outcomeEvidence == .notObserved
    }

    static func completionBasis(policy: DesktopStepCompletionPolicy,
                                delivery: DesktopActionDelivery,
                                outcomeEvidence: DesktopActionOutcomeEvidence) -> DesktopActionCompletionBasis? {
        switch outcomeEvidence {
        case .systemVerified: return .systemVerifiedOutcome
        case .userConfirmed: return .userConfirmedOutcome
        case .notObserved:
            return policy == .deliverySufficient && delivery == .sent ? .deliveryConfirmed : nil
        }
    }
}

/// The executor's factual report for one attempt. `completed` is a read-only
/// compatibility view of `outcomeEvidence == .systemVerified`; task progress
/// must be decided through `DesktopActionCompletion` with the step's policy.
struct DesktopTaskActionResult {
    let delivery: DesktopActionDelivery
    let outcomeEvidence: DesktopActionOutcomeEvidence
    let detail: String
    var resultingApp: String? = nil
    var resultingScene: DesktopTaskSceneIdentity? = nil
    var failureStage: String? = nil
    var reasonCode: String? = nil

    /// Compatibility only: true solely after an independent system read-back.
    var completed: Bool { outcomeEvidence == .systemVerified }
}

struct DesktopActionRecord: Codable {
    let id: String
    let observationID: String
    let app: String
    let targetID: String?
    let label: String
    let action: DesktopActionKind
    let decisionPacket: DesktopDecisionPacket?
    var completionPolicy: DesktopStepCompletionPolicy
    var delivery: DesktopActionDelivery
    var outcomeEvidence: DesktopActionOutcomeEvidence
    var detail: String

    enum CodingKeys: String, CodingKey {
        case id, observationID, app, targetID, label, action, delivery, detail
        case decisionPacket = "decision_packet"
        case completionPolicy = "completion_policy"
        case outcomeEvidence = "outcome_evidence"
        case completionBasis = "completion_basis"
        case satisfied, verified
    }

    init(id: String, observationID: String, app: String, targetID: String?, label: String,
         action: DesktopActionKind, decisionPacket: DesktopDecisionPacket?,
         completionPolicy: DesktopStepCompletionPolicy, delivery: DesktopActionDelivery,
         outcomeEvidence: DesktopActionOutcomeEvidence, detail: String) {
        self.id = id
        self.observationID = observationID
        self.app = app
        self.targetID = targetID
        self.label = label
        self.action = action
        self.decisionPacket = decisionPacket
        self.completionPolicy = completionPolicy
        self.delivery = delivery
        self.outcomeEvidence = outcomeEvidence
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        observationID = try values.decode(String.self, forKey: .observationID)
        app = try values.decode(String.self, forKey: .app)
        targetID = try values.decodeIfPresent(String.self, forKey: .targetID)
        label = try values.decode(String.self, forKey: .label)
        action = try values.decode(DesktopActionKind.self, forKey: .action)
        decisionPacket = try values.decodeIfPresent(DesktopDecisionPacket.self, forKey: .decisionPacket)
        delivery = try values.decode(DesktopActionDelivery.self, forKey: .delivery)
        detail = try values.decode(String.self, forKey: .detail)
        if let policy = try values.decodeIfPresent(DesktopStepCompletionPolicy.self, forKey: .completionPolicy) {
            // New-format record: the two facts were stored separately.
            completionPolicy = policy
            outcomeEvidence = try values.decodeIfPresent(DesktopActionOutcomeEvidence.self, forKey: .outcomeEvidence)
                ?? (try values.decodeIfPresent(Bool.self, forKey: .verified) == true ? .systemVerified : .notObserved)
        } else {
            // Old-format record: only a flattened `verified` Bool existed.
            // Conservatively require outcome evidence — a legacy
            // `verified=false` record must never read as delivery-completed.
            completionPolicy = .outcomeRequired
            outcomeEvidence = try values.decodeIfPresent(Bool.self, forKey: .verified) == true
                ? .systemVerified : .notObserved
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(observationID, forKey: .observationID)
        try values.encode(app, forKey: .app)
        try values.encodeIfPresent(targetID, forKey: .targetID)
        try values.encode(label, forKey: .label)
        try values.encode(action, forKey: .action)
        try values.encodeIfPresent(decisionPacket, forKey: .decisionPacket)
        try values.encode(completionPolicy, forKey: .completionPolicy)
        try values.encode(delivery, forKey: .delivery)
        try values.encode(outcomeEvidence, forKey: .outcomeEvidence)
        // Derived reporting fields for tool JSON consumers; never input.
        try values.encodeIfPresent(completionBasis, forKey: .completionBasis)
        try values.encode(satisfied, forKey: .satisfied)
        try values.encode(detail, forKey: .detail)
        // Compatibility for old JSON consumers; derived, never authoritative.
        try values.encode(verified, forKey: .verified)
    }

    /// Compatibility view for older call sites and JSON consumers. Only an
    /// independent system read-back counts; a user confirmation does not.
    var verified: Bool { outcomeEvidence == .systemVerified }

    var satisfied: Bool {
        DesktopActionCompletion.isStepSatisfied(policy: completionPolicy, delivery: delivery,
                                                outcomeEvidence: outcomeEvidence)
    }

    var uncertainEffect: Bool {
        DesktopActionCompletion.isUncertainEffect(policy: completionPolicy, delivery: delivery,
                                                  outcomeEvidence: outcomeEvidence)
    }

    var completionBasis: DesktopActionCompletionBasis? {
        DesktopActionCompletion.completionBasis(policy: completionPolicy, delivery: delivery,
                                                outcomeEvidence: outcomeEvidence)
    }

    /// The three satisfiable wordings stay distinct: a delivered action is
    /// never reported as a verified state change.
    var summary: String {
        let state: String
        switch completionBasis {
        case .systemVerifiedOutcome: state = "结果已验证"
        case .userConfirmedOutcome: state = "用户已确认结果"
        case .deliveryConfirmed: state = "动作已送达"
        case nil: state = delivery == .notSent ? "未下发" : "结果未确认"
        }
        return "\(action.rawValue)「\(label)」：\(state)"
    }
}

struct DesktopTaskReceipt: Codable {
    let goal: String
    var status: String
    /// Compatibility field: ONLY actions attempted in this invocation.
    let actions: [String]
    var detail: String
    var app: String? = nil
    var taskID: String = UUID().uuidString
    var turnID: String = UUID().uuidString
    var targetVersion: Int = 1
    var priorActions: [String] = []
    var currentActions: [DesktopActionRecord] = []
    /// Effects independently verified by the system, carried across the whole
    /// task chain. User-confirmed and delivery-only actions never enter here.
    var verifiedActionHistory: [String] = []
    /// Every step that counts as done — delivery-confirmed direct inputs,
    /// system-verified outcomes and user-confirmed outcomes. The decision
    /// model reads this as "already done", never the verified-only list.
    var satisfiedActionHistory: [String] = []
    var completedStepCount: Int = 0
    var totalStepCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case goal, status, actions, detail, app
        case taskID = "task_id", turnID = "turn_id", targetVersion = "target_version"
        case priorActions = "prior_actions", currentActions = "current_actions"
        case verifiedActionHistory = "verified_action_history"
        case satisfiedActionHistory = "satisfied_action_history"
        case completedStepCount = "completed_step_count", totalStepCount = "total_step_count"
    }

    var toolOutput: String {
        guard let data = try? JSONEncoder().encode(self) else { return "任务结果编码失败，不能声称完成。" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Action speech is not another model inference. An old action or a
    /// provider's confident prose cannot turn into a new completion claim.
    var spokenSummary: String {
        if status == "running" || status == "pausing" {
            return "任务尚未完成，已确认 \(completedStepCount)/\(totalStepCount) 步。"
        }
        if status == "cancelling" { return "已停止后续操作，正在核查已经发出的部分。" }
        if status == "cancelled" { return "任务已取消，已经发生的操作记录保留。" }
        let sent = currentActions.filter { $0.delivery != .notSent }
        guard let last = sent.last else {
            return "这次没有执行操作。\(detail)"
        }
        if status == "completed" {
            if currentActions.count > 1, currentActions.allSatisfy({ $0.outcomeEvidence == .systemVerified }) {
                return "已完成并确认这 \(currentActions.count) 步操作。"
            }
            switch last.completionBasis {
            case .systemVerifiedOutcome:
                switch last.action {
                case .openApp: return "已确认「\(last.label)」已启动。"
                case .type: return "文字已输入，并已读回确认。"
                default: return "已确认「\(last.label)」的操作结果。"
                }
            case .userConfirmedOutcome:
                return "你已确认上一轮操作已经生效。"
            case .deliveryConfirmed:
                return last.deliveryConfirmedSpeech
            case nil:
                break
            }
        }
        if last.delivery == .unknown { return "本轮尝试了操作，但结果还不确定，已停下，没有继续尝试其他目标。" }
        if last.outcomeEvidence == .systemVerified {
            return "本轮已确认 \(currentActions.filter(\.verified).count) 步；后续条件未满足，已停下。"
        }
        if last.action == .openApp {
            return "我发出了打开「\(last.label)」的请求，但没有确认到它的可见前台窗口，所以不能说已经打开。"
        }
        return "已向「\(last.label)」发送操作，但目标结果还没有确认，已停下。"
    }
}

extension DesktopActionRecord {
    /// Factual wording for a completed step whose only proof is delivery.
    /// It names the input action and never claims a business outcome.
    var deliveryConfirmedSpeech: String {
        switch action {
        case .click: return "已点击「\(label)」。"
        case .doubleClick: return "已双击「\(label)」。"
        case .rightClick: return "已右键点击「\(label)」。"
        case .pressKey: return "已按下 \(label)。"
        case .shortcut: return "已执行快捷键 \(label)。"
        case .scroll: return "已\(Self.scrollDirectionName(label))滚动。"
        case .openApp: return "已打开「\(label)」。"
        case .type: return "已输入文字。"
        }
    }

    private static func scrollDirectionName(_ direction: String) -> String {
        switch direction {
        case "up": return "向上"
        case "left": return "向左"
        case "right": return "向右"
        default: return "向下"
        }
    }
}

struct DesktopTaskSubmission {
    let goal: String
    var exactTarget: DesktopTaskTarget? = nil
    var steps: [DesktopActionStep]? = nil
    var intent: DesktopTaskIntent = .new
    var uncertainResolution: DesktopTaskUncertainResolution? = nil
    let turnID: String
    /// Product-owned constraint for automatic speech-only continuation; never
    /// decoded from a model tool request or used as fresh authorization.
    var expectedResumeScene: DesktopTaskSceneIdentity? = nil
}

extension DesktopTaskReceipt {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let verifiedHistory = try values.decodeIfPresent([String].self, forKey: .verifiedActionHistory) ?? []
        self.init(goal: try values.decode(String.self, forKey: .goal),
            status: try values.decode(String.self, forKey: .status),
            actions: try values.decode([String].self, forKey: .actions),
            detail: try values.decode(String.self, forKey: .detail),
            app: try values.decodeIfPresent(String.self, forKey: .app),
            taskID: try values.decodeIfPresent(String.self, forKey: .taskID) ?? UUID().uuidString,
            turnID: try values.decodeIfPresent(String.self, forKey: .turnID) ?? UUID().uuidString,
            targetVersion: try values.decodeIfPresent(Int.self, forKey: .targetVersion) ?? 1,
            priorActions: try values.decodeIfPresent([String].self, forKey: .priorActions) ?? [],
            currentActions: try values.decodeIfPresent([DesktopActionRecord].self, forKey: .currentActions) ?? [],
            verifiedActionHistory: verifiedHistory,
            satisfiedActionHistory: try values.decodeIfPresent([String].self, forKey: .satisfiedActionHistory) ?? verifiedHistory,
            completedStepCount: try values.decodeIfPresent(Int.self, forKey: .completedStepCount) ?? 0,
            totalStepCount: try values.decodeIfPresent(Int.self, forKey: .totalStepCount) ?? 0)
    }
}
