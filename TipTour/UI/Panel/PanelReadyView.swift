import SwiftUI

/// The panel once setup is done: how to call her, three things to say, and
/// whatever is live right now (the conversation, a receipt, an error).
///
/// This is the empty state the first-run contract U2 is judged on
/// (docs/development/2026-09-23-first-run-and-interface.md). Engineering
/// switches that used to sit here moved to Settings.
struct PanelReadyView: View {
    @ObservedObject var companionManager: CompanionManager

    private var isVoiceMode: Bool { companionManager.selectedMode.isVoiceMode }
    private var isVoiceSessionLive: Bool { companionManager.voiceState != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            startControl
                .panelRow(1)

            if let voiceErrorMessage = companionManager.voiceSessionErrorMessage, !voiceErrorMessage.isEmpty {
                Label(voiceErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(PanelStyle.warningTint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .panelRow(2)
            }

            if isVoiceSessionLive, let transcript = companionManager.lastTranscript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 12))
                    .foregroundColor(PanelStyle.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .panelRow(2)
            }

            if let receipt = companionManager.desktopTaskReceipt {
                receiptView(receipt)
                    .padding(.top, 10)
                    .panelRow(3)
            }

            if let activityText = companionManager.textCommandActivityText, !activityText.isEmpty {
                HStack(spacing: 6) {
                    PanelStatusChip(text: activityText, isInProgress: companionManager.isTextCommandRunning)
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                .panelRow(3)
            }

            Text("可以这样说")
                .font(.system(size: 11))
                .foregroundColor(PanelStyle.tertiaryText)
                .padding(.top, 14)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                .panelRow(4)
            ForEach(Array(examples.enumerated()), id: \.offset) { index, example in
                exampleRow(example)
                    .panelRow(5 + index)
            }

            if !missingPermissions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(isVoiceMode ? "想让她看屏幕、替你动手，还需要：" : "JEV 还需要：")
                        .font(.system(size: 11))
                        .foregroundColor(PanelStyle.tertiaryText)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                    ForEach(missingPermissions, id: \.self) { permission in
                        PanelPermissionRow(permission: permission, companionManager: companionManager)
                    }
                }
                .padding(.top, 10)
                .panelRow(8)
            }
        }
    }

    // MARK: - Start control

    /// The keys are the button: clicking them does what pressing them does.
    private var startControl: some View {
        Button(action: companionManager.openSelectedMode) {
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    if isVoiceMode {
                        PanelKeycap(symbol: "⌃")
                        PanelKeycap(symbol: "⌥")
                    } else {
                        PanelKeycap(symbol: "⌃")
                        PanelKeycap(symbol: "K")
                    }
                }
                Text(startHint)
                    .font(.system(size: 12))
                    .foregroundColor(PanelStyle.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(companionManager.isTextCommandRunning)
        .pointerCursor(isEnabled: !companionManager.isTextCommandRunning)
        .help(isVoiceMode ? "点这里和按 ⌃⌥ 一样" : "点这里和按 ⌃K 一样")
        .accessibilityLabel(isVoiceMode ? (isVoiceSessionLive ? "结束对话" : "开始说话") : "打开输入框")
    }

    private var startHint: String {
        guard isVoiceMode else { return "按一下打开输入框，写下要点击什么" }
        switch companionManager.voiceState {
        case .idle: return "按一下开始说话，再按一下结束"
        case .processing: return "正在连接…"
        case .listening, .responding: return "对话中，再按一下 ⌃⌥ 结束"
        }
    }

    // MARK: - Examples

    private struct Example {
        let systemImage: String
        let phrase: String
        let kind: String
    }

    /// Each one exercises a path that exists today: describe_screen, open_app
    /// (verified by a visible window), and plain conversation. Rows are
    /// examples to say, not buttons, so they have no hover or pointer.
    private var examples: [Example] {
        if isVoiceMode {
            return [
                Example(systemImage: "eye", phrase: "“这个页面在讲什么？”", kind: "看屏幕"),
                Example(systemImage: "cursorarrow", phrase: "“打开备忘录”", kind: "动手"),
                Example(systemImage: "bubble.left", phrase: "“我今天有点累”", kind: "聊天"),
            ]
        }
        return [
            Example(systemImage: "cursorarrow.click", phrase: "点「新建文件夹」", kind: "单击"),
            Example(systemImage: "cursorarrow.click.2", phrase: "双击「下载」", kind: "双击"),
            Example(systemImage: "contextualmenu.and.cursorarrow", phrase: "右键第一个文件", kind: "右键"),
        ]
    }

    private func exampleRow(_ example: Example) -> some View {
        HStack(spacing: 10) {
            Image(systemName: example.systemImage)
                .font(.system(size: 13))
                .foregroundColor(PanelStyle.secondaryText)
                .frame(width: 18)
            Text(example.phrase)
                .font(.system(size: 13))
                .foregroundColor(PanelStyle.primaryText)
            Spacer(minLength: 8)
            Text(example.kind)
                .font(.system(size: 11))
                .foregroundColor(PanelStyle.tertiaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    // MARK: - Receipt and permissions

    private func receiptView(_ receipt: DesktopTaskReceipt) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(receipt.goal)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(PanelStyle.primaryText)
                .lineLimit(2)
            Text(receipt.spokenSummary)
                .font(.system(size: 12))
                .foregroundColor(PanelStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            // The same evidence counters the spoken progress uses, so the panel
            // can never report a delivered input as a result the system verified.
            if receipt.totalStepCount > 0 {
                Text(receipt.progressEvidenceLine)
                    .font(.system(size: 11))
                    .foregroundColor(PanelStyle.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PanelStyle.quietFill))
    }

    /// Permissions not yet granted that some example above needs. Screen
    /// Content only makes sense once Screen Recording is granted.
    private var missingPermissions: [PanelPermission] {
        var candidates: [PanelPermission] = [.accessibility, .screenRecording]
        if isVoiceMode { candidates.insert(.microphone, at: 0) }
        if companionManager.hasScreenRecordingPermission { candidates.append(.screenContent) }
        return candidates.filter { !$0.isGranted(in: companionManager) }
    }
}
