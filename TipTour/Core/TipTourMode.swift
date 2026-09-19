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
        case .stepfun: return "阶跃语音"
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
            return "Type a task. JEV finds and clicks screen controls."
        case .gemini:
            return "Talk naturally. Gemini can click, type, and guide you."
        case .stepfun:
            return "Talk naturally in Chinese. StepFun decides what to ask for."
        }
    }
    var privacySummary: String {
        switch self {
        case .jev:
            return "Your task and detected screen labels go to TypeSafe. Images stay on your Mac."
        case .gemini:
            return "Your voice and optional screenshots go to Google."
        case .stepfun:
            return "Your voice goes to StepFun. Screen content is read on your Mac and only described in text."
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
