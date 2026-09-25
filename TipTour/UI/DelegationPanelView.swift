import SwiftUI

/// The Ctrl+K conversation with Her: talk, review her draft for Claude Code,
/// watch it work, then merge or discard what it changed.
struct DelegationPanelView: View {
    @ObservedObject var session: DelegationSession
    @ObservedObject var companionManager: CompanionManager
    @FocusState private var isInputFocused: Bool
    @State private var inputText: String = ""
    @State private var transcriptContentHeight: CGFloat = 0

    static let width: CGFloat = 440
    static let maximumHeight: CGFloat = 540

    /// The panel grows with the conversation instead of opening at full
    /// height around two short lines; past the maximum the transcript scrolls.
    private var panelHeight: CGFloat {
        guard !session.entries.isEmpty else { return TextCommandPanelManager.baseHeight }
        let headerHeight: CGFloat = 34
        let runningRowHeight: CGFloat = { if case .running = session.phase { return 34 }; return 0 }()
        let inputHeight: CGFloat = companionManager.textCommandActivityText?.isEmpty == false ? 64 : 46
        let natural = headerHeight + transcriptContentHeight + 16 + runningRowHeight + inputHeight
        return min(Self.maximumHeight, max(TextCommandPanelManager.baseHeight, natural))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !session.entries.isEmpty {
                header
                transcript
                Rectangle().fill(DS.Colors.borderSubtle.opacity(0.6)).frame(height: 0.5)
            }
            if case .running(let startedAt, let latestProgress) = session.phase {
                RunningRow(startedAt: startedAt, latestProgress: latestProgress) { session.stop() }
            }
            inputRow
        }
        .frame(width: Self.width, height: panelHeight, alignment: .bottomLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.background.opacity(0.97))
                .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.8)
        )
        .onExitCommand { companionManager.dismissTextCommandPanel() }
        .onAppear {
            companionManager.resizeConversationPanel(height: panelHeight, hasEntries: !session.entries.isEmpty)
            DispatchQueue.main.async { isInputFocused = true }
        }
        .onChange(of: panelHeight) { _, height in
            companionManager.resizeConversationPanel(height: height, hasEntries: !session.entries.isEmpty)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            if !session.isBusy {
                Button("新对话") { session.startOver() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .pointerCursor()
                    .help("清空这段对话（等你决定的改动会保留）")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var statusText: String {
        switch session.phase {
        case .idle: return "在听"
        case .thinking: return "在想"
        case .awaitingSend: return "草稿等你确认"
        case .running: return "Claude Code 在干活"
        case .awaitingDecision: return "改好了，等你决定"
        case .merging: return "在合并"
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .awaitingSend, .awaitingDecision: return DS.Colors.warning
        case .running, .thinking, .merging: return DS.Colors.accent
        case .idle: return DS.Colors.textTertiary
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.entries) { entry in
                        entryView(entry).id(entry.id)
                    }
                    if session.phase == .thinking {
                        Text("…")
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textTertiary)
                            .id("thinking")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                })
            }
            .onPreferenceChange(TranscriptHeightKey.self) { transcriptContentHeight = $0 }
            .onChange(of: session.entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(session.entries.last?.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: DelegationSession.Entry) -> some View {
        switch entry {
        case .message(_, let speaker, let text):
            MessageBubble(text: text, isUser: speaker == .user)
        case .draft(_, let text, let isCurrent):
            DraftCard(text: text, isCurrent: isCurrent && session.phase == .awaitingSend,
                      onSend: { Task { await session.sendCurrentDraft() } },
                      onRevise: { isInputFocused = true })
        case .report(let id, let report):
            ReportCard(report: report,
                       isAwaitingDecision: session.phase == .awaitingDecision && isLatestReport(id),
                       onMerge: { Task { await session.mergePendingChange() } },
                       onDiscard: { Task { await session.discardPendingChange() } })
        }
    }

    private func isLatestReport(_ id: UUID) -> Bool {
        session.entries.last(where: { if case .report = $0 { return true }; return false })?.id == id
    }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "command")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16, height: 16)
                TextField(placeholder, text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isInputFocused)
                    .disabled(session.isBusy)
                    .onSubmit(submit)
            }
            if let activity = companionManager.textCommandActivityText, !activity.isEmpty {
                Text(activity)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 25)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
    }

    private var placeholder: String {
        switch session.phase {
        case .awaitingSend: return "要改草稿就直接说"
        case .awaitingDecision: return "有什么想问的，或者先决定合不合"
        default: return "跟她说要做什么"
        }
    }

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task { await session.send(text) }
    }
}

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MessageBubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(isUser ? DS.Colors.textPrimary : DS.Colors.textPrimary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser ? DS.Colors.accentSubtle : DS.Colors.surface2)
                )
            if !isUser { Spacer(minLength: 48) }
        }
    }
}

private struct DraftCard: View {
    let text: String
    let isCurrent: Bool
    let onSend: () -> Void
    let onRevise: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isCurrent ? "要交给 Claude Code 的内容" : "之前的草稿")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(isCurrent ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: isCurrent ? 170 : 44)
            if isCurrent {
                HStack(spacing: 8) {
                    CardButton(title: "发出去", isPrimary: true, action: onSend)
                    CardButton(title: "再改改", isPrimary: false, action: onRevise)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(isCurrent ? DS.Colors.warning.opacity(0.55) : DS.Colors.borderSubtle, lineWidth: 0.8))
    }
}

private struct ReportCard: View {
    let report: DelegationReport
    let isAwaitingDecision: Bool
    let onMerge: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.headline)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !report.receipt.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.receipt.changedFiles.prefix(6), id: \.self) { file in
                        Text(file)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if report.receipt.changedFiles.count > 6 {
                        Text("还有 \(report.receipt.changedFiles.count - 6) 个文件")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }
            if let question = report.followUpQuestion {
                Text("它最后问你：\(question)")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !report.receipt.agentSummary.isEmpty {
                Text("Claude Code 说：\(report.receipt.agentSummary)")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if let costText = report.costText {
                Text(costText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            if isAwaitingDecision {
                HStack(spacing: 8) {
                    CardButton(title: "合进来", isPrimary: true, action: onMerge)
                    CardButton(title: "丢掉", isPrimary: false, action: onDiscard)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(report.receipt.outcome == .changed ? DS.Colors.success.opacity(0.45) : DS.Colors.borderSubtle,
                    lineWidth: 0.8))
    }
}

private struct RunningRow: View {
    let startedAt: Date
    let latestProgress: String
    let onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(latestProgress)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("\(Int(context.date.timeIntervalSince(startedAt))) 秒")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                Button(action: onStop) { Image(systemName: "stop.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                    .help("让 Claude Code 停下")
                    .accessibilityLabel("停下")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

private struct CardButton: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isPrimary ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isPrimary ? DS.Colors.accentSubtle.opacity(isHovered ? 1 : 0.8)
                                        : DS.Colors.surface3.opacity(isHovered ? 1 : 0.7))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}
