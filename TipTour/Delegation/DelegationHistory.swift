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

    /// Loads the file. A record still `running` belongs to an earlier launch
    /// that quit mid-task, so it becomes `interrupted`. A file that cannot be
    /// read is moved aside, never overwritten.
    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            records = try Self.decoder.decode([DelegationRecord].self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return
        }
        if records.contains(where: { $0.result == .running }) {
            records = records.map {
                var record = $0
                if record.result == .running { record.result = .interrupted }
                return record
            }
            save()
        }
    }

    func begin(userWords: [String], draft: String, project: DelegationProject, tool: DelegationAgentTool) -> UUID {
        let record = DelegationRecord(
            id: UUID(), sentAt: Date(), userWords: userWords, draft: draft,
            projectPath: project.repositoryPath, tool: tool.rawValue,
            result: .running, failure: nil, agentSummary: nil, changedFiles: [], decision: nil)
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
            record.changedFiles = receipt.changedFiles
        }
    }

    func decide(_ id: UUID, _ decision: DelegationRecord.Decision) {
        update(id) { $0.decision = decision }
    }

    /// The newest records, newest first, as the conversation sees them.
    func promptText(limit: Int = 5) -> String {
        let recent = records.suffix(limit).reversed()
        guard !recent.isEmpty else { return "（还没有记录）" }
        return recent.enumerated().map { index, record in
            let tool = DelegationAgentTool(rawValue: record.tool)?.displayName ?? record.tool
            let project = URL(fileURLWithPath: record.projectPath).lastPathComponent
            var lines = ["\(index + 1). \(Self.timeFormatter.string(from: record.sentAt)) · 项目 \(project)（\(record.projectPath)）· \(tool)"]
            if !record.userWords.isEmpty {
                lines.append("   用户原话：" + record.userWords.map { Self.clip($0, 300) }.joined(separator: " / "))
            }
            lines.append("   草稿：" + Self.clip(record.draft, 800))
            lines.append("   结果：" + Self.resultText(record))
            if let decision = record.decision {
                lines.append("   用户决定：" + (decision == .merged ? "已合进项目" : "已丢掉"))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func update(_ id: UUID, _ change: (inout DelegationRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        save()
    }

    private func save() {
        records = Array(records.suffix(Self.keptCount))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            print("DelegationHistory: could not save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    private static func resultText(_ record: DelegationRecord) -> String {
        switch record.result {
        case .running: return "正在执行，还没有结果"
        case .interrupted: return "没有收到结果：执行期间 Her 被关掉了"
        case .changed:
            let files = record.changedFiles.prefix(10).joined(separator: "、")
            return "改了 \(record.changedFiles.count) 个文件（\(files)）" + summaryText(record)
        case .noChange: return "说做完了，但没有任何改动，不算做成" + summaryText(record)
        case .failed: return "没做成。原始报错：" + clip(record.failure ?? "", 600)
        case .cancelled: return "用户停下了，没合进任何东西"
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
