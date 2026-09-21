import Foundation
import OSLog

/// Public logs contain routing/status metadata only. Raw diagnostics require
/// an explicit DEBUG launch option and stay in a bounded, private local file.
@MainActor
enum DesktopVoiceTrace {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TipTour", category: "VoiceTask")

    static func event(_ name: String, turnID: String, fields: [String: String] = [:], privateFields: [String: String] = [:]) {
        let publicRecord = encodedEvent(name, turnID: turnID, fields: fields, privateFields: privateFields, includePrivate: false)
        logger.info("\(publicRecord, privacy: .public)")
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "voiceDiagnosticTraceEnabled") else { return }
        let record = encodedEvent(name, turnID: turnID, fields: fields, privateFields: privateFields, includePrivate: true)
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TipTour/VoiceDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("events.jsonl")
            let maximumBytes = 2 * 1024 * 1024
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let size = attributes[.size] as? NSNumber, size.intValue >= maximumBytes {
                let previous = directory.appendingPathComponent("previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: file, to: previous)
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((record + "\n").utf8))
        } catch {
            logger.error("Could not persist the opted-in local voice diagnostic event.")
        }
        #endif
    }

    static func encodedEvent(_ name: String, turnID: String, fields: [String: String],
                             privateFields: [String: String], includePrivate: Bool) -> String {
        var record: [String: Any] = ["event": name, "turn_id": turnID,
            "time": ISO8601DateFormatter().string(from: Date()), "metadata": fields]
        if includePrivate {
            record["diagnostic"] = privateFields.mapValues { String($0.prefix(16_000)) }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
