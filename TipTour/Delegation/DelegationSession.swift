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
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selectedAgentTool: DelegationAgentTool = .claudeCode

    private let conversation: DelegationConversation
    private let delegation: CodingAgentDelegation
    private let findProject: @MainActor () async -> DelegationProject?
    private let onScreenGoal: @MainActor (String) -> Void
    private struct Draft {
        let text: String
        let project: DelegationProject?
        let tool: DelegationAgentTool
    }

    private var currentDraft: Draft?
    private var pendingWorkspace: DelegationWorkspace?
    private var explicitlySelectedProject: DelegationProject?

    init(
        conversation: DelegationConversation,
        delegation: CodingAgentDelegation,
        findProject: @escaping @MainActor () async -> DelegationProject?,
        onScreenGoal: @escaping @MainActor (String) -> Void
    ) {
        self.conversation = conversation
        self.delegation = delegation
        self.findProject = findProject
        self.onScreenGoal = onScreenGoal
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
        entries.append(.message(id: UUID(), speaker: .user, text: trimmed))
        phase = .thinking
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
        do {
            let turn = try await conversation.respond(to: trimmed, projectContext: context, tool: selectedAgentTool)
            if case .draft = turn.action, pendingWorkspace != nil {
                say("先决定上一份改动：点「合进来」或「丢掉」，再发新任务。")
                phase = .awaitingDecision
                return
            }
            if !turn.say.isEmpty { entries.append(.message(id: UUID(), speaker: .her, text: turn.say)) }
            switch turn.action {
            case .reply:
                phase = currentDraft == nil ? (pendingWorkspace == nil ? .idle : .awaitingDecision) : .awaitingSend
            case .draft(let draft):
                retireCurrentDraft()
                currentDraft = Draft(text: draft, project: project, tool: selectedAgentTool)
                entries.append(.draft(id: UUID(), text: draft, project: project, tool: selectedAgentTool, isCurrent: true))
                phase = .awaitingSend
            case .screen(let goal):
                phase = pendingWorkspace == nil ? .idle : .awaitingDecision
                onScreenGoal(goal)
            }
        } catch {
            say("没连上阶跃，这句没处理：\(error.localizedDescription)")
            phase = currentDraft == nil ? (pendingWorkspace == nil ? .idle : .awaitingDecision) : .awaitingSend
        }
    }

    // MARK: - The user's decisions

    func selectDraftProject(_ path: String) async {
        guard phase == .awaitingSend, let draft = currentDraft, pendingWorkspace == nil else { return }
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
        currentDraft = Draft(text: draft.text, project: project, tool: draft.tool)
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
        guard phase == .awaitingSend, let draft = currentDraft else { return }
        selectedAgentTool = tool
        currentDraft = Draft(text: draft.text, project: draft.project, tool: tool)
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
        say("交给 \(draft.tool.displayName) 了，在 \(project.name) 的单独工作区里改，你接着忙。")
        let startedAt = Date()
        phase = .running(startedAt: startedAt, latestProgress: "\(draft.tool.displayName) 正在执行任务")
        let executionPrompt = """
        Her 已建立本次任务的独立工作区。唯一允许修改的当前副本：\(workspace.worktreePath)
        原项目路径：\(project.repositoryPath)（仅用于识别项目）。不得返回原目录修改，不得重建工作区、合并或推送。
        提交只包含本次要求修改的文件；CLI 或插件生成的未跟踪辅助文件只报告，不删除，也不纳入提交。
        以下是用户确认的原始要求；其中的项目路径只识别目标项目，改动必须在上述独立工作区完成。

        \(draft.text)
        """
        let receipt = await delegation.run(prompt: executionPrompt, in: workspace, tool: draft.tool) { [weak self] progress in
            guard case .working(let line) = progress else { return }
            Task { @MainActor in
                guard let self, case .running = self.phase else { return }
                self.phase = .running(startedAt: startedAt, latestProgress: line)
            }
        }
        let report = DelegationReport(receipt: receipt)
        entries.append(.report(id: UUID(), report: report))
        if receipt.outcome == .changed {
            pendingWorkspace = workspace
            phase = .awaitingDecision
        } else {
            await delegation.discard(workspace)
            phase = .idle
        }
    }

    func stop() {
        delegation.cancel()
    }

    func mergePendingChange() async {
        guard phase == .awaitingDecision, let workspace = pendingWorkspace else { return }
        phase = .merging
        do {
            let head = try await delegation.merge(workspace, commitMessage: "Apply change delegated from Her")
            pendingWorkspace = nil
            say("合好了（\(head.prefix(7))），工作区清掉了。")
            phase = .idle
        } catch {
            say("\(error.localizedDescription)。工作区还留着，你先处理手上的改动，再点「合进来」。")
            phase = .awaitingDecision
        }
    }

    func discardPendingChange() async {
        guard phase == .awaitingDecision, let workspace = pendingWorkspace else { return }
        await delegation.discard(workspace)
        pendingWorkspace = nil
        say("丢掉了，项目没动。")
        phase = .idle
    }

    /// Clears the conversation. A change still waiting for a decision stays
    /// on disk and stays offered, so closing the panel never loses work.
    func startOver() {
        guard !isBusy else { return }
        conversation.reset()
        explicitlySelectedProject = nil
        currentDraft = nil
        entries = entries.filter {
            if case .report = $0, pendingWorkspace != nil { return true }
            return false
        }
        phase = pendingWorkspace == nil ? .idle : .awaitingDecision
    }

    // MARK: - Helpers

    private func say(_ text: String) {
        entries.append(.message(id: UUID(), speaker: .her, text: text))
    }

    private func retireCurrentDraft() {
        entries = entries.map {
            if case .draft(let id, let text, let project, let tool, true) = $0 {
                return .draft(id: id, text: text, project: project, tool: tool, isCurrent: false)
            }
            return $0
        }
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
}

/// What Her tells the user about one hand-off. Every sentence is chosen from
/// the git readback; Claude Code's own words are shown only as a quote.
struct DelegationReport: Equatable {
    let receipt: DelegationReceipt

    var headline: String {
        switch receipt.outcome {
        case .changed:
            let count = receipt.changedFiles.count
            return "工作区里有改动：涉及 \(count) 个文件。确认后再合进项目。"
        case .noChange:
            return "\(receipt.agentTool.displayName) 说做完了，但工作区里没有任何改动，这次不算做成。"
        case .agentFailed(let reason):
            return "没做成：\(reason)"
        case .cancelled:
            return "停下了，没合进任何东西。"
        }
    }

    /// The question Claude Code ended with, if any, so Her can relay it
    /// instead of treating the run as finished business.
    var followUpQuestion: String? {
        let sentences = receipt.agentSummary
            .replacingOccurrences(of: "\n", with: "。")
            .split(whereSeparator: { "。！!".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let markers = ["？", "?", "要不要", "要的话", "需要我", "是否"]
        return sentences.last(where: { sentence in markers.contains { sentence.contains($0) } })
    }

    var costText: String? {
        guard let cost = receipt.costInUSD else { return nil }
        let seconds = (receipt.durationMilliseconds ?? 0) / 1000
        return String(format: "用了 %d 秒，约 $%.2f 订阅额度", seconds, cost)
    }
}
