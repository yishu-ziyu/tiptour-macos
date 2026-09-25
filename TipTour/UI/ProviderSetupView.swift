import SwiftUI

struct ProviderSetupView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var editingKeyMode: TipTourMode = .stepfun
    @State private var hoveredKeyMode: TipTourMode?

    private var visibleKeyMode: TipTourMode {
        guard companionManager.selectedMode == .stepfun else { return companionManager.selectedMode }
        return editingKeyMode == .jev ? .jev : .stepfun
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModeSelectionView(companionManager: companionManager, compact: true)

            if companionManager.selectedMode == .stepfun {
                VStack(alignment: .leading, spacing: 9) {
                    Text("配置 API 密钥")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    HStack(spacing: 8) {
                        keyEditorButton(for: .stepfun, title: "阶跃语音密钥")
                        keyEditorButton(for: .jev, title: "JEV 决策密钥（可选）")
                    }

                    Text("这里只切换正在编辑的密钥，不会切换语音模式。")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }

            ProviderKeyCard(mode: visibleKeyMode,
                onKeyChanged: companionManager.refreshProviderKeyStatus)
                .id(visibleKeyMode)
            Text("密钥分别保存在 macOS 钥匙串。切换上方的使用方式会结束当前语音会话。")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { editingKeyMode = companionManager.selectedMode }
        .onChange(of: companionManager.selectedMode) { _, selectedMode in
            editingKeyMode = selectedMode
        }
    }

    private func keyEditorButton(for mode: TipTourMode, title: String) -> some View {
        let isEditing = visibleKeyMode == mode
        return Button {
            editingKeyMode = mode
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isEditing ? DS.Colors.textOnAccent : DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(isEditing
                        ? (hoveredKeyMode == mode ? DS.Colors.accentHover : DS.Colors.accent)
                        : (hoveredKeyMode == mode ? DS.Colors.surface3 : DS.Colors.surface2)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isEditing ? DS.Colors.accent : DS.Colors.borderStrong))
        }
        .buttonStyle(.plain)
        .onHover { hoveredKeyMode = $0 ? mode : nil }
        .pointerCursor()
        .accessibilityValue(isEditing ? "正在编辑" : "未选择")
    }
}

/// The one place the user names her, shared by onboarding and Settings.
///
/// Edits a local draft and saves every change, so the saved name is always
/// current without writing the trimmed value back into the field (which would
/// swallow a space the user is in the middle of typing).
struct CompanionNameField: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("例如：小满", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .tint(DS.Colors.accentText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.borderStrong))
                .accessibilityLabel("她的名字")
                .onChange(of: nameDraft) { _, newNameDraft in
                    companionManager.setCompanionName(newNameDraft)
                }
            Text("她会用这个名字回应你，从下一次语音会话开始生效。可以先空着，之后在「设置」里起。")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { nameDraft = companionManager.companionName }
    }
}

/// Chooses her StepFun realtime voice from the voices the realtime model accepts.
struct RealtimeVoicePicker: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var hoveredVoiceIdentifier: String?

    private var voiceOptions: [TipTourDefaults.RealtimeVoiceOption] {
        TipTourDefaults.StepFunConfiguration.selectableRealtimeVoices
    }

    /// A voice set from the terminal for an A/B test is not in the list; say so
    /// instead of showing no selection without explanation.
    private var isSelectedVoiceOutsideList: Bool {
        !voiceOptions.contains { $0.voiceIdentifier == companionManager.selectedRealtimeVoice }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 6) {
                ForEach(voiceOptions) { voiceOption in
                    voiceOptionButton(voiceOption)
                }
            }
            if isSelectedVoiceOutsideList {
                Text("当前使用终端设置的「\(companionManager.selectedRealtimeVoice)」。选上面任意一个即可替换。")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("从下一次语音会话开始生效。")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private func voiceOptionButton(_ voiceOption: TipTourDefaults.RealtimeVoiceOption) -> some View {
        let isSelected = companionManager.selectedRealtimeVoice == voiceOption.voiceIdentifier
        let isHovered = hoveredVoiceIdentifier == voiceOption.voiceIdentifier
        return Button { companionManager.setRealtimeVoice(voiceOption.voiceIdentifier) } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(voiceOption.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textPrimary)
                    if let caveat = voiceOption.caveat {
                        Text(caveat)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                    ? DS.Colors.blue950.opacity(0.55)
                    : (isHovered ? DS.Colors.surface2 : DS.Colors.surface1)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? DS.Colors.accentText.opacity(0.65) : DS.Colors.borderSubtle))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in hoveredVoiceIdentifier = isHovering ? voiceOption.voiceIdentifier : nil }
        .pointerCursor()
        .accessibilityLabel("她的声音：\(voiceOption.displayName)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

struct ModeSelectionView: View {
    @ObservedObject var companionManager: CompanionManager
    var compact = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(TipTourMode.allCases) { mode in
                        compactModeButton(mode)
                    }
                }
                Text(companionManager.selectedMode.summary)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: 8) {
                ForEach(TipTourMode.allCases) { mode in
                    Button { companionManager.setSelectedMode(mode) } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: mode.systemImage).frame(width: 18)
                                .foregroundColor(DS.Colors.textSecondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(mode.title) · \(mode.kindLabel)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(companionManager.selectedMode == mode ? DS.Colors.accentText : DS.Colors.textPrimary)
                                Text(mode.summary).font(.system(size: 12))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: companionManager.selectedMode == mode ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(companionManager.selectedMode == mode ? DS.Colors.accentText : DS.Colors.textSecondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(companionManager.selectedMode == mode ? DS.Colors.blue950.opacity(0.55) : DS.Colors.surface1))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(companionManager.selectedMode == mode ? DS.Colors.accentText.opacity(0.65) : DS.Colors.borderSubtle))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(companionManager.isTextCommandRunning)
                    .accessibilityLabel("选择 \(mode.title)")
                    .accessibilityValue(companionManager.selectedMode == mode ? "已选择" : "未选择")
                }
            }
        }
    }

    private func compactModeButton(_ mode: TipTourMode) -> some View {
        let isSelected = companionManager.selectedMode == mode
        return Button { companionManager.setSelectedMode(mode) } label: {
            HStack(spacing: 5) {
                Text("\(mode.title) · \(mode.kindLabel)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark.circle.fill") }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? DS.Colors.blue950.opacity(0.55) : DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? DS.Colors.accentText.opacity(0.65) : DS.Colors.borderSubtle))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(companionManager.isTextCommandRunning)
        .accessibilityLabel("选择 \(mode.title)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

struct ProviderKeyCard: View {
    let mode: TipTourMode
    var onKeyChanged: () -> Void = {}
    private var title: String { mode == .jev ? "JEV / TypeSafe 密钥" : "\(mode.title) 密钥" }
    private var detail: String { mode.privacySummary }
    private var keyName: String { mode.keyName }
    @State private var input = ""
    /// Why there is or is not a key. Three states must never collapse into one
    /// "需要密钥" badge: nothing saved, saved but macOS refuses the read, and
    /// saved but not decodable are different problems with different remedies.
    @State private var keyState: KeychainItemState = .absent
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text(badgeText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(badgeColor)
                    .accessibilityLabel("密钥状态")
                    .accessibilityValue(badgeText)
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if mode == .jev {
                Link("没有密钥？前往 TypeSafe 控制台", destination: URL(string: "https://console.typesafe.ai/settings/keys")!)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
            }

            Text("API 密钥")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            SecureField(keyState.itemExists ? "粘贴新的密钥以替换" : "粘贴你的 API 密钥", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .tint(DS.Colors.accentText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.borderStrong))
                .accessibilityLabel("\(title) API 密钥")
                .onSubmit { save() }

            HStack(spacing: 10) {
                Button("保存密钥", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Colors.accent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointerCursor()
                Button("删除密钥", action: delete)
                    .buttonStyle(.bordered)
                    .tint(DS.Colors.destructiveText)
                    .disabled(!keyState.itemExists)
                    .pointerCursor()
            }
            if !status.isEmpty {
                Text(status).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            }
            // The state line only appears when there is something to act on, so
            // a healthy card stays quiet.
            if !keyState.isUsable {
                Text(keyState.userMessage(subject: title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(keyState == .absent ? DS.Colors.textSecondary : DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("安全存储在 macOS 钥匙串中。")
                .font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Colors.borderSubtle))
        // Presence only: no data is requested, nothing is decrypted and no
        // authorization dialog is opened by looking at the card.
        .onAppear { keyState = KeychainStore.presence(forKey: keyName) }
    }

    /// The badge is deliberately not a two-state "saved / needs a key" pair.
    private var badgeText: String {
        switch keyState {
        case .available: return "密钥已保存"
        // A presence query proved the item exists but handed this process no
        // data, so the badge claims only the save and flags the unverified
        // read. It must not slide to "尚未保存" — a save demonstrably happened
        // — nor to the bare `.available` copy, which reads as "usable now".
        case .saved: return "密钥已保存（尚未读取验证）"
        case .absent: return "尚未保存"
        case .readDenied: return "钥匙串读取失败"
        case .undecodable: return "密钥无法解析"
        case .unavailable: return "钥匙串状态未知"
        }
    }

    private var badgeColor: Color {
        switch keyState {
        case .available: return DS.Colors.success
        // Presence is evidence of a save, not of readiness: neutral primary
        // text rather than the success green `.available` earns by holding the
        // value, and rather than the warning amber reserved for states that
        // block use outright.
        case .saved: return DS.Colors.textPrimary
        case .absent: return DS.Colors.textSecondary
        // The key is saved; the problem is access, not a missing save. Warning
        // color, never the "you must save a key" treatment.
        case .readDenied, .undecodable, .unavailable: return DS.Colors.warning
        }
    }

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.set(trimmed, forKey: keyName) {
            // The write path already holds the value in process, so this is a
            // presence read served from memory: no second decrypt, no prompt.
            // It re-reads the state instead of assuming success, so an item
            // that was written but is not readable now is reported as exactly
            // that rather than as a saved key.
            keyState = KeychainStore.presence(forKey: keyName)
            input = ""
            status = "已保存"
            onKeyChanged()
        } else {
            status = "保存到钥匙串失败，请重试。"
        }
    }

    private func delete() {
        if KeychainStore.delete(forKey: keyName) {
            keyState = .absent
            input = ""
            status = "已删除"
            onKeyChanged()
        } else {
            status = "删除失败，请重试。"
        }
    }
}
