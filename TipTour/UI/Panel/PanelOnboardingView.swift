import AppKit
import SwiftUI

/// First-run setup inside the panel: save the selected mode's key, then grant
/// what the first conversation needs, then show how to start it.
///
/// Only the permissions the first use needs are asked for here (user decision
/// 2026-09-23, docs/development/2026-09-23-first-run-and-interface.md): voice
/// needs the microphone and Accessibility (the ⌃⌥ shortcut is an event tap that
/// macOS only delivers to trusted apps). Screen Recording waits until she is
/// first asked to look at the screen. Her name is asked in conversation and can
/// be changed in Settings; the mode picker lives in Settings too.
struct PanelOnboardingView: View {
    @ObservedObject var companionManager: CompanionManager
    @Binding var setupStep: SetupStep

    enum SetupStep: Int, CaseIterable {
        case key = 1, permissions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch setupStep {
            case .key: keyStep
            case .permissions: permissionsStep
            }
        }
        .onAppear {
            companionManager.refreshProviderKeyStatus()
            // A key already in the Keychain (even one not yet read in this
            // process) counts as saved: never ask for it twice.
            if companionManager.selectedModeKeyState.itemExists { setupStep = .permissions }
        }
    }

    static func stepIndicator(currentStep: SetupStep) -> some View {
        HStack(spacing: 4) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= currentStep.rawValue ? PanelStyle.primaryText : PanelStyle.hairline)
                    .frame(width: 16, height: 3)
            }
        }
        .accessibilityLabel("设置第 \(currentStep.rawValue) 步，共 \(SetupStep.allCases.count) 步")
    }

    // MARK: - Step 1: key

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("连接\(companionManager.selectedMode.title)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelStyle.primaryText)
                .panelRow(1)
            Text(keyStepExplanation)
                .font(.system(size: 12))
                .foregroundColor(PanelStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .panelRow(2)
            PanelKeyField(mode: companionManager.selectedMode) {
                companionManager.refreshProviderKeyStatus()
            }
            .padding(.top, 12)
            .panelRow(3)
            HStack {
                Spacer()
                PanelPrimaryButton(title: "继续", isEnabled: companionManager.selectedModeKeyState.itemExists) {
                    setupStep = .permissions
                }
            }
            .padding(.top, 14)
            .panelRow(4)
        }
    }

    private var keyStepExplanation: String {
        switch companionManager.selectedMode {
        case .stepfun: return "她用阶跃的实时语音和你说话。密钥只存在这台 Mac 的钥匙串里。"
        case .jev: return "JEV 负责判断该点屏幕上的哪个控件。密钥只存在这台 Mac 的钥匙串里。"
        case .gemini: return "Gemini 负责语音对话。密钥只存在这台 Mac 的钥匙串里。"
        }
    }

    // MARK: - Step 2: permissions for the first use

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(companionManager.selectedMode.isVoiceMode ? "让她听见你" : "让 JEV 看见并点击")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelStyle.primaryText)
                .panelRow(1)
            Text(companionManager.selectedMode.isVoiceMode
                ? "只在你按下 ⌃⌥ 之后才听，再按一下就停。看屏幕的权限等你第一次问起屏幕时再给。"
                : "JEV 读取屏幕上的控件并替你点击，不需要麦克风。")
                .font(.system(size: 12))
                .foregroundColor(PanelStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .panelRow(2)
            VStack(spacing: 2) {
                ForEach(Array(PanelPermission.firstUse(for: companionManager.selectedMode).enumerated()), id: \.element) { index, permission in
                    PanelPermissionRow(permission: permission, companionManager: companionManager)
                        .panelRow(3 + index)
                }
            }
            .padding(.top, 10)
            HStack {
                PanelTextButton(title: "上一步") { setupStep = .key }
                Spacer()
                PanelPrimaryButton(title: "完成", isEnabled: companionManager.hasFirstUsePermissions) {
                    companionManager.triggerOnboarding()
                }
            }
            .padding(.top, 14)
            .panelRow(6)
        }
    }
}

/// The key input for one mode. Keeps the three Keychain states the old card
/// kept apart: nothing saved, saved but macOS refuses the read, and saved but
/// not decodable each get their own message.
struct PanelKeyField: View {
    let mode: TipTourMode
    var onKeyChanged: () -> Void = {}

    @State private var keyInput = ""
    @State private var keyState: KeychainItemState = .absent
    @State private var saveStatusMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField(keyState.itemExists ? "已保存，粘贴新的密钥可替换" : "粘贴 API 密钥", text: $keyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(PanelStyle.primaryText)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PanelStyle.quietFill))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PanelStyle.hairline, lineWidth: 0.5))
                    .accessibilityLabel("\(mode.title) API 密钥")
                    .onSubmit { saveKey() }
                if !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PanelPrimaryButton(title: "保存", action: saveKey)
                }
            }
            if !saveStatusMessage.isEmpty {
                Text(saveStatusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(PanelStyle.secondaryText)
            } else if keyStateNeedsAttention {
                Text(keyState.userMessage(subject: "\(mode.title) 密钥"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(PanelStyle.warningTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let keyPortalURL = mode.keyPortalURL {
                Link(destination: keyPortalURL) {
                    Text("还没有密钥？去\(mode.keyPortalName)获取 ↗")
                        .font(.system(size: 12))
                        .foregroundColor(PanelStyle.accent)
                }
                .pointerCursor()
            }
        }
        .onAppear { keyState = KeychainStore.presence(forKey: mode.keyName) }
    }

    /// A saved-but-not-yet-read key is normal and stays quiet; refused,
    /// undecodable and unknown states are problems the user must act on.
    private var keyStateNeedsAttention: Bool {
        switch keyState {
        case .readDenied, .undecodable, .unavailable: return true
        case .available, .saved, .absent: return false
        }
    }

    private func saveKey() {
        let trimmedKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        if KeychainStore.set(trimmedKey, forKey: mode.keyName) {
            // Re-read instead of assuming success, so a written-but-unreadable
            // item is reported as exactly that.
            keyState = KeychainStore.presence(forKey: mode.keyName)
            keyInput = ""
            saveStatusMessage = keyState.itemExists ? "已保存到钥匙串" : "写入后没能读回，请再试一次。"
            onKeyChanged()
        } else {
            saveStatusMessage = "保存到钥匙串失败，请再试一次。"
        }
    }
}
