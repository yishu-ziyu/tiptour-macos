//
//  CompanionPanelView.swift
//  TipTour
//
//  SwiftUI content hosted inside the menu bar panel. The normal surface is
//  intentionally pointer-first; durable configuration lives in the separate
//  Settings window.
//  Dark aesthetic via DS.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var setupStep: SetupStep = .mode

    private enum SetupStep: Int {
        case mode = 1, key, permissions
    }

    private var isReady: Bool {
        companionManager.hasCompletedOnboarding && companionManager.hasSelectedModeKey
            && companionManager.hasSelectedModePermissions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 14) {
                if isReady {
                    primaryMessageSection
                    readyControlSection
                } else {
                    onboardingSection
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)

            Spacer().frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 300)
        .background(panelBackground)
        .onAppear {
            companionManager.refreshProviderKeyStatus()
            if companionManager.hasCompletedOnboarding {
                setupStep = companionManager.hasSelectedModeKey ? .permissions : .key
            }
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("TipTour")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            pinToggleButton

            Button(action: {
                NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Pushpin toggle. When on, the panel stays visible regardless of
    /// outside clicks. When off (default), the panel behaves like a
    /// standard menu bar popover.
    private var pinToggleButton: some View {
        Button(action: {
            companionManager.setPanelPinned(!companionManager.isPanelPinned)
        }) {
            Image(systemName: companionManager.isPanelPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(
                    companionManager.isPanelPinned
                        ? DS.Colors.accent
                        : DS.Colors.textTertiary
                )
                .rotationEffect(.degrees(companionManager.isPanelPinned ? 0 : 45))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(
                            companionManager.isPanelPinned
                                ? DS.Colors.accent.opacity(0.15)
                                : Color.white.opacity(0.08)
                        )
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(companionManager.isPanelPinned
            ? "Unpin: panel will close when you click outside"
            : "Pin: panel will stay open when you click outside")
    }

    // MARK: - Primary Message

    private var primaryMessageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(companionManager.selectedMode.title) is ready", systemImage: companionManager.selectedMode.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(companionManager.selectedMode.summary)
                .font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: companionManager.openSelectedMode) {
                Text("\(companionManager.selectedMode.isVoiceMode ? (companionManager.voiceState == .idle ? "开始语音" : "停止语音") : "打开 JEV")  ·  \(companionManager.selectedMode.shortcut)")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Colors.accent)
            .pointerCursor()
            .disabled(companionManager.isTextCommandRunning)
        }
    }

    private var onboardingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("设置 · 第 \(setupStep.rawValue) / 3 步")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
                Text(setupStep == .mode ? "选择你的工作方式" : setupStep == .key ? "连接 \(companionManager.selectedMode.title)" : "允许桌面访问权限")
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            }

            switch setupStep {
            case .mode:
                ModeSelectionView(companionManager: companionManager)
                Text("默认选择 JEV，之后可在「设置」中切换。")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .key:
                ProviderKeyCard(mode: companionManager.selectedMode,
                    onKeyChanged: companionManager.refreshProviderKeyStatus)
                    .id(companionManager.selectedMode)
            case .permissions:
                Text(companionManager.selectedMode == .jev
                    ? "JEV 需要「辅助功能」和「屏幕录制」权限来查看并点击屏幕控件，不需要麦克风。"
                    : "\(companionManager.selectedMode.title) 需要桌面访问权限和麦克风，才能用语音操作电脑。")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                permissionsListSection
            }

            HStack {
                if setupStep != .mode {
                    Button("上一步") {
                        setupStep = setupStep == .permissions ? .key : .mode
                    }
                    .buttonStyle(.plain).pointerCursor()
                    .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer()
                Button(setupStep == .permissions ? "开始使用 \(companionManager.selectedMode.title)" : "继续") {
                    switch setupStep {
                    case .mode: setupStep = .key
                    case .key: setupStep = .permissions
                    case .permissions: companionManager.triggerOnboarding()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Colors.accent).pointerCursor()
                .disabled((setupStep == .key && !companionManager.hasSelectedModeKey)
                    || (setupStep == .permissions && (!companionManager.hasSelectedModeKey || !companionManager.hasSelectedModePermissions)))
            }
        }
    }

    // MARK: - Ready Controls

    private var readyControlSection: some View {
        VStack(spacing: 8) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                compactControlButton(
                    title: companionManager.isAutopilotEnabled ? "Auto-click" : "Point only",
                    subtitle: companionManager.isAutopilotEnabled ? "acts" : "guides",
                    systemImage: companionManager.isAutopilotEnabled ? "wand.and.stars" : "hand.tap",
                    isActive: companionManager.isAutopilotEnabled,
                    helpText: companionManager.isAutopilotEnabled
                        ? "TipTour clicks and types after grounding one action"
                        : "TipTour points at the target and waits for you"
                ) {
                    companionManager.setAutopilotEnabled(!companionManager.isAutopilotEnabled)
                }

                compactControlButton(
                    title: companionManager.isAccurateGroundingEnabled ? "Local" : "AX/DOM",
                    subtitle: "grounding",
                    systemImage: "scope",
                    isActive: companionManager.isAccurateGroundingEnabled,
                    helpText: "Toggle local YOLO/OCR grounding"
                ) {
                    companionManager.setAccurateGroundingEnabled(!companionManager.isAccurateGroundingEnabled)
                }

                if companionManager.selectedMode.isVoiceMode {
                compactControlButton(
                    title: companionManager.isScreenshotStreamingEnabled ? "Screens" : "Private",
                    subtitle: companionManager.isScreenshotStreamingEnabled ? "remote" : "local",
                    systemImage: companionManager.isScreenshotStreamingEnabled ? "eye" : "eye.slash",
                    isActive: companionManager.isScreenshotStreamingEnabled,
                    helpText: "Toggle remote screenshot context"
                ) {
                    companionManager.setScreenshotStreamingEnabled(!companionManager.isScreenshotStreamingEnabled)
                }
                }

            }

            if let activityText = companionManager.textCommandActivityText, !activityText.isEmpty {
                HStack(spacing: 6) {
                    if companionManager.isTextCommandRunning {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                    }
                    Text(activityText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
    }

    private func compactControlButton(
        title: String,
        subtitle: String,
        systemImage: String,
        isActive: Bool,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActive ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? DS.Colors.accent.opacity(0.11) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive ? DS.Colors.accent.opacity(0.28) : DS.Colors.borderSubtle, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(helpText)
    }

    // MARK: - Permissions List

    private var permissionsListSection: some View {
        VStack(spacing: 2) {
            Text("权限")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            if companionManager.selectedMode.isVoiceMode { microphonePermissionRow }
            accessibilityPermissionRow
            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }


        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("辅助功能")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("这样我才能移动光标并读取屏幕上的内容。")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                HStack(spacing: 6) {
                    grantButton {
                        WindowPositionManager.requestAccessibilityPermission()
                    }
                    Button(action: {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("在访达中显示")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("屏幕录制")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(isGranted
                         ? "So I can see your screen when you ask for help."
                         : "Quit and reopen after granting.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    WindowPositionManager.requestScreenRecordingPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("屏幕内容")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("让我持续读取屏幕，无需每次手动选择窗口。")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    companionManager.requestScreenContentPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("麦克风 · 仅语音模式")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("这样你就能按住 ⌃⌥ 和我对话。")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var grantedPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DS.Colors.success)
                .frame(width: 6, height: 6)
            Text("已授权")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.success)
        }
    }

    private func grantButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("授权")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var footerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {

                footerIconButton("设置", systemImage: "gearshape") {
                    NotificationCenter.default.post(name: .tipTourOpenSettings, object: nil)
                    NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
                }

                footerIconButton("日志", systemImage: "doc.text.magnifyingglass") {
                    PipelineLogStore.shared.record(
                        category: "ui",
                        name: "open_logs_window",
                        status: "ok",
                        message: "Opened TipTour logs window."
                    )
                    NotificationCenter.default.post(name: .tipTourOpenLogs, object: nil)
                    NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
                }

                Spacer()

                footerIconButton("退出", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }

        }
    }

    private func footerIconButton(
        _ title: String,
        systemImage: String,
        toggled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundColor(toggled ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(title)
    }

    // MARK: - Visuals

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !isReady {
            return "设置"
        }
        if !companionManager.isOverlayVisible {
            return "就绪"
        }
        switch companionManager.voiceState {
        case .idle:
            return "进行中"
        case .listening:
            return "聆听中"
        case .processing:
            return "处理中"
        case .responding:
            return "回应中"
        }
    }
}
