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
        case draft(id: UUID, text: String, isCurrent: Bool)
        case report(id: UUID, report: DelegationReport)

        var id: UUID {
            switch self {
            case .message(let id, _, _), .draft(let id, _, _), .report(let id, _): return id
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case thinking
        case awaitingSend
        case running(startedAt: Date, latestProgress: String)
        case awaitingDecision
        case merging
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var phase: Phase = .idle

    private let conversation: DelegationConversation
    private let delegation: CodingAgentDelegation
    private let findProject: @MainActor () async -> DelegationProject?
    private let onScreenGoal: @MainActor (String) -> Void
    private var currentDraft: String?
    private var pendingWorkspace: DelegationWorkspace?

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
        case .thinking, .running, .merging: return true
        case .idle, .awaitingSend, .awaitingDecision: return false
        }
    }

    // MARK: - Talking

    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        entries.append(.message(id: UUID(), speaker: .user, text: trimmed))
        phase = .thinking
        let project = await findProject()
        let context = await Self.projectContext(for: project)
        do {
            let turn = try await conversation.respond(to: trimmed, projectContext: context)
            if !turn.say.isEmpty { entries.append(.message(id: UUID(), speaker: .her, text: turn.say)) }
            switch turn.action {
            case .reply:
                phase = currentDraft == nil ? (pendingWorkspace == nil ? .idle : .awaitingDecision) : .awaitingSend
            case .draft(let draft):
                retireCurrentDraft()
                currentDraft = draft
                entries.append(.draft(id: UUID(), text: draft, isCurrent: true))
                phase = .awaitingSend
            case .screen(let goal):
                phase = .idle
                onScreenGoal(goal)
            }
        } catch {
            say("没连上阶跃，这句没处理：\(error.localizedDescription)")
            phase = currentDraft == nil ? .idle : .awaitingSend
        }
    }

    // MARK: - The user's decisions

    /// The user pressed 「发出去」. Only here does anything reach Claude Code.
    func sendCurrentDraft() async {
        guard phase == .awaitingSend, let draft = currentDraft else { return }
        guard let project = await findProject() else {
            say("没找到你最近用 Claude Code 的项目。先在要改的项目里用一次 Claude Code，我就能认出来。")
            return
        }
        retireCurrentDraft()
        currentDraft = nil
        let workspace: DelegationWorkspace
        do {
            workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "task")
        } catch {
            say("没能建好工作区：\(error.localizedDescription)")
            phase = .idle
            return
        }
        say("交给 Claude Code 了，在 \(project.name) 的单独工作区里改，你接着忙。")
        let startedAt = Date()
        phase = .running(startedAt: startedAt, latestProgress: "Claude Code 正在读项目")
        let receipt = await delegation.run(prompt: draft, in: workspace) { [weak self] progress in
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
            let head = try await delegation.merge(workspace, commitMessage: "Apply Claude Code change delegated from Her")
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
            if case .draft(let id, let text, true) = $0 { return .draft(id: id, text: text, isCurrent: false) }
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
            return "改好了：动了 \(count) 个文件。差异在下面，要合进来吗？"
        case .noChange:
            return "Claude Code 说做完了，但工作区里没有任何改动，这次不算做成。"
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
