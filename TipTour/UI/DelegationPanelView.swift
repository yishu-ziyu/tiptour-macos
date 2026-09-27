import SwiftUI
import UniformTypeIdentifiers

/// The Ctrl+K conversation with Her: talk, review the task draft,
/// watch it work, then merge or discard what it changed.
struct DelegationPanelView: View {
    @ObservedObject var session: DelegationSession
    @ObservedObject var companionManager: CompanionManager
    @FocusState private var isInputFocused: Bool
    @State private var inputText: String = ""
    @State private var isChoosingProject = false
    @State private var projectSelectionError: String?
    static let width: CGFloat = 560
    static let preferredHeight: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(ConversationColors.border)
            if session.entries.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("在这里。")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("今天想一起做什么？")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                transcript
            }
            if case .running(let startedAt, let latestProgress) = session.phase {
                RunningRow(startedAt: startedAt, latestProgress: latestProgress) { session.stop() }
            }
            inputRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConversationColors.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ConversationColors.border, lineWidth: 1)
        )
        .tint(ConversationColors.accent)
        .onExitCommand { companionManager.dismissTextCommandPanel() }
        .onAppear {
            companionManager.resizeConversationPanel(height: Self.preferredHeight, hasEntries: !session.entries.isEmpty)
            DispatchQueue.main.async { isInputFocused = true }
        }
        .onChange(of: companionManager.textCommandFocusRequest) { _, _ in
            isInputFocused = false
            DispatchQueue.main.async { isInputFocused = !session.isBusy }
        }
        .fileImporter(isPresented: $isChoosingProject, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                Task { await session.selectDraftProject(url.path) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    projectSelectionError = error.localizedDescription
                }
            }
        }
        .fileDialogConfirmationLabel("选择项目")
        .alert("无法选择项目", isPresented: Binding(
            get: { projectSelectionError != nil },
            set: { if !$0 { projectSelectionError = nil } }
        )) {
            Button("好") { projectSelectionError = nil }
        } message: {
            Text(projectSelectionError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ConversationPanelDragRegion()
                .overlay(alignment: .leading) {
                    HStack(spacing: 12) {
                        Text(companionManager.companionName.isEmpty ? "Her" : companionManager.companionName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                        Text(statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help("拖动窗口")
            if !session.isBusy {
                PanelIconButton(symbol: "square.and.pencil", title: "新对话") { session.startOver() }
            }
            PanelIconButton(symbol: "xmark", title: "收起") { companionManager.dismissTextCommandPanel() }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 54)
    }

    private var statusText: String {
        switch session.phase {
        case .idle: return "在听"
        case .thinking: return "在想"
        case .awaitingSend: return "草稿等你确认"
        case .choosingProject: return "在核对目标项目"
        case .preparing: return "在准备工作区"
        case .running: return "\(session.selectedAgentTool.displayName) 在干活"
        case .awaitingDecision: return "有改动，等你决定"
        case .merging: return "在合并"
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .awaitingSend, .awaitingDecision: return ConversationColors.warning
        case .choosingProject, .preparing, .running, .thinking, .merging: return ConversationColors.accent
        case .idle: return Color(nsColor: .systemGreen)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(session.entries) { entry in
                        entryView(entry).id(entry.id)
                    }
                    if session.phase == .thinking {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("在想").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: session.entries.count) { _, _ in
                proxy.scrollTo(session.entries.last?.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: DelegationSession.Entry) -> some View {
        switch entry {
        case .message(_, let speaker, let text):
            MessageBubble(text: text, isUser: speaker == .user)
        case .draft(_, let text, let project, let tool, let isCurrent):
            DraftCard(text: text, project: project, tool: tool, isCurrent: isCurrent,
                      canSend: isCurrent && session.phase == .awaitingSend,
                      onSelectTool: { session.selectAgentTool($0) },
                      onChooseProject: { isChoosingProject = true },
                      onSend: { Task { await session.sendCurrentDraft() } },
                      onRevise: { isInputFocused = true })
        case .report(let id, let report):
            ReportCard(report: report,
                       isSuperseded: isSuperseded(id, report),
                       isAwaitingDecision: session.phase == .awaitingDecision && isLatestReport(id),
                       onMerge: { Task { await session.mergePendingChange() } },
                       onDiscard: { Task { await session.discardPendingChange() } })
        }
    }

    /// A later receipt for the same workspace replaces this one.
    private func isSuperseded(_ id: UUID, _ report: DelegationReport) -> Bool {
        guard let index = session.entries.firstIndex(where: { $0.id == id }) else { return false }
        return session.entries[(index + 1)...].contains { entry in
            if case .report(_, let later) = entry {
                return later.receipt.workspace.worktreePath == report.receipt.workspace.worktreePath
            }
            return false
        }
    }

    private func isLatestReport(_ id: UUID) -> Bool {
        session.entries.last(where: { if case .report = $0 { return true }; return false })?.id == id
    }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField(placeholder, text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1...4)
                    .padding(.vertical, 6)
                    .focused($isInputFocused)
                    .disabled(session.isBusy)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(canSubmit ? ConversationColors.accent : ConversationColors.border, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .pointerCursor()
                .help("发送")
                .accessibilityLabel("发送")
            }
            .padding(12)
            .background(ConversationColors.input, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                isInputFocused ? ConversationColors.accent.opacity(0.55) : ConversationColors.border, lineWidth: 1))
            if let activity = companionManager.textCommandActivityText, !activity.isEmpty {
                Text(activity)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var canSubmit: Bool {
        !session.isBusy && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        guard canSubmit else { return }
        inputText = ""
        Task { await session.send(text) }
    }
}

private enum ConversationColors {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let input = Color(nsColor: .textBackgroundColor)
    static let border = Color.primary.opacity(0.10)
    static let accent = Color(nsColor: .systemBlue)
    static let warning = Color(nsColor: .systemOrange)
}

private struct PanelIconButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(isHovered ? ConversationColors.border : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct MessageBubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 64) }
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, isUser ? 13 : 0)
                .padding(.vertical, isUser ? 10 : 2)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isUser ? ConversationColors.accent.opacity(0.08) : Color.clear)
                )
            if !isUser { Spacer(minLength: 20) }
        }
    }
}

private struct DraftCard: View {
    let text: String
    let project: DelegationProject?
    let tool: DelegationAgentTool
    let isCurrent: Bool
    let canSend: Bool
    let onSelectTool: (DelegationAgentTool) -> Void
    let onChooseProject: () -> Void
    let onSend: () -> Void
    let onRevise: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isCurrent ? "要交给 \(tool.displayName) 的内容" : "之前的草稿 · \(tool.displayName)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if isCurrent {
                Picker("执行工具", selection: Binding(get: { tool }, set: onSelectTool)) {
                    ForEach(DelegationAgentTool.allCases, id: \.self) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(!canSend)
                .pointerCursor()
                .accessibilityLabel("执行工具")
                Text(tool == .codex ? "模型：GPT-6 Luna · High" : "模型：跟随 \(tool.displayName) 配置")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let project {
                    Label(project.name, systemImage: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                } else {
                    Label("尚未确定项目", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(ConversationColors.warning)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Button(action: onChooseProject) {
                        Label(project == nil ? "选择项目" : "更换项目", systemImage: "folder.badge.gearshape")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canSend)
                    .pointerCursor()
                    .help("选择这份草稿实际使用的 Git 项目")
                }
            }
            if let project {
                Text(project.repositoryPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineSpacing(4)
                .lineLimit(isCurrent ? nil : 2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent {
                HStack(spacing: 8) {
                    CardButton(title: "发出去", isPrimary: true, action: onSend)
                    CardButton(title: "再改改", isPrimary: false, action: onRevise)
                }
                .disabled(!canSend)
            }
        }
        .padding(16)
        .background(ConversationColors.input, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isCurrent ? ConversationColors.accent.opacity(0.28) : ConversationColors.border, lineWidth: 1))
    }
}

private struct ReportCard: View {
    let report: DelegationReport
    let isSuperseded: Bool
    let isAwaitingDecision: Bool
    let onMerge: () -> Void
    let onDiscard: () -> Void
    @State private var showsDiffStat = false

    /// Coding tools answer in Markdown; bold and code spans are shown, not their asterisks.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            card
                .opacity(isSuperseded ? 0.45 : 1)
            if isSuperseded {
                Label("你之前看的那份，已被下面这份取代", systemImage: "arrow.up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { if report.sinceShown != nil { showsDiffStat = true } }
    }

    @ViewBuilder
    private var sinceShownNotice: some View {
        if let title = report.sinceShownTitle, let detail = report.sinceShownDetail {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ConversationColors.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ConversationColors.warning)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ConversationColors.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            sinceShownNotice
            Text(report.headline)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !report.receipt.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.receipt.changedFiles.prefix(6), id: \.self) { file in
                        HStack(spacing: 6) {
                            Text(file)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let note = report.sinceShownNote(for: file) {
                                Text(note)
                                    .font(.system(size: 11))
                                    .foregroundStyle(ConversationColors.warning)
                            }
                        }
                    }
                    if report.receipt.changedFiles.count > 6 {
                        Text("还有 \(report.receipt.changedFiles.count - 6) 个文件")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let question = report.followUpQuestion {
                Text("它最后问你：\(question)")
                    .font(.system(size: 12))
                    .foregroundStyle(ConversationColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !report.receipt.diffStat.isEmpty {
                DisclosureGroup("改动统计", isExpanded: $showsDiffStat) {
                    ScrollView(.horizontal) {
                        Text(report.receipt.diffStat)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if !report.receipt.agentSummary.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.agentSummaryCaption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(Self.inlineMarkdown(report.receipt.agentSummary))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 2)
                }
            }
            if let costText = report.costText {
                Text(costText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if isAwaitingDecision {
                HStack(spacing: 8) {
                    CardButton(title: "合进来", isPrimary: true, action: onMerge)
                    CardButton(title: "丢掉", isPrimary: false, action: onDiscard)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConversationColors.input, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(ConversationColors.border, lineWidth: 1))
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("\(Int(context.date.timeIntervalSince(startedAt))) 秒")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(action: onStop) { Image(systemName: "stop.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .pointerCursor()
                    .help("停止当前执行任务")
                    .accessibilityLabel("停下")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(ConversationColors.accent.opacity(0.05))
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
                .foregroundStyle(isPrimary ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isPrimary ? ConversationColors.accent.opacity(isHovered ? 0.85 : 1)
                                        : Color.primary.opacity(isHovered ? 0.10 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}
