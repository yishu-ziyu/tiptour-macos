//
//  DelegationNotices.swift
//  TipTour
//
//  Telling the user a hand-off ended while they were not looking. Every
//  sentence is written here from the record, never by the model: which task
//  in which project, what happened, why Her is saying it now, and what a click
//  does. The user can silence one kind of notice ("这类不再提醒"); that rule is a
//  small JSON file kept across restarts and listed in Settings.
//

import Combine
import Foundation
import IOKit.pwr_mgt

/// One kind of hand-off ending, the unit a "这类不再提醒" rule silences.
enum DelegationNoticeCategory: String, Codable, CaseIterable, Sendable {
    case changed
    case noChange
    case failed

    /// Cancelled by the user: they already know, so there is nothing to tell.
    init?(_ outcome: DelegationOutcome) {
        switch outcome {
        case .changed: self = .changed
        case .noChange: self = .noChange
        case .agentFailed: self = .failed
        case .cancelled: return nil
        }
    }

    var displayName: String {
        switch self {
        case .changed: return "做完了、等你决定合不合"
        case .noChange: return "说做完了但没有改动"
        case .failed: return "没做成"
        }
    }
}

struct DelegationNotice: Equatable, Sendable {
    let recordID: UUID?
    let category: DelegationNoticeCategory
    let title: String
    let body: String

    /// `task` is what the user asked for, in their words when there are any.
    init?(recordID: UUID?, receipt: DelegationReceipt, task: String) {
        guard let category = DelegationNoticeCategory(receipt.outcome) else { return nil }
        let tool = receipt.agentTool.displayName
        let project = receipt.workspace.project.name
        let quoted = "「\(Self.clip(task, 30))」"
        self.recordID = recordID
        self.category = category
        switch receipt.outcome {
        case .changed:
            title = "\(tool) 做完了 · \(project)"
            let leftOut = receipt.untrackedFiles.isEmpty ? "" : "另有 \(receipt.untrackedFiles.count) 个新建的文件没提交，合并时不会带上。"
            body = "\(quoted)改了 \(receipt.changedFiles.count) 个文件。\(leftOut)现在告诉你，是因为改动在单独的工作区里，等你决定合不合进项目。点开看改动。"
        case .noChange:
            title = "\(tool) 说做完了，但没有改动 · \(project)"
            let leftovers = receipt.untrackedFiles.isEmpty
                ? "项目里没有任何改动"
                : "没有提交任何改动；它新建的 \(receipt.untrackedFiles.count) 个文件没提交，已随工作区清掉"
            body = "\(quoted)\(leftovers)，这次不算做成。现在告诉你，是免得你以为已经改好了。点开看它的说明。"
        case .agentFailed(let reason):
            title = "\(tool) 没做成 · \(project)"
            body = "\(quoted)停下了：\(Self.clip(reason, 80))。现在告诉你，是因为要你决定重试还是换个做法。点开看原始报错。"
        case .cancelled:
            return nil
        }
    }

    /// What a posted notification carries, so a click or 「这类不再提醒」 finds its way back.
    var userInfo: [String: String] {
        ["category": category.rawValue, "recordID": recordID?.uuidString ?? ""]
    }

    static func decode(userInfo: [AnyHashable: Any]) -> (category: DelegationNoticeCategory, recordID: UUID?)? {
        guard let category = (userInfo["category"] as? String).flatMap(DelegationNoticeCategory.init(rawValue:)) else { return nil }
        return (category, (userInfo["recordID"] as? String).flatMap(UUID.init(uuidString:)))
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count <= limit ? line : String(line.prefix(limit)) + "…"
    }
}

/// Shows notices to the user; the app posts system notifications, tests record them.
@MainActor
protocol DelegationNoticePoster: AnyObject {
    /// Called when a hand-off starts, so permission is asked when it matters.
    /// False when the user has turned notifications off for Her.
    func prepare() async -> Bool
    func post(_ notice: DelegationNotice)
    /// Takes an already shown notice away once the user has dealt with it.
    func withdraw(_ recordID: UUID)
}

/// The kinds of notice the user silenced, in one file they can open.
@MainActor
final class DelegationNoticeRules: ObservableObject {
    struct Rule: Codable, Equatable, Sendable {
        let category: DelegationNoticeCategory
        let createdAt: Date
        /// The hand-off whose notice the user silenced from, if any.
        let sourceRecordID: UUID?
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Her/notice-rules.json")
    }

    private let fileURL: URL
    @Published private(set) var rules: [Rule] = []
    /// Set when the file exists but could not be read or moved aside; the
    /// rules then live in memory only, so nothing the user wrote is lost.
    private var isReadOnly = false

    /// A file that cannot be decoded is moved aside, never overwritten.
    init(fileURL: URL) {
        self.fileURL = fileURL
        reload()
    }

    /// Reads the file first, so a rule the user removed by hand stops applying at once.
    func silences(_ category: DelegationNoticeCategory) -> Bool {
        reload()
        return rules.contains { $0.category == category }
    }

    func silence(_ category: DelegationNoticeCategory, from recordID: UUID? = nil) {
        reload()
        guard !silences(category) else { return }
        rules.append(Rule(category: category, createdAt: Date(), sourceRecordID: recordID))
        save()
    }

    func restore(_ category: DelegationNoticeCategory) {
        reload()
        rules.removeAll { $0.category == category }
        save()
    }

    /// Reads the file again first, so an edit the user made by hand is kept.
    private func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            isReadOnly = true
            return
        }
        do {
            rules = try Self.decoder.decode([Rule].self, from: data)
        } catch {
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
            do {
                try FileManager.default.moveItem(at: fileURL, to: aside)
            } catch {
                isReadOnly = true
            }
        }
    }

    private func save() {
        guard !isReadOnly else {
            print("DelegationNoticeRules: \(fileURL.path) could not be read; keeping rules in memory only")
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(rules).write(to: fileURL, options: .atomic)
        } catch {
            print("DelegationNoticeRules: could not save \(fileURL.path): \(error.localizedDescription)")
        }
    }

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

/// Keeps the Mac from idle sleep while a hand-off runs, and only then.
@MainActor
protocol DelegationKeepAwake: AnyObject {
    func begin(reason: String)
    func end()
}

@MainActor
final class SystemKeepAwake: DelegationKeepAwake {
    private var assertion: IOPMAssertionID?

    func begin(reason: String) {
        guard assertion == nil else { return }
        var id = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess {
            assertion = id
        }
    }

    func end() {
        guard let assertion else { return }
        IOPMAssertionRelease(assertion)
        self.assertion = nil
    }
}
