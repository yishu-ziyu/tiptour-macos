//
//  TipTourDefaults.swift
//  TipTour
//
//  Centralized UserDefaults access for app preferences. Keep the raw keys
//  here so feature code can read intent instead of string literals.
//

import Foundation

enum TipTourDefaults {
    enum Key: String {
        case hasCompletedOnboarding = "hasCompletedModeSetup"
        case hasScreenContentPermission
        case isAccurateGroundingEnabled
        case isAutopilotEnabled
        case isCuaActionDriverEnabled
        case isDetectionOverlayEnabled
        case isNekoModeEnabled
        case isPanelPinned
        case isScreenshotStreamingEnabled
        case hasPreviouslyConfirmedScreenRecordingPermission = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"
    }

    /// Provider wiring that is a deployment choice rather than a user preference.
    ///
    /// Kept here so a model going offline or gaining a paid successor is a one-line
    /// change instead of a hunt through the voice layer. `stepaudio-3-realtime-preview`
    /// is a limited-time free preview that StepFun has said will be retired in favour
    /// of a paid version, so the name must never be written inline.
    enum StepFunConfiguration {
        /// Realtime voice. Runs on the open-platform route: the Step Plan channel
        /// restricts its realtime models, and its `stepaudio-2.5-realtime` did not
        /// call tools at all under the same prompt.
        static let realtimeModel = "stepaudio-3-realtime-preview"

        /// Vision. Runs on the Step Plan route, where the coding subscription's
        /// credits apply.
        static let visionModel = "step-3.7-flash"

        /// Official StepFun voice 温柔熟女, the default since the user's 2026-09-23
        /// listening test of every official voice the realtime model accepts
        /// (docs/development/2026-09-23-voice-conversation-quality.md). It replaced `linjiajiejie`.
        static let defaultRealtimeVoice = "wenroushunv"

        /// User's custom clone, also used by By-Your-Side. Selectable, but it
        /// changed speaker between replies of one session in the consistency probe.
        static let customCloneRealtimeVoice = "voice-tone-T3kZb9MwL2"

        /// The voices offered in Settings, in display order. The realtime model
        /// rejects some voices the TTS models accept, so only voices it was
        /// observed to accept belong here.
        static let selectableRealtimeVoices: [RealtimeVoiceOption] = [
            RealtimeVoiceOption(voiceIdentifier: defaultRealtimeVoice, displayName: "温柔熟女",
                caveat: nil),
            RealtimeVoiceOption(voiceIdentifier: "qingchunshaonv", displayName: "清纯少女",
                caveat: nil),
            RealtimeVoiceOption(voiceIdentifier: "jingdiannvsheng", displayName: "经典女声",
                caveat: nil),
            RealtimeVoiceOption(voiceIdentifier: customCloneRealtimeVoice, displayName: "你的克隆音色",
                caveat: "多轮对话里可能突然换成别的声音"),
        ]

        /// Server VAD "energy awakeness" (0–5000, provider default 2500): audio
        /// above it counts as the user speaking. Under investigation because the
        /// 2026-09-23 14:33 session saw 4.5–5.6 s between the user's last loud
        /// mic buffer and `speech_stopped`, and a barge-in on a −38 dBFS mic.
        /// `defaults write com.yishuziyu.her stepfunVADEnergyThreshold -int <n>`
        /// changes it without a rebuild; `--vad-probe` measures candidates.
        static var serverVADEnergyThreshold: Int {
            let storedThreshold = UserDefaults.standard.integer(forKey: "stepfunVADEnergyThreshold")
            return (1...5000).contains(storedThreshold) ? storedThreshold : 2500
        }

        /// The voice for the next session. Settings writes the same key that
        /// `defaults write com.yishuziyu.her stepfunRealtimeVoice <voice>` sets,
        /// so a voice chosen from the terminal for A/B tests still applies.
        static var realtimeVoice: String {
            get {
                let storedVoice = UserDefaults.standard.string(forKey: realtimeVoiceKey)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return storedVoice.isEmpty ? defaultRealtimeVoice : storedVoice
            }
            set { UserDefaults.standard.set(newValue, forKey: realtimeVoiceKey) }
        }

        private static let realtimeVoiceKey = "stepfunRealtimeVoice"
    }

    /// How a voice conversation takes turns (user decision 2026-09-28: both
    /// kept, chosen in Settings → 模型).
    enum VoiceStyle: String, CaseIterable, Identifiable {
        /// One StepFun realtime model listens and speaks; the user can talk over her.
        case realtime
        /// Hold ⌃⌥ to talk: Step Plan speech-to-text, the Ctrl+K model, MiniMax
        /// speech with the user's own voice. She is not listening while she speaks.
        case stable

        var id: String { rawValue }
        var title: String { self == .realtime ? "随时能插嘴" : "声音稳定" }
        var detail: String {
            switch self {
            case .realtime: return "按一下 ⌃⌥ 开始对话，她说话时你随时能插嘴；反应快，偶尔音色会跳。"
            case .stable: return "按住 ⌃⌥ 说话，松手她再回，她说话时再按住就停下；用你在 MiniMax 定义的声音，每句都一样。暂时不能看屏幕和点屏幕。你的话发给阶跃转成文字，她的回答发给 MiniMax 念出来。"
            }
        }
    }

    static var voiceStyle: VoiceStyle {
        get { VoiceStyle(rawValue: UserDefaults.standard.string(forKey: "voiceStyle") ?? "") ?? .realtime }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "voiceStyle") }
    }

    /// MiniMax speech for the 「声音稳定」 style. The key is in the Keychain
    /// under `keyName`; the voice is one the user defined in MiniMax.
    enum MiniMaxConfiguration {
        static let keyName = "minimaxAPIKey"
        static let keyPortalURL = URL(string: "https://platform.minimaxi.com/")!

        static var voiceID: String {
            get { UserDefaults.standard.string(forKey: "minimaxVoiceID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "minimaxVoiceID") }
        }

        /// `defaults write com.yishuziyu.her minimaxSpeechModel speech-2.8-turbo` tries another model.
        static var speechModel: String {
            let stored = UserDefaults.standard.string(forKey: "minimaxSpeechModel") ?? ""
            return stored.isEmpty ? MiniMaxSpeechClient.defaultModel : stored
        }
    }

    struct RealtimeVoiceOption: Identifiable, Equatable {
        let voiceIdentifier: String
        let displayName: String
        /// Shown under the option when the voice has a known problem.
        let caveat: String?
        var id: String { voiceIdentifier }
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 0,
            Key.hasCompletedOnboarding.rawValue: false,
            Key.hasScreenContentPermission.rawValue: false,
            Key.hasPreviouslyConfirmedScreenRecordingPermission.rawValue: false,
            Key.isAccurateGroundingEnabled.rawValue: false,
            Key.isAutopilotEnabled.rawValue: true,
            Key.isCuaActionDriverEnabled.rawValue: true,
            Key.isDetectionOverlayEnabled.rawValue: false,
            Key.isNekoModeEnabled.rawValue: false,
            Key.isPanelPinned.rawValue: false,
            Key.isScreenshotStreamingEnabled.rawValue: true
        ])
    }

    static var selectedMode: TipTourMode {
        get { TipTourMode.restored(from: UserDefaults.standard.string(forKey: "selectedMode")) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "selectedMode") }
    }

    /// The name the user gave her. Empty means she has not been named yet.
    ///
    /// Read through `UserDefaults.standard`, so a `-companionName <name>` launch
    /// argument overrides it for one run without persisting (used by the voice probe).
    static var companionName: String {
        get { UserDefaults.standard.string(forKey: companionNameKey) ?? "" }
        set { UserDefaults.standard.set(sanitizedCompanionName(newValue), forKey: companionNameKey) }
    }

    /// The name is inserted into the voice session's instructions, so it is kept
    /// to one short line: no line breaks and at most 20 characters.
    static func sanitizedCompanionName(_ rawName: String) -> String {
        let singleLineName = rawName.components(separatedBy: .newlines).joined(separator: " ")
        return String(singleLineName.trimmingCharacters(in: .whitespaces).prefix(20))
    }

    private static let companionNameKey = "companionName"

    /// What she calls the user. Empty means the user has not said.
    static var userAddress: String {
        get { UserDefaults.standard.string(forKey: userAddressKey) ?? "" }
        set { UserDefaults.standard.set(sanitizedCompanionName(newValue), forKey: userAddressKey) }
    }

    private static let userAddressKey = "userAddress"

    static var hasCompletedOnboarding: Bool {
        get { bool(for: .hasCompletedOnboarding) }
        set { set(newValue, for: .hasCompletedOnboarding) }
    }

    static var hasScreenContentPermission: Bool {
        get { bool(for: .hasScreenContentPermission) }
        set { set(newValue, for: .hasScreenContentPermission) }
    }

    static var hasPreviouslyConfirmedScreenRecordingPermission: Bool {
        get { bool(for: .hasPreviouslyConfirmedScreenRecordingPermission) }
        set { set(newValue, for: .hasPreviouslyConfirmedScreenRecordingPermission) }
    }

    static var isAccurateGroundingEnabled: Bool {
        get { bool(for: .isAccurateGroundingEnabled) }
        set { set(newValue, for: .isAccurateGroundingEnabled) }
    }

    static var isAutopilotEnabled: Bool {
        get { bool(for: .isAutopilotEnabled) }
        set { set(newValue, for: .isAutopilotEnabled) }
    }

    static var isCuaActionDriverEnabled: Bool {
        get { bool(for: .isCuaActionDriverEnabled) }
        set { set(newValue, for: .isCuaActionDriverEnabled) }
    }

    static var isDetectionOverlayEnabled: Bool {
        get { bool(for: .isDetectionOverlayEnabled) }
        set { set(newValue, for: .isDetectionOverlayEnabled) }
    }

    static var isNekoModeEnabled: Bool {
        get { bool(for: .isNekoModeEnabled) }
        set { set(newValue, for: .isNekoModeEnabled) }
    }

    static var isPanelPinned: Bool {
        get { bool(for: .isPanelPinned) }
        set { set(newValue, for: .isPanelPinned) }
    }

    static var isScreenshotStreamingEnabled: Bool {
        get { bool(for: .isScreenshotStreamingEnabled) }
        set { set(newValue, for: .isScreenshotStreamingEnabled) }
    }

    static func reset(_ key: Key) {
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }

    private static func bool(for key: Key) -> Bool {
        if let storedValue = UserDefaults.standard.object(forKey: key.rawValue) as? Bool {
            return storedValue
        }
        return defaultBool(for: key)
    }

    private static func set(_ value: Bool, for key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    private static func defaultBool(for key: Key) -> Bool {
        switch key {
        case .isAutopilotEnabled, .isCuaActionDriverEnabled, .isScreenshotStreamingEnabled:
            return true
        case .hasCompletedOnboarding,
             .hasScreenContentPermission,
             .hasPreviouslyConfirmedScreenRecordingPermission,
             .isAccurateGroundingEnabled,
             .isDetectionOverlayEnabled,
             .isNekoModeEnabled,
             .isPanelPinned:
            return false
        }
    }

}
