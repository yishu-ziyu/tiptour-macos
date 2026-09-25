import AVFoundation
import SwiftUI

struct TipTourSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var selectedSection: SettingsSection = .models
    private let sidebarWidth: CGFloat = 178
    private let contentMaxWidth: CGFloat = 620

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()
                .background(DS.Colors.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    selectedContent
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SettingsPointerMark()
                    .fill(DS.Colors.textSecondary)
                    .frame(width: 18, height: 18)

                Text("Her")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .padding(.bottom, 16)

            ForEach(SettingsSection.allCases) { section in
                sidebarButton(section)
            }

            Spacer()

            Text("当前：\(companionManager.selectedMode.title) · \(companionManager.selectedMode.kindLabel)\n\(companionManager.selectedMode.shortcut) 启动")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(DS.Colors.surface1)
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(selectedSection == section ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                    .frame(width: 16)

                Text(section.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(selectedSection == section ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selectedSection == section ? Color.white.opacity(0.075) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedSection.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Text(selectedSection.subtitle)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .models:
            voiceSection
        case .connections:
            connectionsSection
        case .privacy:
            privacySection
        case .permissions:
            permissionsSection
        case .advanced:
            advancedSection
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text("她的名字")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                CompanionNameField(companionManager: companionManager)
            }
            if companionManager.selectedMode == .stepfun {
                VStack(alignment: .leading, spacing: 9) {
                    Text("她的声音")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    RealtimeVoicePicker(companionManager: companionManager)
                }
            }
            ProviderSetupView(companionManager: companionManager)
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsRow(
                title: "操作桌面",
                subtitle: companionManager.isCuaActionDriverEnabled
                    ? "她可以点击、输入、打开应用和按快捷键。"
                    : "她只看和规划，不会动手操作桌面。",
                systemImage: "cursorarrow.motionlines",
                isOn: Binding(
                    get: { companionManager.isCuaActionDriverEnabled },
                    set: { companionManager.setCuaActionDriverEnabled($0) }
                )
            )

            // Moved here from the panel on 2026-09-23: the panel keeps only what
            // a user needs to start a conversation.
            settingsRow(
                title: "自动点击",
                subtitle: companionManager.isAutopilotEnabled
                    ? "找到目标后由她直接点击。"
                    : "只指出目标位置，由你自己点击（JEV 需要自动点击）。",
                systemImage: companionManager.isAutopilotEnabled ? "wand.and.stars" : "hand.tap",
                isOn: Binding(
                    get: { companionManager.isAutopilotEnabled },
                    set: { companionManager.setAutopilotEnabled($0) }
                )
            )

        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsRow(
                title: "发送截图",
                subtitle: companionManager.isScreenshotStreamingEnabled
                    ? "你问起屏幕时，她会把一张截图发给阶跃。"
                    : "截图不会发出去，本机定位照常进行。",
                systemImage: companionManager.isScreenshotStreamingEnabled ? "eye" : "eye.slash",
                isOn: Binding(
                    get: { companionManager.isScreenshotStreamingEnabled },
                    set: { companionManager.setScreenshotStreamingEnabled($0) }
                )
            )

            settingsRow(
                title: "精准定位",
                subtitle: companionManager.isAccurateGroundingEnabled
                    ? "先用本机的图像和文字识别找目标，再参考模型给的坐标。"
                    : "只用辅助功能信息和网页结构找目标。",
                systemImage: "scope",
                isOn: Binding(
                    get: { companionManager.isAccurateGroundingEnabled },
                    set: { companionManager.setAccurateGroundingEnabled($0) }
                )
            )

            note("「发送截图」只决定画面会不会发出去；本机看屏幕、定位目标和安全检查不受影响。")
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if companionManager.selectedMode.isVoiceMode {
            permissionRow(
                title: "麦克风",
                subtitle: "语音对话时听见你说话。",
                systemImage: "mic",
                isGranted: companionManager.hasMicrophonePermission
            ) {
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }

            }

            permissionRow(
                title: "辅助功能",
                subtitle: "读取应用界面，并替你点击和输入。",
                systemImage: "hand.raised",
                isGranted: companionManager.hasAccessibilityPermission
            ) {
                WindowPositionManager.requestAccessibilityPermission()
            }

            permissionRow(
                title: "屏幕录制",
                subtitle: "你问起屏幕时，看一眼屏幕上的内容。",
                systemImage: "rectangle.dashed.badge.record",
                isGranted: companionManager.hasScreenRecordingPermission
            ) {
                WindowPositionManager.requestScreenRecordingPermission()
            }

            if companionManager.hasScreenRecordingPermission {
                permissionRow(
                    title: "屏幕内容",
                    subtitle: "看屏幕时不用每次都选窗口。",
                    systemImage: "eye",
                    isGranted: companionManager.hasScreenContentPermission
                ) {
                    companionManager.requestScreenContentPermission()
                }
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsRow(
                title: "固定面板",
                subtitle: "打开后，点击面板以外的地方也不会收起面板。",
                systemImage: companionManager.isPanelPinned ? "pin.fill" : "pin",
                isOn: Binding(
                    get: { companionManager.isPanelPinned },
                    set: { companionManager.setPanelPinned($0) }
                )
            )

            Button {
                NotificationCenter.default.post(name: .tipTourOpenLogs, object: nil)
            } label: {
                settingsActionLabel(
                    title: "查看日志",
                    subtitle: "打开本机运行日志窗口，排查问题时用。",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            settingsRow(
                title: "小猫光标",
                subtitle: "用像素小猫代替普通指针。",
                systemImage: "cat.fill",
                isOn: Binding(
                    get: { companionManager.isNekoModeEnabled },
                    set: { companionManager.setNekoModeEnabled($0) }
                )
            )

            #if DEBUG
            settingsRow(
                title: "识别框",
                subtitle: "显示本机 CoreML 和 OCR 识别到的框，调试时用。",
                systemImage: "viewfinder",
                isOn: Binding(
                    get: { companionManager.isDetectionOverlayEnabled },
                    set: { companionManager.setDetectionOverlayEnabled($0) }
                )
            )

            Button {
                let screen = NSScreen.main
                companionManager.detectedElementScreenLocation = screen.map {
                    CGPoint(x: $0.frame.midX, y: $0.frame.midY)
                }
                companionManager.detectedElementDisplayFrame = screen?.frame
                companionManager.detectedElementBubbleText = "测试"
            } label: {
                settingsActionLabel(
                    title: "测试指针飞行",
                    subtitle: "让她的指针飞到主屏幕中央。",
                    systemImage: "arrow.up.right"
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            #endif
        }
    }

    private func settingsRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowIcon(systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.82)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowIcon(systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            if isGranted {
                HStack(spacing: 5) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("已允许")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button("允许", action: action)
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(DS.Colors.accent)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsActionLabel(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowIcon(systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func rowIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(width: 22)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case models
    case connections
    case privacy
    case permissions
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "模型"
        case .connections: return "桌面操作"
        case .privacy: return "隐私"
        case .permissions: return "权限"
        case .advanced: return "高级"
        }
    }

    var subtitle: String {
        switch self {
        case .models:
            return "给她起名，选择使用方式；阶跃语音和可选的 JEV 决策密钥可分别配置。"
        case .connections:
            return "决定她能不能动手操作桌面，以及由谁来点击。"
        case .privacy:
            return "决定哪些内容会离开这台 Mac，以及本机怎样定位目标。"
        case .permissions:
            return "她听你说话、看屏幕和动手操作所需的 macOS 权限。"
        case .advanced:
            return "实验性外观和开发调试选项。"
        }
    }

    var systemImage: String {
        switch self {
        case .models: return "waveform.badge.mic"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .privacy: return "lock.shield"
        case .permissions: return "checkmark.shield"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

private struct SettingsPointerMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let originX = rect.midX - 12 * scale
        let originY = rect.midY - 12 * scale

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: point(4.037, 4.688))
        path.addCurve(
            to: point(4.688, 4.037),
            control1: point(3.90, 3.90),
            control2: point(3.90, 3.90)
        )
        path.addLine(to: point(20.688, 10.537))
        path.addCurve(
            to: point(20.625, 11.484),
            control1: point(21.42, 10.84),
            control2: point(21.42, 10.84)
        )
        path.addLine(to: point(14.501, 13.064))
        path.addCurve(
            to: point(13.063, 14.499),
            control1: point(13.43, 13.34),
            control2: point(13.43, 13.34)
        )
        path.addLine(to: point(11.484, 20.625))
        path.addCurve(
            to: point(10.537, 20.688),
            control1: point(11.17, 21.42),
            control2: point(11.17, 21.42)
        )
        path.closeSubpath()
        return path
    }
}
