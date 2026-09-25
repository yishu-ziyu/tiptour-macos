import AVFoundation
import AppKit
import SwiftUI

/// One macOS permission as the panel presents it: why she needs it, and a
/// button that requests it the same way the previous panel did.
enum PanelPermission: Hashable {
    case microphone
    case accessibility
    case screenRecording
    case screenContent

    /// What the first conversation needs, asked during setup. Everything else
    /// waits until it is first used.
    static func firstUse(for mode: TipTourMode) -> [PanelPermission] {
        mode.isVoiceMode ? [.microphone, .accessibility] : [.accessibility, .screenRecording]
    }

    var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .screenContent: return "屏幕内容"
        }
    }

    var reason: String {
        switch self {
        case .microphone: return "听见你说话。"
        case .accessibility: return "响应 ⌃⌥，并替你点击和输入。"
        case .screenRecording: return "你问起屏幕时，看一眼当前窗口。授权后需重新打开 Her。"
        case .screenContent: return "看屏幕时不用每次都选窗口。"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic"
        case .accessibility: return "hand.raised"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .screenContent: return "eye"
        }
    }

    @MainActor
    func isGranted(in companionManager: CompanionManager) -> Bool {
        switch self {
        case .microphone: return companionManager.hasMicrophonePermission
        case .accessibility: return companionManager.hasAccessibilityPermission
        case .screenRecording: return companionManager.hasScreenRecordingPermission
        case .screenContent: return companionManager.hasScreenContentPermission
        }
    }

    @MainActor
    func request(in companionManager: CompanionManager) {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else if let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                // Once denied, macOS never shows the prompt again; only Settings can change it.
                NSWorkspace.shared.open(microphoneSettingsURL)
            }
        case .accessibility:
            WindowPositionManager.requestAccessibilityPermission()
        case .screenRecording:
            WindowPositionManager.requestScreenRecordingPermission()
        case .screenContent:
            companionManager.requestScreenContentPermission()
        }
    }
}

struct PanelPermissionRow: View {
    let permission: PanelPermission
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        let isGranted = permission.isGranted(in: companionManager)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(PanelStyle.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(PanelStyle.primaryText)
                Text(permission.reason)
                    .font(.system(size: 11))
                    .foregroundColor(PanelStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isGranted {
                Label("已允许", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(PanelStyle.successTint)
            } else {
                PanelPrimaryButton(title: "允许") { permission.request(in: companionManager) }
                    .accessibilityLabel("允许\(permission.title)")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
    }
}
