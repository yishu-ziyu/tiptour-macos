import SwiftUI

struct ProviderSetupView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModeSelectionView(companionManager: companionManager)
            ProviderKeyCard(mode: companionManager.selectedMode,
                onKeyChanged: companionManager.refreshProviderKeyStatus)
                .id(companionManager.selectedMode)
            Text("Your choice is saved. You can switch modes here any time.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}

struct ModeSelectionView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 8) {
            ForEach(TipTourMode.allCases) { mode in
                Button { companionManager.setSelectedMode(mode) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: mode.systemImage).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title + (mode == .jev ? " · Text" : " · Voice"))
                                .font(.system(size: 13, weight: .semibold))
                            Text(mode.summary).font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: companionManager.selectedMode == mode ? "checkmark.circle.fill" : "circle")
                    }
                    .foregroundColor(companionManager.selectedMode == mode ? DS.Colors.accent : DS.Colors.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(companionManager.selectedMode == mode ? DS.Colors.accent.opacity(0.1) : DS.Colors.surface1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(companionManager.isTextCommandRunning)
                .accessibilityLabel("Select \(mode.title)")
                .accessibilityValue(companionManager.selectedMode == mode ? "Selected" : "Not selected")
            }
        }
    }
}

struct ProviderKeyCard: View {
    let mode: TipTourMode
    var onKeyChanged: () -> Void = {}
    private var title: String { mode == .jev ? "JEV / TypeSafe key" : "\(mode.title) key" }
    private var detail: String { mode.privacySummary }
    private var keyName: String { mode.keyName }
    @State private var input = ""
    @State private var hasSavedKey = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(hasSavedKey ? "Key saved" : "Key needed")
                    .font(.system(size: 11))
                    .foregroundColor(hasSavedKey ? DS.Colors.success : DS.Colors.textTertiary)
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(hasSavedKey ? "Paste a replacement key" : "Paste your API key", text: $input)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(title) API key")
                .onSubmit { save() }
            HStack {
                Button("Save key", action: save)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointerCursor()
                Button("Remove key") {
                    if KeychainStore.delete(forKey: keyName) {
                        hasSavedKey = false
                        input = ""
                        status = "Removed"
                        onKeyChanged()
                    } else {
                        status = "Could not remove the key. Try again."
                    }
                }
                .disabled(!hasSavedKey)
                .pointerCursor()

            }
            if !status.isEmpty {
                Text(status).font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary)
            }
            Text("Stored securely in macOS Keychain.")
                .font(.system(size: 10)).foregroundColor(DS.Colors.textTertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.surface1))
        .onAppear { hasSavedKey = !(KeychainStore.get(forKey: keyName) ?? "").isEmpty }
    }

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.set(trimmed, forKey: keyName) {
            hasSavedKey = true
            input = ""
            status = "Saved"
            onKeyChanged()
        } else {
            status = "Could not save to Keychain. Try again."
        }
    }
}
