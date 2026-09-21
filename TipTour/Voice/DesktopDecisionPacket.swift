import Foundation

enum DesktopDecisionSource: String, Codable {
    case deterministic
    case jevFanout = "jev_fanout"
    case generalModel = "general_model"
}

enum DesktopDecisionScope: String, Codable {
    case single
    case workflow
}

struct DesktopDecisionPacket: Codable, Equatable {
    struct Target: Codable, Equatable {
        let id: String
        let label: String
        let source: String
    }

    struct Location: Codable, Equatable {
        let region: DesktopTargetRegion?
        let anchorLabel: String?
        let relation: DesktopTargetRelation?
        let resolvedTargetID: String?

        enum CodingKeys: String, CodingKey {
            case region, relation
            case anchorLabel = "anchor_label"
            case resolvedTargetID = "resolved_target_id"
        }
    }

    struct Confidence: Codable, Equatable {
        let intent: Double?
        let action: Double?
        let target: Double?
        let whereValue: Double?
        let actionMargin: Double?
        let targetMargin: Double?

        enum CodingKeys: String, CodingKey {
            case intent, action, target
            case whereValue = "where"
            case actionMargin = "action_margin"
            case targetMargin = "target_margin"
        }
    }

    let source: DesktopDecisionSource
    let intent: DesktopTaskIntent?
    let action: DesktopActionKind
    let target: Target?
    let whereValue: Location?
    let scope: DesktopDecisionScope
    let requiresPerception: Bool
    let requiresPlanning: Bool
    let confidence: Confidence
    let evidence: [String]

    enum CodingKeys: String, CodingKey {
        case source, intent, action, target, scope, confidence, evidence
        case whereValue = "where"
        case requiresPerception = "requires_perception"
        case requiresPlanning = "requires_planning"
    }

    static func make(
        step: DesktopActionStep,
        target: DesktopTaskTarget?,
        intent: DesktopTaskIntent?,
        scope: DesktopDecisionScope,
        modelDecision: DesktopTaskDecision?
    ) -> DesktopDecisionPacket {
        let source = modelDecision?.source ?? .deterministic
        let actionConfidence: Double?
        let actionMargin: Double?
        if step.allowsActionDecision {
            actionConfidence = modelDecision?.actionProbability
            actionMargin = modelDecision?.actionMargin
        } else {
            actionConfidence = 1
            actionMargin = 1
        }
        let targetConfidence: Double? = target == nil
            ? nil
            : (modelDecision == nil ? 1 : modelDecision?.targetProbability)
        let targetMargin: Double? = target == nil
            ? nil
            : (modelDecision == nil ? 1 : modelDecision?.targetMargin)
        let hasCodeOwnedLocationConstraint = step.region != nil || step.anchorLabel != nil || step.relation != nil
        let locationConfidence: Double? = target == nil
            ? nil
            : (hasCodeOwnedLocationConstraint ? 1 : targetConfidence)

        var evidence: [String] = []
        evidence.append(step.allowsActionDecision ? "action_selected" : "action_locked")
        if target != nil { evidence.append(source == .deterministic ? "target_exact" : "target_selected") }
        if hasCodeOwnedLocationConstraint { evidence.append("location_filtered_in_code") }
        if source == .jevFanout { evidence.append("speculative_fanout") }

        return DesktopDecisionPacket(
            source: source,
            intent: intent,
            action: step.action,
            target: target.map { Target(id: $0.id, label: $0.label, source: $0.source) },
            whereValue: target == nil && !hasCodeOwnedLocationConstraint ? nil : Location(
                region: step.region,
                anchorLabel: step.anchorLabel,
                relation: step.relation,
                resolvedTargetID: target?.id
            ),
            scope: scope,
            requiresPerception: step.action.needsTarget,
            requiresPlanning: scope == .workflow,
            confidence: Confidence(
                intent: nil,
                action: actionConfidence,
                target: targetConfidence,
                whereValue: locationConfidence,
                actionMargin: actionMargin,
                targetMargin: targetMargin
            ),
            evidence: evidence
        )
    }
}
