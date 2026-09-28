//
//  DelegationHistory.swift
//  TipTour
//
//  What Her remembers about each hand-off: the user's words, the draft, the
//  project, the tool, the result (with the raw failure text) and whether the
//  change was merged or discarded. Kept in one JSON file the user can open,
//  so a restart does not erase it; the newest records go into the
//  conversation so "上次那个" resolves without the user repeating it.
//

import Foundation

struct DelegationRecord: Codable, Equatable, Sendable {
    enum Result: String, Codable, Sendable {
        case running, changed, noChange, failed, cancelled
        /// Her quit while the tool was running, so no result ever came back.
        case interrupted
    }

    enum Decision: String, Codable, Sendable { case merged, discarded }

    let id: UUID
    let sentAt: Date
    let userWords: [String]
    let draft: String
    let projectPath: String
    let tool: String
    var result: Result
    var failure: String?
    var agentSummary: String?
    var changedFiles: [String]
    var decision: Decision?
    /// The receipt headline Her showed the user, word for word. Records
    /// written before this field existed decode it as nil.
    var shownToUser: String?
    /// Where the change was made, so a decision still owed survives a restart.
    var branchName: String? = nil
    var worktreePath: String? = nil
    var baseCommit: String? = nil
    var projectBranch: String? = nil
    /// What the receipt showed, so a receipt rebuilt after a restart shows the
    /// same and a merge can check the workspace still matches it.
    var diffStat: String? = nil
    var untrackedFiles: [String]? = nil
    var diffDigest: String? = nil
    /// Set when the shown receipt replaced an earlier one, so the notice survives a restart.
    var sinceShown: DelegationChangeSinceShown? = nil
}

@MainActor
final class DelegationHistory {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Her/delegation-history.json")
    }

    /// Older records are dropped from the file beyond this.
    static let keptCount = 100

    private let fileURL: URL
    private(set) var records: [DelegationRecord] = []
    /// Set when the file exists but could not be read or moved aside; changes
    /// then stay in memory so nothing the user wrote is overwritten.
    private var isReadOnly = false

    /// Loads the file. A record still `running` belongs to an earlier launch
    /// that quit mid-task, so it becomes `interrupted`. A file that cannot be
    /// read is moved aside, never overwritten.
    init(fileURL: URL) {
        self.fileURL = fileURL
        reload()
        if records.contains(where: { $0.result == .running }) {
            records = records.map {
                var record = $0
                if record.result == .running { record.result = .interrupted }
                return record
            }
            save()
        }
    }

    func begin(userWords: [String], draft: String, project: DelegationProject, tool: DelegationAgentTool,
               workspace: DelegationWorkspace? = nil) -> UUID {
        let record = DelegationRecord(
            id: UUID(), sentAt: Date(), userWords: userWords, draft: draft,
            projectPath: project.repositoryPath, tool: tool.rawValue,
            result: .running, failure: nil, agentSummary: nil, changedFiles: [], decision: nil, shownToUser: nil,
            branchName: workspace?.branchName, worktreePath: workspace?.worktreePath, baseCommit: workspace?.baseCommit,
            projectBranch: workspace?.projectBranch)
        reload()
        records.append(record)
        save()
        return record.id
    }

    func finish(_ id: UUID, receipt: DelegationReceipt) {
        update(id) { record in
            switch receipt.outcome {
            case .changed: record.result = .changed
            case .noChange: record.result = .noChange
            case .agentFailed(let reason): record.result = .failed; record.failure = reason
            case .cancelled: record.result = .cancelled
            }
            let summary = receipt.agentSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            record.agentSummary = summary.isEmpty ? nil : summary
            Self.keepContents(of: receipt, in: &record)
            record.shownToUser = DelegationReport(receipt: receipt).headline
        }
    }

    /// The workspace changed after the user was shown it; keep what is shown now.
    func reviewAgain(_ id: UUID, receipt: DelegationReceipt, sinceShown: DelegationChangeSinceShown) {
        update(id) { record in
            Self.keepContents(of: receipt, in: &record)
            record.sinceShown = sinceShown
            record.shownToUser = DelegationReport(receipt: receipt).headline
        }
    }

    private static func keepContents(of receipt: DelegationReceipt, in record: inout DelegationRecord) {
        record.changedFiles = receipt.changedFiles
        record.diffStat = receipt.diffStat
        record.untrackedFiles = receipt.untrackedFiles
        record.diffDigest = receipt.diffDigest
    }

    func decide(_ id: UUID, _ decision: DelegationRecord.Decision) {
        update(id) { $0.decision = decision }
    }

    /// How many of the newest records the conversation sees.
    private static let promptedCount = 5

    /// The records the conversation sees, newest first; `refers_to` numbers count from 1 in this order.
    private var promptedRecords: [DelegationRecord] { records.suffix(Self.promptedCount).reversed() }

    /// The newest records, newest first, as the conversation sees them.
    func promptText() -> String {
        guard !promptedRecords.isEmpty else { return "（还没有记录）" }
        return promptedRecords.enumerated().map { index, record in
            let project = DelegationProject(repositoryPath: record.projectPath).name
            var lines = ["\(index + 1). \(Self.timeFormatter.string(from: record.sentAt)) · 项目 \(project)（\(record.projectPath)）· \(Self.toolName(record))"]
            if !record.userWords.isEmpty {
                lines.append("   用户原话：" + record.userWords.map { Self.clip($0, 300) }.joined(separator: " / "))
            }
            lines.append("   草稿：" + Self.clip(record.draft, 800))
            lines.append("   结果：" + Self.resultText(record))
            if let shown = Self.shownWords(record) {
                lines.append("   Her 当时在回执里给用户看的原话：「" + Self.clip(shown, 600) + "」")
            }
            if let decision = record.decision {
                lines.append("   用户决定：" + (decision == .merged ? "已合进项目" : "已丢掉"))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// What a draft about one of those records starts with, written from the
    /// record itself so the date, tool and Her's words are exact. `number`
    /// is the record's number in `promptText` (1 = newest).
    /// Short, because the user reads it at the top of the draft; the tool's
    /// own explanation stays out, the repository's history has the detail.
    func background(forNumber number: Int) -> String? {
        guard let record = record(forNumber: number) else { return nil }
        let project = DelegationProject(repositoryPath: record.projectPath).name
        let goal = record.draft.split(whereSeparator: \.isNewline).first.map(String.init) ?? record.draft
        var lines = ["背景：接着 \(Self.timeFormatter.string(from: record.sentAt)) 交给 \(Self.toolName(record)) 的任务（项目 \(project)）：\(Self.clip(goal, 120))",
                     "当时的结果：" + (record.result == .failed ? "没做成" : Self.resultText(record, withToolExplanation: false)) + Self.decisionText(record)]
        // A change that was made needs no quote; what Her said about a run
        // that went wrong may be the very thing the user wants changed.
        if record.result != .changed, let shown = Self.shownWords(record) {
            lines.append("Her 当时给用户看的原话：「\(Self.clip(shown, 600))」")
        }
        return lines.joined(separator: "\n")
    }

    /// The newest change still waiting for the user to merge or discard it,
    /// with its worktree still on disk, rebuilt as the receipt Her showed.
    func pendingDecision() -> (id: UUID, receipt: DelegationReceipt, sinceShown: DelegationChangeSinceShown?)? {
        guard let record = records.last(where: { $0.result == .changed && $0.decision == nil }),
              let branchName = record.branchName, let worktreePath = record.worktreePath, let baseCommit = record.baseCommit,
              FileManager.default.fileExists(atPath: worktreePath) else { return nil }
        let workspace = DelegationWorkspace(project: DelegationProject(repositoryPath: record.projectPath),
                                            branchName: branchName, worktreePath: worktreePath, baseCommit: baseCommit,
                                            projectBranch: record.projectBranch)
        let receipt = DelegationReceipt(workspace: workspace, outcome: .changed, agentSummary: record.agentSummary ?? "",
                                        changedFiles: record.changedFiles, untrackedFiles: record.untrackedFiles ?? [],
                                        diffStat: record.diffStat ?? "",
                                        costInUSD: nil, durationMilliseconds: nil, agentSessionID: nil,
                                        agentTool: DelegationAgentTool(rawValue: record.tool) ?? .claudeCode,
                                        diffDigest: record.diffDigest ?? "")
        return (record.id, receipt, record.sinceShown)
    }

    /// One line about a recorded hand-off, for when its receipt is no longer on screen.
    func summary(of id: UUID) -> String? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        let task = record.userWords.first.map { "「\(Self.clip($0, 30))」" } ?? "那次任务"
        return "\(Self.timeFormatter.string(from: record.sentAt)) 交给 \(Self.toolName(record)) 的\(task)：\(Self.resultText(record, withToolExplanation: false))"
    }

    /// One line each for the newest hand-offs, with the user's decision, for voice.
    func recentSummaries(_ count: Int) -> [String] {
        records.suffix(count).reversed().compactMap { record in
            summary(of: record.id).map { $0 + Self.decisionText(record) }
        }
    }

    /// What the user first said about the record numbered `number` in `promptText`.
    func request(forNumber number: Int) -> String? {
        record(forNumber: number)?.userWords.first
    }

    /// The tool that made the change of the record numbered `number` in
    /// `promptText`; nil when that run changed nothing, since its tool may be why.
    func toolThatMadeChange(forNumber number: Int) -> DelegationAgentTool? {
        record(forNumber: number).flatMap { $0.result == .changed ? DelegationAgentTool(rawValue: $0.tool) : nil }
    }

    /// The repository of the record numbered `number` in `promptText`.
    func projectPath(forNumber number: Int) -> String? {
        record(forNumber: number)?.projectPath
    }

    /// Every repository a hand-off went to, newest first, each once.
    var projectPaths: [String] {
        var seen = Set<String>()
        return records.reversed().map(\.projectPath).filter { seen.insert($0).inserted }
    }

    // MARK: - Helpers

    private func record(forNumber number: Int) -> DelegationRecord? {
        let recent = promptedRecords
        guard number >= 1, number <= recent.count else { return nil }
        return recent[number - 1]
    }

    /// Records written before `shownToUser` existed were failures shown as
    /// "没做成：" plus the raw failure; that historical wording is kept literally.
    private static func shownWords(_ record: DelegationRecord) -> String? {
        record.shownToUser ?? (record.result == .failed ? "没做成：" + (record.failure ?? "") : nil)
    }

    private static func toolName(_ record: DelegationRecord) -> String {
        DelegationAgentTool(rawValue: record.tool)?.displayName ?? record.tool
    }

    /// Reads the file again first, so a record the user edited or deleted by
    /// hand while Her runs is kept that way.
    private func update(_ id: UUID, _ change: (inout DelegationRecord) -> Void) {
        reload()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        save()
    }

    /// A file that cannot be decoded is moved aside, never overwritten.
    private func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            isReadOnly = true
            return
        }
        do {
            records = try Self.decoder.decode([DelegationRecord].self, from: data)
        } catch {
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
            if (try? FileManager.default.moveItem(at: fileURL, to: aside)) == nil { isReadOnly = true }
        }
    }

    private func save() {
        guard !isReadOnly else {
            print("DelegationHistory: \(fileURL.path) could not be read; keeping records in memory only")
            return
        }
        records = Array(records.suffix(Self.keptCount))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            print("DelegationHistory: could not save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    private static func resultText(_ record: DelegationRecord, withToolExplanation: Bool = true) -> String {
        let explanation = withToolExplanation ? summaryText(record) : ""
        switch record.result {
        case .running: return "正在执行，还没有结果"
        case .interrupted: return "没有收到结果：执行期间 Her 被关掉了"
        case .changed:
            let files = record.changedFiles.prefix(10).joined(separator: "、")
            return "改了 \(record.changedFiles.count) 个文件（\(files)）" + explanation
        case .noChange: return "说做完了，但没有任何改动，不算做成" + explanation
        case .failed: return "没做成。原始报错：" + clip(record.failure ?? "", 600)
        case .cancelled: return "用户停下了，没合进任何东西"
        }
    }

    private static func decisionText(_ record: DelegationRecord) -> String {
        switch record.decision {
        case .merged: return "，用户已合进项目"
        case .discarded: return "，用户已丢掉"
        case nil: return ""
        }
    }

    private static func summaryText(_ record: DelegationRecord) -> String {
        guard let summary = record.agentSummary else { return "" }
        return "。执行工具的说明：" + clip(summary, 300)
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
