//
//  DelegationConversationLog.swift
//  TipTour
//
//  Ctrl+K's conversation on disk, one JSON line per entry, only ever
//  appended: `~/Library/Application Support/Her/ctrlk-conversation.jsonl`.
//  After a restart the panel shows it again and the model gets its last turns.
//

import Foundation

@MainActor
final class DelegationConversationLog {
    struct Line: Codable, Equatable {
        enum Kind: String, Codable {
            case user
            /// The model's own reply.
            case her
            /// A sentence the app wrote (receipts, merges, refusals).
            case app
            case draft
            case report
            /// 「重新开始」: what came before is not shown again.
            case startOver
        }

        let id: UUID
        let at: Date
        let kind: Kind
        var text: String? = nil
        var projectPath: String? = nil
        var tool: String? = nil
        var report: DelegationReport? = nil
    }

    nonisolated static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Her/ctrlk-conversation.jsonl")
    }

    let fileURL: URL

    init(fileURL: URL = DelegationConversationLog.defaultFileURL) {
        self.fileURL = fileURL
    }

    func append(_ line: Line) {
        do {
            var data = try Self.encoder.encode(line)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            print("DelegationConversationLog: could not append to \(fileURL.path): \(error.localizedDescription)")
        }
    }

    /// The newest `limit` lines since the last 「重新开始」. A line that cannot
    /// be decoded is skipped; the file itself is never rewritten or moved.
    func restore(limit: Int = 50) -> [Line] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let lines = data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(Line.self, from: Data($0)) }
        let sinceStartOver = lines.lastIndex { $0.kind == .startOver }.map { Array(lines[($0 + 1)...]) } ?? lines
        return Array(sinceStartOver.suffix(limit))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
