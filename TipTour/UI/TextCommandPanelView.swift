import SwiftUI

struct TextCommandPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @FocusState private var isInputFocused: Bool
    @State private var commandText: String = ""

    var body: some View {
        if let session = companionManager.delegationSession {
            DelegationPanelView(session: session, companionManager: companionManager)
        } else {
            jevInput
        }
    }

    private var jevInput: some View {
        let activityText = companionManager.textCommandActivityText ?? ""
        let hasActivityText = !activityText.isEmpty

        return Group {

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "command")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16, height: 16)

                TextField("Ask JEV to click something…", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .tint(DS.Colors.textSecondary)
                    .focused($isInputFocused)
                    .disabled(companionManager.isTextCommandRunning)
                    .onSubmit {
                        submitCommand()
                    }
                    .onExitCommand {
                        commandText = ""
                        companionManager.dismissTextCommandPanel()
                    }
                if companionManager.isTextCommandRunning {
                    Button { companionManager.cancelTextCommand() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Stop JEV")
                    .accessibilityLabel("Stop JEV")
                }
            }
            .frame(height: 18)

            ZStack(alignment: .leading) {
                TextCommandActivityTicker(
                    text: activityText,
                    isActive: companionManager.isTextCommandRunning
                )
                .opacity(hasActivityText ? 1 : 0)
            }
            .frame(height: 14)
            .clipped()

            // The Jev loop's live decision. The panel is never dismissed on
            // submit (only Escape dismisses it), so this stays on screen for
            // the whole run.
            if let step = companionManager.jevStep {
                JevStepPanelView(snapshot: step)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(width: 340, height: panelHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.background.opacity(0.96))
                .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.8)
        )
        .animation(.easeInOut(duration: 0.16), value: companionManager.textCommandActivityText)
        .animation(.easeInOut(duration: 0.16), value: companionManager.jevStep)
        .onExitCommand { companionManager.dismissTextCommandPanel() }
        .onChange(of: companionManager.isTextCommandRunning) { _, running in
            isInputFocused = !running
        }
        .onChange(of: companionManager.textCommandFocusRequest) { _, _ in
            isInputFocused = false
            DispatchQueue.main.async {
                isInputFocused = !companionManager.isTextCommandRunning
            }
        }
        .onAppear {
            commandText = ""
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
        }
    }

    private var panelHeight: CGFloat {
        guard let step = companionManager.jevStep else { return TextCommandPanelManager.baseHeight }
        return TextCommandPanelManager.baseHeight + JevStepPanelView.height(for: step)
    }

    private func submitCommand() {
        let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }
        commandText = ""
        companionManager.submitTextCommand(trimmedCommand)
    }
}

private struct TextCommandActivityTicker: View {
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(DS.Colors.textSecondary.opacity(isActive ? 0.82 : 0.42))
                .frame(width: 4, height: 4)

            ZStack(alignment: .leading) {
                Text(text)
                    .id(text)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(
                        .asymmetric(
                            insertion: .opacity,
                            removal: .opacity
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.leading, 25)
        .padding(.trailing, 2)
        .accessibilityElement(children: .combine)
    }
}
