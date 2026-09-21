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

enum DesktopActionDelivery: String, Codable {
    case notSent = "not_sent", unknown, sent
}

struct DesktopActionRecord: Codable {
    let id: String
    let observationID: String
    let app: String
    let targetID: String?
    let label: String
    let action: DesktopActionKind
    let decisionPacket: DesktopDecisionPacket?
    var delivery: DesktopActionDelivery
    var verified: Bool
    var detail: String

    enum CodingKeys: String, CodingKey {
        case id, observationID, app, targetID, label, action, delivery, verified, detail
        case decisionPacket = "decision_packet"
    }

    var summary: String {
        let state = verified ? "目标状态已验证" : (delivery == .notSent ? "未下发" : "结果未确认")
        return "\(action.rawValue)「\(label)」：\(state)"
    }
}

struct DesktopTaskReceipt: Codable {
    let goal: String
    let status: String
    /// Compatibility field: ONLY actions attempted in this invocation.
    let actions: [String]
    let detail: String
    var app: String? = nil
    var taskID: String = UUID().uuidString
    var turnID: String = UUID().uuidString
    var targetVersion: Int = 1
    var priorActions: [String] = []
    var currentActions: [DesktopActionRecord] = []
    /// Verified effects only, carried across the whole task chain. Unverified
    /// or unsent attempts are NOT "already done" and never enter this list.
    var verifiedActionHistory: [String] = []

    enum CodingKeys: String, CodingKey {
        case goal, status, actions, detail, app
        case taskID = "task_id", turnID = "turn_id", targetVersion = "target_version"
        case priorActions = "prior_actions", currentActions = "current_actions"
        case verifiedActionHistory = "verified_action_history"
    }

    var toolOutput: String {
        guard let data = try? JSONEncoder().encode(self) else { return "任务结果编码失败，不能声称完成。" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Action speech is not another model inference. An old action or a
    /// provider's confident prose cannot turn into a new completion claim.
    var spokenSummary: String {
        let sent = currentActions.filter { $0.delivery != .notSent }
        guard let last = sent.last else {
            return "这次没有执行操作。\(detail)"
        }
        if status == "completed", currentActions.allSatisfy({ $0.verified }), last.verified {
            if currentActions.count > 1 { return "已完成并确认这 \(currentActions.count) 步操作。" }
            switch last.action {
            case .openApp: return "已确认「\(last.label)」已启动。"
            case .type: return "文字已输入，并已读回确认。"
            default: return "已确认「\(last.label)」的操作结果。"
            }
        }
        if last.delivery == .unknown { return "本轮尝试了操作，但结果还不确定，已停下，没有继续尝试其他目标。" }
        if last.verified { return "本轮已确认 \(currentActions.filter(\.verified).count) 步；后续条件未满足，已停下。" }
        if last.action == .openApp {
            return "我发出了打开「\(last.label)」的请求，但没有确认到它的可见前台窗口，所以不能说已经打开。"
        }
        return "已向「\(last.label)」发送操作，但目标结果还没有确认，已停下。"
    }
}
