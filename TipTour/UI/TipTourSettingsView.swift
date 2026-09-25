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
                title: "CUA Driver",
                subtitle: companionManager.isCuaActionDriverEnabled
                    ? "Desktop clicking, typing, launching, and shortcuts are enabled."
                    : "TipTour can observe and plan, but desktop actions are blocked.",
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
                title: "Remote Screenshots",
                subtitle: companionManager.isScreenshotStreamingEnabled
                    ? "She can send a screenshot to StepFun when you ask about the screen."
                    : "Remote visual context is off; local grounding can still run.",
                systemImage: companionManager.isScreenshotStreamingEnabled ? "eye" : "eye.slash",
                isOn: Binding(
                    get: { companionManager.isScreenshotStreamingEnabled },
                    set: { companionManager.setScreenshotStreamingEnabled($0) }
                )
            )

            settingsRow(
                title: "Accurate Grounding",
                subtitle: companionManager.isAccurateGroundingEnabled
                    ? "Local YOLO/OCR targets improve grounding before LLM coordinates."
                    : "Use AX/DOM and standard local resolvers.",
                systemImage: "scope",
                isOn: Binding(
                    get: { companionManager.isAccurateGroundingEnabled },
                    set: { companionManager.setAccurateGroundingEnabled($0) }
                )
            )

            note("Screenshots only controls remote visual context. TipTour still uses local screen understanding for grounding and safety when enabled.")
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if companionManager.selectedMode.isVoiceMode {
            permissionRow(
                title: "Microphone",
                subtitle: "Required for voice input.",
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
                title: "Accessibility",
                subtitle: "Required to read app UI and drive desktop actions.",
                systemImage: "hand.raised",
                isGranted: companionManager.hasAccessibilityPermission
            ) {
                WindowPositionManager.requestAccessibilityPermission()
            }

            permissionRow(
                title: "Screen Recording",
                subtitle: "Required to capture screen context.",
                systemImage: "rectangle.dashed.badge.record",
                isGranted: companionManager.hasScreenRecordingPermission
            ) {
                WindowPositionManager.requestScreenRecordingPermission()
            }

            if companionManager.hasScreenRecordingPermission {
                permissionRow(
                    title: "Screen Content",
                    subtitle: "Lets TipTour read the screen without choosing a window each time.",
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
                title: "Neko Mode",
                subtitle: "Use the pixel-art cursor instead of the standard pointer.",
                systemImage: "cat.fill",
                isOn: Binding(
                    get: { companionManager.isNekoModeEnabled },
                    set: { companionManager.setNekoModeEnabled($0) }
                )
            )

            #if DEBUG
            settingsRow(
                title: "Detection Overlay",
                subtitle: "Show local CoreML and OCR boxes for debugging.",
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
                companionManager.detectedElementBubbleText = "Test"
            } label: {
                settingsActionLabel(
                    title: "Test Cursor Flight",
                    subtitle: "Send the overlay pointer to the center of the main screen.",
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
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button("Grant", action: action)
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
        case .models: return "Models"
        case .connections: return "Desktop actions"
        case .privacy: return "Privacy"
        case .permissions: return "Permissions"
        case .advanced: return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .models:
            return "给她起名，选择使用方式；阶跃语音和可选的 JEV 决策密钥可分别配置。"
        case .connections:
            return "Local harnesses and desktop action integrations."
        case .privacy:
            return "Control what can leave the Mac and how local grounding runs."
        case .permissions:
            return "macOS access TipTour needs to hear, see, and act."
        case .advanced:
            return "Experimental visuals and development controls."
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
