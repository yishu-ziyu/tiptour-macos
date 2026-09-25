import Foundation

/// The two ways a user can drive the desktop: type a task and let the local
/// detector plus JEV pick a control, or talk and let the realtime voice model
/// decide what to ask for.
nonisolated enum TipTourMode: String, CaseIterable, Identifiable {
    case jev
    case stepfun

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

    /// Every voice-specific branch tests this rather than naming a provider, so
    /// the voice slot can change provider without touching those branches.
    var isVoiceMode: Bool {
        switch self {
        case .jev: return false
        case .stepfun: return true
        }
    }

    /// The retired Gemini mode was the previous voice provider. Users who had
    /// picked it keep voice as their way of working and land on StepFun, where
    /// setup asks for the StepFun key they have not entered yet.
    private static let retiredGeminiModeRawValue = "gemini"

    static func restored(from value: String?) -> Self {
        if value == retiredGeminiModeRawValue { return .stepfun }
        return value.flatMap(Self.init(rawValue:)) ?? .jev
    }

    /// Voice needs the microphone; JEV does not. Desktop permission
    /// (accessibility) is required by every mode because all of them act on apps.
    func permissionsReady(desktop: Bool, microphone: Bool) -> Bool {
        desktop && (self == .jev || microphone)
    }
}
