import Foundation

/// Other windows may be modeless dialogs; only the current window or a true
/// application-modal dialog can block an action in the active target window.
nonisolated enum WorkflowModalPolicy {
    static func blocksCurrentWindow(subrole: String?, isModal: Bool?, isFocused: Bool) -> Bool {
        if isModal == true { return true }
        guard isFocused, isModal != false else { return false }
        return subrole == "AXDialog" || subrole == "AXSystemDialog"
    }
}

/// Launching an app necessarily changes activation. Do not cancel the atomic
/// launch because an intermediate app became frontmost; the caller verifies the
/// requested bundle ID after launch. Other steps still stop on unrelated app
/// switches so cursor/keyboard work cannot continue in the wrong application.
nonisolated enum WorkflowApplicationSwitchPolicy {
    static func shouldPause(isOpenApplicationStep: Bool, matchesPlanTarget: Bool) -> Bool {
        if isOpenApplicationStep { return false }
        return !matchesPlanTarget
    }
}
