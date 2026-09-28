//
//  DelegationSession.swift
//  TipTour
//
//  One Ctrl+K conversation from the first words to a merged (or discarded)
//  change: talk → draft → the user sends it → Claude Code works in a private
//  worktree → a receipt read back with git → the user merges or discards.
//  Everything Her says about the hand-off itself is a fixed sentence built
//  here from the receipt; the model only talks and drafts.
//

import Combine
import Foundation

@MainActor
final class DelegationSession: ObservableObject {
    enum Speaker: Equatable { case user, her }

    enum Entry: Identifiable, Equatable {
        case message(id: UUID, speaker: Speaker, text: String)
        /// A request for Claude Code; `isCurrent` is false once replaced or sent.
        case draft(id: UUID, text: String, project: DelegationProject?, tool: DelegationAgentTool = .claudeCode, isCurrent: Bool)
        case report(id: UUID, report: DelegationReport)

        var id: UUID {
            switch self {
            case .message(let id, _, _), .draft(let id, _, _, _, _), .report(let id, _): return id
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case thinking
        case awaitingSend
        case choosingProject
        case preparing
        case running(startedAt: Date, latestProgress: String)
        case awaitingDecision
        case merging
    }

    @Published private(set) var entries: [Entry] = []
    /// When each entry appeared, for the time lines between them.
    private(set) var entryTimes: [UUID: Date] = [:]
    /// Entries shown again from before this launch; the panel greys them.
    private(set) var restoredEntryIDs: Set<UUID> = []
    /// When this launch began, if it brought earlier entries back.
    private(set) var restartedAt: Date?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selectedAgentTool: DelegationAgentTool = .claudeCode

    private let conversation: DelegationConversation
    private let delegation: CodingAgentDelegation
    private let findProject: @MainActor () async -> DelegationProject?
    /// Hands a screen goal to JEV; the second argument is called once with
    /// what happened, including when it never started.
    /// Hands a goal to JEV; returns why it did not start, or nil once it has.
    private let onScreenGoal: @MainActor (String, @escaping @MainActor (String) -> Void) -> String?
    private let history: DelegationHistory?
    /// Her's own bundle identifier, used to recognize her source repository.
    private let herBundleIdentifier: String?
    private let noticePoster: DelegationNoticePoster?
    private let noticeRules: DelegationNoticeRules?
    /// Whether the user is looking at the panel right now; then the receipt is enough.
    private let isUserLooking: @MainActor () -> Bool
    private let keepAwake: DelegationKeepAwake?
    private let log: DelegationConversationLog?
    private struct Draft {
        /// The user's words that asked for this task; a notice quotes them.
        let request: String
        /// What the model wrote; the hand-off record keeps only this.
        let body: String
        /// Her's recorded background, put first when the draft is about an earlier hand-off.
        let background: String?
        var project: DelegationProject?
        var tool: DelegationAgentTool
        var text: String { DelegationSession.draftText(body, background: background) }
    }

    private var currentDraft: Draft?
    /// The change waiting for the user, as last shown to them.
    private var pendingReceipt: DelegationReceipt?
    private var pendingWorkspace: DelegationWorkspace? { pendingReceipt?.workspace }
    private var explicitlySelectedProject: DelegationProject?
    /// What the user said since the last hand-off, saved with the next one.
    private var userWordsSinceLastSend: [String] = []
    private var pendingRecordID: UUID?
    /// The record whose receipt is the latest one on screen.
    private var lastReportRecordID: UUID?
    /// Set by 「停止」, so a run the user stopped is never announced.
    private var stopRequested = false
    private var hasToldNoticesAreOff = false

    init(
        conversation: DelegationConversation,
        delegation: CodingAgentDelegation,
        findProject: @escaping @MainActor () async -> DelegationProject?,
        onScreenGoal: @escaping @MainActor (String, @escaping @MainActor (String) -> Void) -> String?,
        history: DelegationHistory? = nil,
        herBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        noticePoster: DelegationNoticePoster? = nil,
        noticeRules: DelegationNoticeRules? = nil,
        isUserLooking: @escaping @MainActor () -> Bool = { false },
        keepAwake: DelegationKeepAwake? = nil,
        log: DelegationConversationLog? = nil
    ) {
        self.conversation = conversation
        self.delegation = delegation
        self.findProject = findProject
        self.onScreenGoal = onScreenGoal
        self.history = history
        self.herBundleIdentifier = herBundleIdentifier
        self.noticePoster = noticePoster
        self.noticeRules = noticeRules
        self.isUserLooking = isUserLooking
        self.keepAwake = keepAwake
        self.log = log
        restoreConversation()
        restorePendingDecision()
    }

    /// What was said before the last quit comes back, greyed, and the model
    /// gets its last turns, so "刚才那个" still means something.
    private func restoreConversation() {
        guard let lines = log?.restore(), !lines.isEmpty else { return }
        for line in lines {
            let entry: Entry
            switch line.kind {
            case .user: entry = .message(id: line.id, speaker: .user, text: line.text ?? "")
            case .her, .app: entry = .message(id: line.id, speaker: .her, text: line.text ?? "")
            case .draft:
                entry = .draft(id: line.id, text: line.text ?? "", project: line.projectPath.map { DelegationProject(repositoryPath: $0) },
                               tool: line.tool.flatMap(DelegationAgentTool.init(rawValue:)) ?? .claudeCode, isCurrent: false)
            case .report:
                guard let report = line.report else { continue }
                entry = .report(id: line.id, report: report)
            case .startOver:
                continue
            }
            entries.append(entry)
            entryTimes[line.id] = line.at
            restoredEntryIDs.insert(line.id)
        }
        restartedAt = Date()
        conversation.restore(lines)
    }

    /// The line shown above an entry: where Her restarted, where the
    /// conversation starts, or where it picks up after a pause; nil otherwise.
    func timeLine(before id: UUID) -> String? {
        guard let index = entries.firstIndex(where: { $0.id == id }), let time = entryTimes[id] else { return nil }
        let previous = index > 0 ? entryTimes[entries[index - 1].id] : nil
        if let restartedAt, index > 0, restoredEntryIDs.contains(entries[index - 1].id), !restoredEntryIDs.contains(id) {
            return "── Her 重启过 · \(Self.timeText(restartedAt, sameDayAs: previous)) ──"
        }
        guard let previous else { return Self.timeText(time, sameDayAs: nil) }
        guard time.timeIntervalSince(previous) >= Self.pauseBeforeTimeLine else { return nil }
        return Self.timeText(time, sameDayAs: previous)
    }

    /// A gap at least this long gets a time line.
    static let pauseBeforeTimeLine: TimeInterval = 5 * 60

    private static func timeText(_ time: Date, sameDayAs previous: Date?) -> String {
        let calendar = Calendar.current
        let clock = time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if let previous, calendar.isDate(time, inSameDayAs: previous) { return clock }
        if calendar.isDateInToday(time) { return "今天 \(clock)" }
        if calendar.isDateInYesterday(time) { return "昨天 \(clock)" }
        let components = calendar.dateComponents([.month, .day], from: time)
        return "\(components.month ?? 0)月\(components.day ?? 0)日 \(clock)"
    }

    /// Every entry goes through here: it gets a time and is kept on disk.
    private func append(_ entry: Entry, as kind: DelegationConversationLog.Line.Kind) {
        let now = Date()
        entries.append(entry)
        entryTimes[entry.id] = now
        var line = DelegationConversationLog.Line(id: entry.id, at: now, kind: kind)
        switch entry {
        case .message(_, _, let text): line.text = text
        case .draft(_, let text, let project, let tool, _):
            line.text = text
            line.projectPath = project?.repositoryPath
            line.tool = tool.rawValue
        case .report(_, let report): line.report = report
        }
        log?.append(line)
    }

    /// A change still waiting for merge or discard when Her last quit comes
    /// back with its buttons, so the decision is never lost to a restart.
    private func restorePendingDecision() {
        guard let (id, receipt, sinceShown) = history?.pendingDecision() else { return }
        pendingReceipt = receipt
        pendingRecordID = id
        lastReportRecordID = id
        if let summary = history?.summary(of: id) {
            say("Her 重启前的这件事还在等你决定：\(summary)。")
        }
        append(.report(id: UUID(), report: DelegationReport(receipt: receipt, sinceShown: sinceShown)), as: .report)
        phase = .awaitingDecision
    }

    var isBusy: Bool {
        switch phase {
        case .thinking, .choosingProject, .preparing, .running, .merging: return true
        case .idle, .awaitingSend, .awaitingDecision: return false
        }
    }

    // MARK: - Talking

    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        append(.message(id: UUID(), speaker: .user, text: trimmed), as: .user)
        userWordsSinceLastSend.append(trimmed)
        phase = .thinking
        // Only a project found from recent use is a guess the model may replace.
        let projectIsGuess = currentDraft == nil && pendingWorkspace == nil && explicitlySelectedProject == nil
        let project: DelegationProject?
        if let currentDraft {
            project = currentDraft.project
        } else if let pendingWorkspace {
            project = pendingWorkspace.project
        } else if let explicitlySelectedProject {
            project = explicitlySelectedProject
        } else {
            project = await findProject()
        }
        let context = await Self.projectContext(for: project)
        let herProject = Self.herOwnProject(bundleIdentifier: herBundleIdentifier,
                                            among: [project?.repositoryPath].compactMap { $0 } + (history?.projectPaths ?? []))
        do {
            let turn = try await conversation.respond(
                to: trimmed, projectContext: context, tool: selectedAgentTool,
                recentHandOffs: history?.promptText() ?? "（还没有记录）",
                herCode: herProject.map { "\($0.name)（\($0.repositoryPath)）" } ?? "（不知道在哪：最近用过的项目里没有 Her 的代码）")
            if case .draft = turn.action, pendingWorkspace != nil {
                say("先决定上一份改动：点「合进来」或「丢掉」，再发新任务。")
                phase = .awaitingDecision
                return
            }
            // A screen reply ("正在点击…") is shown only once the goal has started.
            var isScreen = false
            if case .screen = turn.action { isScreen = true }
            if !turn.say.isEmpty, !isScreen { append(.message(id: UUID(), speaker: .her, text: turn.say), as: .her) }
            switch turn.action {
            case .reply:
                phase = restingPhase
            case .draft(let body):
                // A revision keeps the background of the draft it revises.
                let background = turn.refersTo.flatMap { history?.background(forReference: $0) } ?? currentDraft?.background
                let bound = projectIsGuess ? (chosenProject(for: turn, herProject: herProject) ?? project) : project
                let request = currentDraft?.request ?? turn.refersTo.flatMap { history?.request(forReference: $0) } ?? trimmed
                // Carrying on a change in its own project keeps the tool that made it,
                // unless the user names another. Said aloud, since the picker otherwise
                // shows the last choice.
                if currentDraft == nil, Self.toolAskedFor(in: trimmed) == nil,
                   let reference = turn.refersTo, bound?.repositoryPath == history?.projectPath(forReference: reference),
                   let earlierTool = history?.toolThatMadeChange(forReference: reference), earlierTool != selectedAgentTool {
                    selectedAgentTool = earlierTool
                    say("执行工具沿用那次的 \(earlierTool.displayName)；要换，在草稿的「执行工具」里选。")
                }
                let draft = Draft(request: request, body: body, background: background, project: bound, tool: selectedAgentTool)
                retireCurrentDraft()
                currentDraft = draft
                append(.draft(id: UUID(), text: draft.text, project: bound, tool: selectedAgentTool, isCurrent: true), as: .draft)
                phase = .awaitingSend
                if projectIsGuess, turn.project == .her, herProject == nil, let bound {
                    say("没找到 Her 自己的代码在哪，草稿先绑在 \(bound.name)；发出去前点「更换项目」选 Her 的仓库。")
                }
            case .screen(let goal):
                phase = pendingWorkspace == nil ? .idle : .awaitingDecision
                if let refusal = onScreenGoal(goal, { [weak self] result in self?.screenGoalEnded(result) }) {
                    let line = "没去点：\(refusal)"
                    say(line)
                    conversation.noteAppEvent(line)
                } else if !turn.say.isEmpty {
                    append(.message(id: UUID(), speaker: .her, text: turn.say), as: .her)
                }
            }
            if currentDraft != nil, let reminder = Self.toolReminder(words: trimmed, say: turn.say, selected: selectedAgentTool) {
                say(reminder)
            }
        } catch {
            if (error as? DelegationConversationError)?.isUnusableAnswer == true {
                say("阶跃这次的回答没法用，这句没处理：\(error.localizedDescription)。再说一遍试试。")
            } else {
                say("没连上阶跃，这句没处理：\(error.localizedDescription)")
            }
            phase = restingPhase
        }
    }

    /// The repository the model chose for a draft, when it names one Her can resolve.
    private func chosenProject(for turn: DelegationTurn, herProject: DelegationProject?) -> DelegationProject? {
        switch turn.project {
        case .current: return nil
        case .her: return herProject
        case .record:
            guard let path = turn.refersTo.flatMap({ history?.projectPath(forReference: $0) }),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return DelegationProject(repositoryPath: path)
        }
    }

    /// One notice for a hand-off that ended while the user was not looking,
    /// unless they silenced this kind. A cancelled run is never announced.
    private func tellIfAway(recordID: UUID?, receipt: DelegationReceipt, task: String) {
        guard !stopRequested,
              let notice = DelegationNotice(recordID: recordID, receipt: receipt, task: task),
              noticeRules?.silences(notice.category) != true,
              !isUserLooking() else { return }
        noticePoster?.post(notice)
    }

    /// The user clicked a notice. When its receipt is no longer on screen
    /// (a restart, or 「重新开始」), say from the record what it was about.
    func openNotice(for recordID: UUID?) {
        guard let recordID else { return }
        noticePoster?.withdraw(recordID)
        guard recordID != lastReportRecordID, let summary = history?.summary(of: recordID) else { return }
        say("你点开的是这件事：\(summary)。")
    }

    /// JEV's result, said in the panel and kept where the model will see it,
    /// so "弄好了吗" is answered from what happened, not from her own promise.
    private func screenGoalEnded(_ result: String) {
        let line = "屏幕上那件事：\(result)"
        say(line)
        conversation.noteAppEvent(line)
    }

    /// What voice is told about Ctrl+K, so she can answer "刚才那个任务怎么样了"
    /// from what is here. Read-only: acting on any of it stays in the panel.
    var voiceContext: String {
        var lines: [String] = []
        if let draft = currentDraft {
            let firstLine = draft.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let clipped = firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
            lines.append("当前草稿：「\(clipped)」，项目 \(draft.project?.name ?? "还没选")，执行工具 \(draft.tool.displayName)，还没发出去")
        } else {
            lines.append("当前草稿：没有")
        }
        if let pendingReceipt {
            lines.append("等用户决定的改动（\(pendingReceipt.workspace.project.name)）：\(DelegationReport(receipt: pendingReceipt).headline)")
        } else {
            lines.append("等用户决定的改动：没有")
        }
        if case .running(_, let progress) = phase {
            lines.append("正在执行：\(progress)")
        } else {
            lines.append("正在执行：没有")
        }
        let recent = history?.recentSummaries(3) ?? []
        if recent.isEmpty {
            lines.append("最近交出去的任务：没有记录")
        } else {
            lines.append("最近交出去的任务：")
            lines += recent.enumerated().map { "\($0.offset + 1). \($0.element)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Where the panel rests after a turn: offering the draft, the pending change, or nothing.
    private var restingPhase: Phase {
        currentDraft == nil ? (pendingWorkspace == nil ? .idle : .awaitingDecision) : .awaitingSend
    }

    // MARK: - The user's decisions

    func selectDraftProject(_ path: String) async {
        guard phase == .awaitingSend, currentDraft != nil, pendingWorkspace == nil else { return }
        phase = .choosingProject
        let result = await DelegationCommand.git(["rev-parse", "--show-toplevel"], inDirectory: path)
        let repositoryPath = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitStatus == 0, !repositoryPath.isEmpty else {
            let reason = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            say("没能选择这个项目：\(reason.isEmpty ? "未找到 Git 仓库" : reason)。草稿和原项目都保留着，可以重新选择。")
            phase = .awaitingSend
            return
        }
        let project = DelegationProject(repositoryPath: repositoryPath)
        explicitlySelectedProject = project
        currentDraft?.project = project
        entries = entries.map {
            if case .draft(let id, let text, _, let tool, true) = $0 {
                return .draft(id: id, text: text, project: project, tool: tool, isCurrent: true)
            }
            return $0
        }
        say("目标项目已换成 \(project.name)，草稿还没发出去。")
        phase = .awaitingSend
    }

    func selectAgentTool(_ tool: DelegationAgentTool) {
        guard phase == .awaitingSend, currentDraft != nil else { return }
        selectedAgentTool = tool
        currentDraft?.tool = tool
        entries = entries.map {
            if case .draft(let id, let text, let project, _, true) = $0 {
                return .draft(id: id, text: text, project: project, tool: tool, isCurrent: true)
            }
            return $0
        }
    }

    /// The user pressed 「发出去」. Only here does anything reach the selected tool.
    func sendCurrentDraft() async {
        guard phase == .awaitingSend, let draft = currentDraft else { return }
        guard let project = draft.project else {
            say("这份草稿还没绑定项目，先点「选择项目」指定要改的 Git 仓库，再发出去。")
            return
        }
        phase = .preparing
        let workspace: DelegationWorkspace
        do {
            workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "task")
        } catch {
            say("没能建好工作区：\(error.localizedDescription)")
            phase = .awaitingSend
            return
        }
        retireCurrentDraft()
        currentDraft = nil
        let recordID = history?.begin(userWords: userWordsSinceLastSend, draft: draft.body, project: project,
                                      tool: draft.tool, workspace: workspace)
        userWordsSinceLastSend = []
        stopRequested = false
        say("交给 \(draft.tool.displayName) 了，在 \(project.name) 的单独工作区里改，你接着忙。")
        if let noticePoster, !(await noticePoster.prepare()), !hasToldNoticesAreOff {
            hasToldNoticesAreOff = true
            say("系统通知被关了：这次做完我不会弹提醒，回来看这里就行。要开的话去 系统设置 → 通知 → Her。")
        }
        let startedAt = Date()
        phase = .running(startedAt: startedAt, latestProgress: "\(draft.tool.displayName) 正在执行任务")
        let executionPrompt = """
        Her 已建立本次任务的独立工作区。唯一允许修改的当前副本：\(workspace.worktreePath)
        原项目路径：\(project.repositoryPath)（仅用于识别项目）。不得返回原目录修改，不得重建工作区、合并或推送。
        提交只包含本次要求修改的文件；CLI 或插件生成的未跟踪辅助文件只报告，不删除，也不纳入提交。
        以下是用户确认的原始要求；其中的项目路径只识别目标项目，改动必须在上述独立工作区完成。

        \(draft.text)
        """
        keepAwake?.begin(reason: "Her：\(draft.tool.displayName) 正在执行交给它的任务")
        let receipt = await delegation.run(prompt: executionPrompt, in: workspace, tool: draft.tool) { [weak self] progress in
            guard case .working(let line) = progress else { return }
            Task { @MainActor in
                guard let self, case .running = self.phase else { return }
                self.phase = .running(startedAt: startedAt, latestProgress: line)
            }
        }
        keepAwake?.end()
        if let recordID { history?.finish(recordID, receipt: receipt) }
        tellIfAway(recordID: recordID, receipt: receipt, task: draft.request)
        let report = DelegationReport(receipt: receipt)
        append(.report(id: UUID(), report: report), as: .report)
        lastReportRecordID = recordID
        if receipt.outcome == .changed {
            pendingReceipt = receipt
            pendingRecordID = recordID
            phase = .awaitingDecision
        } else {
            await delegation.discard(workspace)
            phase = .idle
        }
    }

    func stop() {
        stopRequested = true
        delegation.cancel()
    }

    func mergePendingChange() async {
        guard phase == .awaitingDecision, let reviewed = pendingReceipt else { return }
        phase = .merging
        do {
            let head = try await delegation.merge(reviewed, commitMessage: "Apply change delegated from Her")
            pendingReceipt = nil
            if let pendingRecordID {
                history?.decide(pendingRecordID, .merged)
                noticePoster?.withdraw(pendingRecordID)
            }
            pendingRecordID = nil
            say("合好了（\(head.prefix(7))），工作区清掉了。" + Self.uncommittedGone(reviewed))
            phase = .idle
        } catch DelegationError.changedSinceReview(let now) {
            // Only what the user has seen may be merged: show what is there now.
            let sinceShown = DelegationChangeSinceShown(shown: reviewed, now: now)
            pendingReceipt = now
            if let pendingRecordID { history?.reviewAgain(pendingRecordID, receipt: now, sinceShown: sinceShown) }
            say(reviewed.diffDigest.isEmpty
                ? "这份改动是重启前记下的，没法确认你看到的还是不是现在的内容，所以没有合进去。下面是工作区现在的改动，看过再决定。"
                : "你看过之后工作区又变了，没有合进去。下面是现在的改动，看过再决定。")
            append(.report(id: UUID(), report: DelegationReport(receipt: now, sinceShown: sinceShown)), as: .report)
            phase = .awaitingDecision
        } catch DelegationError.branchMoved(let expected, let current) {
            say("任务开始时 \(reviewed.workspace.project.name) 在 \(expected) 分支，现在在 \(current.isEmpty ? "一个没有分支名的提交上" : current + " 分支")，所以没有合进去。切回 \(expected) 再点「合进来」，或者丢掉。")
            phase = .awaitingDecision
        } catch {
            say("\(error.localizedDescription)。工作区还留着，你先处理手上的改动，再点「合进来」。")
            phase = .awaitingDecision
        }
    }

    func discardPendingChange() async {
        guard phase == .awaitingDecision, let receipt = pendingReceipt else { return }
        await delegation.discard(receipt.workspace)
        pendingReceipt = nil
        if let pendingRecordID {
            history?.decide(pendingRecordID, .discarded)
            noticePoster?.withdraw(pendingRecordID)
        }
        pendingRecordID = nil
        say("丢掉了，项目没动。" + Self.uncommittedGone(receipt))
        phase = .idle
    }

    private static func uncommittedGone(_ receipt: DelegationReceipt) -> String {
        receipt.untrackedFiles.isEmpty ? "" : "没提交的 \(DelegationReport.names(receipt.untrackedFiles)) 也随工作区删了，不进废纸篓。"
    }

    /// Clears the conversation. A change still waiting for a decision stays
    /// on disk and stays offered, so closing the panel never loses work.
    func startOver() {
        guard !isBusy else { return }
        conversation.reset()
        explicitlySelectedProject = nil
        userWordsSinceLastSend = []
        currentDraft = nil
        log?.append(DelegationConversationLog.Line(id: UUID(), at: Date(), kind: .startOver))
        restoredEntryIDs = []
        restartedAt = nil
        entries = entries.filter {
            if case .report = $0, pendingWorkspace != nil { return true }
            return false
        }
        phase = pendingWorkspace == nil ? .idle : .awaitingDecision
    }

    // MARK: - Helpers

    private func say(_ text: String) {
        append(.message(id: UUID(), speaker: .her, text: text), as: .app)
    }

    private func retireCurrentDraft() {
        entries = entries.map {
            if case .draft(let id, let text, let project, let tool, true) = $0 {
                return .draft(id: id, text: text, project: project, tool: tool, isCurrent: false)
            }
            return $0
        }
    }

    nonisolated static func draftText(_ body: String, background: String?) -> String {
        background.map { $0 + "\n\n" + body } ?? body
    }

    /// Her's own line naming the tool actually selected, when the user asks for
    /// another one or her reply claims one.
    static func toolReminder(words: String, say: String, selected: DelegationAgentTool) -> String? {
        guard let named = toolAskedFor(in: words) ?? toolAskedFor(in: say), named != selected else { return nil }
        return "现在选的还是 \(selected.displayName)；要用 \(named.displayName)，在草稿的「执行工具」里选。"
    }

    private static let toolRequest = try! Regex("(换成?|改用|改为|改成|选的是|用|让|交给)\\s*(claude|codex|kimi|step code)")
    private static let toolsByName: [String: DelegationAgentTool] = [
        "claude": .claudeCode, "codex": .codex, "kimi": .kimiCode, "step code": .stepCode,
    ]

    /// The coding tool asked for in so many words ("换 Kimi", "执行工具改为 Kimi Code"),
    /// the last one if several. Recalling a past hand-off ("上次用 Codex 那个"),
    /// ruling a tool out ("不用 Codex") or describing a call ("调用 Codex") is not a request.
    static func toolAskedFor(in text: String) -> DelegationAgentTool? {
        DelegationConversation.clausesAboutNow(text.lowercased()).flatMap { clause in
            clause.matches(of: toolRequest).compactMap { match -> DelegationAgentTool? in
                let before = clause[..<match.range.lowerBound]
                guard !before.contains("不"), !before.contains("别"), !before.hasSuffix("调") else { return nil }
                return match.output[2].substring.flatMap { toolsByName[String($0)] }
            }
        }.last
    }

    static func projectContext(for project: DelegationProject?) async -> String {
        guard let project else { return "（还没找到项目：用户最近没有在任何 git 仓库里用过 Claude Code）" }
        let branch = await DelegationCommand.git(["branch", "--show-current"], inDirectory: project.repositoryPath)
        let log = await DelegationCommand.git(["log", "--oneline", "-5"], inDirectory: project.repositoryPath)
        return """
        名字：\(project.name)
        路径：\(project.repositoryPath)
        分支：\(branch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        最近的提交：
        \(log.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// Her's own source repository among `paths`: the first whose Xcode project builds this bundle identifier.
    static func herOwnProject(bundleIdentifier: String?, among paths: [String]) -> DelegationProject? {
        paths.first { buildsApp(bundleIdentifier, at: $0) }.map(DelegationProject.init(repositoryPath:))
    }

    /// Whether an Xcode project at the repository root builds the app with
    /// this bundle identifier, i.e. the repository is Her's own source.
    private static func buildsApp(_ bundleIdentifier: String?, at repositoryPath: String) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: repositoryPath) else { return false }
        return entries.filter { $0.hasSuffix(".xcodeproj") }.contains { name in
            let file = URL(fileURLWithPath: repositoryPath).appendingPathComponent(name).appendingPathComponent("project.pbxproj")
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return text.contains("PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier);")
        }
    }
}

/// How a receipt differs from the one the user saw before it.
enum DelegationChangeSinceShown: Codable, Equatable, Sendable {
    case sameFiles
    case differentFiles(added: [String], removed: [String])
    /// The earlier receipt came from before a restart and had no fingerprint to compare.
    case unverifiable

    init(shown: DelegationReceipt, now: DelegationReceipt) {
        if shown.diffDigest.isEmpty {
            self = .unverifiable
        } else if Set(shown.changedFiles) == Set(now.changedFiles) {
            self = .sameFiles
        } else {
            self = .differentFiles(added: now.changedFiles.filter { !shown.changedFiles.contains($0) },
                                   removed: shown.changedFiles.filter { !now.changedFiles.contains($0) })
        }
    }
}

/// What Her tells the user about one hand-off. Every sentence is chosen from
/// the git readback; Claude Code's own words are shown only as a quote.
struct DelegationReport: Codable, Equatable {
    let receipt: DelegationReceipt
    /// Set when this receipt replaced one the user had already seen.
    var sinceShown: DelegationChangeSinceShown? = nil

    var headline: String {
        switch receipt.outcome {
        case .changed:
            let count = receipt.changedFiles.count
            let target = receipt.workspace.projectBranch.map { " \(receipt.workspace.project.name) 的 \($0) 分支" } ?? "项目"
            let leftOut = receipt.untrackedFiles.isEmpty ? ""
                : "另有 \(receipt.untrackedFiles.count) 个新建但没提交的文件（\(Self.names(receipt.untrackedFiles))），合并时不会带上；合进来或丢掉后都会随工作区删除，不进废纸篓。"
            return "工作区里有改动：涉及 \(count) 个文件。确认后再合进\(target)。" + leftOut
        case .noChange:
            let nothing = receipt.untrackedFiles.isEmpty ? "工作区里没有任何改动" : "没有提交任何改动"
            return "\(receipt.agentTool.displayName) 说做完了，但\(nothing)，这次不算做成。" + deletedWithWorkspace
        case .agentFailed(let reason):
            return "没做成：\(reason)" + deletedWithWorkspace
        case .cancelled:
            return "停下了，没合进任何东西。" + deletedWithWorkspace
        }
    }

    /// The workspace of an unfinished run is removed at once, taking the
    /// tool's uncommitted new files with it.
    private var deletedWithWorkspace: String {
        receipt.untrackedFiles.isEmpty ? "" : "它新建但没提交的 \(Self.names(receipt.untrackedFiles)) 已随工作区删除，不进废纸篓。"
    }

    /// Up to three file names, so the user can tell what is going away.
    static func names(_ files: [String]) -> String {
        let shown = files.prefix(3).joined(separator: "、")
        return files.count > 3 ? "\(shown) 等 \(files.count) 个文件" : shown
    }

    /// The question Claude Code ended with, if any, so Her can relay it
    /// instead of treating the run as finished business. Code spans such as
    /// `?? notes.txt` from `git status` are not questions.
    var followUpQuestion: String? {
        let sentences = receipt.agentSummary
            .replacingOccurrences(of: "\n", with: "。")
            .split(whereSeparator: { "。！!".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let markers = ["？", "?", "要不要", "要的话", "需要我", "是否"]
        return sentences.last(where: { sentence in
            let prose = sentence.replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)
            return markers.contains { prose.contains($0) }
        })
    }

    /// The first line of the notice on a receipt that replaced one the user saw.
    var sinceShownTitle: String? {
        switch sinceShown {
        case nil: return nil
        case .sameFiles, .differentFiles: return "和你上次看到的不一样"
        case .unverifiable: return "没法确认是不是你上次看到的"
        }
    }

    var sinceShownDetail: String? {
        switch sinceShown {
        case nil:
            return nil
        case .sameFiles:
            return "文件还是这 \(receipt.changedFiles.count) 个，里面的改动变了。下面的改动统计是现在的。"
        case .differentFiles(let added, let removed):
            let parts = [added.isEmpty ? nil : "多了 \(Self.names(added))", removed.isEmpty ? nil : "少了 \(Self.names(removed))"]
            return "涉及的文件也变了：\(parts.compactMap { $0 }.joined(separator: "，"))。下面的改动统计是现在的。"
        case .unverifiable:
            return "这份是 Her 重启前记下的，下面是现在工作区的改动。"
        }
    }

    /// A note after a file name, only where it is certain.
    func sinceShownNote(for file: String) -> String? {
        switch sinceShown {
        case .sameFiles where receipt.changedFiles.count == 1: return "内容变了"
        case .differentFiles(let added, _) where added.contains(file): return "新出现"
        default: return nil
        }
    }

    /// Who wrote the quoted summary, and whether it predates what is shown.
    var agentSummaryCaption: String {
        let tool = receipt.agentTool.displayName
        switch sinceShown {
        case nil: return "\(tool) 说"
        case .sameFiles, .differentFiles: return "\(tool) 做完时说 · 写在内容变动之前"
        case .unverifiable: return "\(tool) 做完时说 · 之后内容可能变过"
        }
    }

    var costText: String? {
        guard let cost = receipt.costInUSD else { return nil }
        let seconds = (receipt.durationMilliseconds ?? 0) / 1000
        return String(format: "用了 %d 秒，约 $%.2f 订阅额度", seconds, cost)
    }
}
