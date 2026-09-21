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

        /// User's custom StepFun voice, also used by By-Your-Side.
        static let realtimeVoice = "voice-tone-T3kZb9MwL2"
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
