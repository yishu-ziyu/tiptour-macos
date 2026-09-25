import Foundation

/// The two ways a user can drive the desktop: type a task and let the local
/// detector plus JEV pick a control, or talk and let the realtime voice model
/// decide what to ask for.
///
/// `stepfun` replaced `gemini` as the voice provider; Gemini was removed on
/// 2026-09-25. A stored `gemini` value restores as `stepfun` (see `restored`).
///
/// Declaration order is the order the mode picker lists them: voice first
/// (docs/PRODUCT.md), JEV text as the fallback entry.
nonisolated enum TipTourMode: String, CaseIterable, Identifiable {
    case stepfun
    case jev

    var id: String { rawValue }
    var title: String {
        switch self {
        case .jev: return "JEV"
        case .stepfun: return "阶跃"
        }
    }

    /// The interaction form, shown beside the title in the mode picker. Kept
    /// separate from the title so a name never has to repeat it.
    var kindLabel: String {
        switch self {
        case .jev: return "文字"
        case .stepfun: return "实时语音"
        }
    }
    var keyName: String {
        switch self {
        case .jev: return "jevAPIKey"
        case .stepfun: return "stepfunAPIKey"
        }
    }
    /// Where a user without a key gets one; shown under the key field.
    var keyPortalURL: URL? {
        switch self {
        case .stepfun: return URL(string: "https://platform.stepfun.com/")
        case .jev: return URL(string: "https://console.typesafe.ai/settings/keys")
        }
    }
    var keyPortalName: String {
        switch self {
        case .stepfun: return "阶跃开放平台"
        case .jev: return "TypeSafe 控制台"
        }
    }
    var shortcut: String {
        switch self {
        case .jev: return "Ctrl+K"
        case .stepfun: return "Ctrl+Option"
        }
    }
    var systemImage: String {
        switch self {
        case .jev: return "text.cursor"
        case .stepfun: return "waveform"
        }
    }
    var summary: String {
        switch self {
        case .jev:
            return "输入任务，JEV 会找到并点击屏幕上的控件。"
        case .stepfun:
            return "用中文自然对话，由阶跃实时语音决定下一步该做什么。"
        }
    }
    var privacySummary: String {
        switch self {
        case .jev:
            return "你的任务和检测到的屏幕文字会发送到 TypeSafe，图片只留在本机。"
        case .stepfun:
            return "语音和按需截图会发送到阶跃；已配置 JEV 时，控件文字和位置也会发给 TypeSafe。"
        }
    }

    /// Voice-specific branches test this rather than naming a provider.
    var isVoiceMode: Bool {
        switch self {
        case .jev: return false
        case .stepfun: return true
        }
    }

    /// Only a missing or unknown stored value falls back to the default, so an
    /// existing user's saved choice is never switched underneath them. The
    /// retired `gemini` value is unknown now, so those users land on voice and
    /// the panel asks for the StepFun key.
    static func restored(from value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .stepfun
    }

    /// Voice needs the microphone; JEV does not. Desktop permission
    /// (accessibility) is required by every mode because all of them act on apps.
    func permissionsReady(desktop: Bool, microphone: Bool) -> Bool {
        desktop && (self == .jev || microphone)
    }
}
