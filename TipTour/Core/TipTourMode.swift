import Foundation

/// The two ways a user can drive the desktop: type a task and let the local
/// detector plus JEV pick a control, or talk and let the realtime voice model
/// decide what to ask for.
///
/// `stepfun` replaces `gemini` as the voice provider. Gemini's API key is not
/// obtainable in this region, so its code path is being retired — it is kept
/// temporarily only so the app compiles while the StepFun session takes over.
nonisolated enum TipTourMode: String, CaseIterable, Identifiable {
    case jev
    case gemini
    case stepfun

    var id: String { rawValue }
    var title: String {
        switch self {
        case .jev: return "JEV"
        case .gemini: return "Gemini"
        case .stepfun: return "阶跃"
        }
    }

    /// The interaction form, shown beside the title in the mode picker. Kept
    /// separate from the title so a name never has to repeat it.
    var kindLabel: String {
        switch self {
        case .jev: return "文字"
        case .gemini: return "语音"
        case .stepfun: return "实时语音"
        }
    }
    var keyName: String {
        switch self {
        case .jev: return "jevAPIKey"
        case .gemini: return "geminiAPIKey"
        case .stepfun: return "stepfunAPIKey"
        }
    }
    var shortcut: String {
        switch self {
        case .jev: return "Ctrl+K"
        case .gemini, .stepfun: return "Ctrl+Option"
        }
    }
    var systemImage: String {
        switch self {
        case .jev: return "text.cursor"
        case .gemini: return "waveform"
        case .stepfun: return "waveform"
        }
    }
    var summary: String {
        switch self {
        case .jev:
            return "输入任务，JEV 会找到并点击屏幕上的控件。"
        case .gemini:
            return "自然地说话，Gemini 可以点击、输入并引导你。"
        case .stepfun:
            return "用中文自然对话，由阶跃实时语音决定下一步该做什么。"
        }
    }
    var privacySummary: String {
        switch self {
        case .jev:
            return "你的任务和检测到的屏幕文字会发送到 TypeSafe，图片只留在本机。"
        case .gemini:
            return "你的语音和可选的屏幕截图会发送到 Google。"
        case .stepfun:
            return "语音和按需截图会发送到阶跃；已配置 JEV 时，控件文字和位置也会发给 TypeSafe。"
        }
    }

    /// Both voice providers share the same interaction shape — hold a shortcut, talk,
    /// get one action per turn — so every voice-specific branch tests this rather
    /// than naming a provider.
    var isVoiceMode: Bool {
        switch self {
        case .jev: return false
        case .gemini, .stepfun: return true
        }
    }

    static func restored(from value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .jev
    }

    /// Both voice providers need the microphone; JEV does not. Desktop permission
    /// (accessibility) is required by every mode because all of them act on apps.
    func permissionsReady(desktop: Bool, microphone: Bool) -> Bool {
        desktop && (self == .jev || microphone)
    }
}
