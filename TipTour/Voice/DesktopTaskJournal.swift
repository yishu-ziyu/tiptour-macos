import CryptoKit
import Darwin
import Foundation

/// Recovery metadata only. Goals, labels, input text, keys and images never
/// enter this file. A recovered task is inspectable but cannot execute.
final class DesktopTaskJournal {
    /// One attempt's two-layer facts as persisted for recovery. `verified`
    /// stays a derived compatibility field: only a system read-back is true.
    struct Attempt: Codable {
        let id: String
        let observationID: String
        let revision: Int
        let action: DesktopActionKind
        let targetDigest: String
        var completionPolicy: DesktopStepCompletionPolicy
        var delivery: DesktopActionDelivery
        var outcomeEvidence: DesktopActionOutcomeEvidence

        var verified: Bool { outcomeEvidence == .systemVerified }
        var satisfied: Bool {
            DesktopActionCompletion.isStepSatisfied(policy: completionPolicy, delivery: delivery,
                outcomeEvidence: outcomeEvidence)
        }
        var uncertainEffect: Bool {
            DesktopActionCompletion.isUncertainEffect(policy: completionPolicy, delivery: delivery,
                outcomeEvidence: outcomeEvidence)
        }

        enum CodingKeys: String, CodingKey {
            case id, revision, action, delivery, verified
            case observationID = "observationID"
            case targetDigest = "targetDigest"
            case completionPolicy = "completion_policy"
            case outcomeEvidence = "outcome_evidence"
        }

        init(id: String, observationID: String, revision: Int, action: DesktopActionKind,
             targetDigest: String, completionPolicy: DesktopStepCompletionPolicy,
             delivery: DesktopActionDelivery, outcomeEvidence: DesktopActionOutcomeEvidence) {
            self.id = id
            self.observationID = observationID
            self.revision = revision
            self.action = action
            self.targetDigest = targetDigest
            self.completionPolicy = completionPolicy
            self.delivery = delivery
            self.outcomeEvidence = outcomeEvidence
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            observationID = try values.decode(String.self, forKey: .observationID)
            revision = try values.decode(Int.self, forKey: .revision)
            action = try values.decode(DesktopActionKind.self, forKey: .action)
            targetDigest = try values.decode(String.self, forKey: .targetDigest)
            // A missing delivery cannot be assumed "not sent": unknown keeps
            // the attempt unresolved so the task stays subject to inspection.
            delivery = try values.decodeIfPresent(DesktopActionDelivery.self, forKey: .delivery) ?? .unknown
            if let evidence = try values.decodeIfPresent(DesktopActionOutcomeEvidence.self, forKey: .outcomeEvidence) {
                outcomeEvidence = evidence
                completionPolicy = try values.decodeIfPresent(DesktopStepCompletionPolicy.self, forKey: .completionPolicy)
                    ?? .outcomeRequired
            } else if let legacyVerified = try values.decodeIfPresent(Bool.self, forKey: .verified) {
                // v1 conservative read: the flattened Bool only ever proves a
                // system verification. false keeps outcomeRequired evidence
                // missing — a legacy attempt never reads as delivery-completed.
                outcomeEvidence = legacyVerified ? .systemVerified : .notObserved
                completionPolicy = .outcomeRequired
            } else {
                // Not enough facts to classify the attempt: treat it as an
                // unsatisfied, unresolved effect that needs a human check.
                outcomeEvidence = .notObserved
                completionPolicy = .outcomeRequired
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(observationID, forKey: .observationID)
            try values.encode(revision, forKey: .revision)
            try values.encode(action, forKey: .action)
            try values.encode(targetDigest, forKey: .targetDigest)
            try values.encode(completionPolicy, forKey: .completionPolicy)
            try values.encode(delivery, forKey: .delivery)
            try values.encode(outcomeEvidence, forKey: .outcomeEvidence)
            // Compatibility for v1 readers; derived, never authoritative.
            try values.encode(verified, forKey: .verified)
        }
    }

    struct Snapshot: Codable {
        let schemaVersion: Int
        let taskID: String
        let targetVersion: Int
        var status: String
        let completedStepCount: Int
        let totalStepCount: Int
        let attempts: [Attempt]
    }

    private let directory: URL
    private let fileURL: URL

    init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("task.json")
    }

    static func applicationDefault() -> DesktopTaskJournal {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DesktopTaskJournal(directory: support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "tiptour-local")
            .appendingPathComponent("TaskRecovery"))
    }

    func load() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        try refuseSymlink(fileURL)
        let bytes = try Data(contentsOf: fileURL)
        guard bytes.count <= 256_000 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Snapshot.self, from: bytes)
        guard (1...2).contains(value.schemaVersion), !value.taskID.isEmpty,
              value.targetVersion > 0, value.completedStepCount >= 0,
              value.totalStepCount >= value.completedStepCount, value.attempts.count <= 256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var snapshot = value
        if snapshot.status == "completed", snapshot.attempts.contains(where: \Attempt.uncertainEffect) {
            // A stored completion claim with an unresolved attempt is exactly
            // the false-completion class this journal exists to catch: keep
            // the task subject to human inspection instead of trusting it.
            snapshot.status = "recovery_required"
        }
        return snapshot
    }

    func save(_ receipt: DesktopTaskReceipt) throws {
        let previous = try load()
        var attempts = previous?.taskID == receipt.taskID ? previous!.attempts : []
        for record in receipt.currentActions {
            let digest = SHA256.hash(data: Data("\(record.app)\u{0}\(record.targetID ?? "")\u{0}\(record.label)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let attempt = Attempt(id: record.id, observationID: record.observationID, revision: receipt.targetVersion,
                action: record.action, targetDigest: digest, completionPolicy: record.completionPolicy,
                delivery: record.delivery, outcomeEvidence: record.outcomeEvidence)
            if let index = attempts.firstIndex(where: { $0.id == record.id }) { attempts[index] = attempt }
            else { attempts.append(attempt) }
        }
        // Never silently evict an unresolved effect to meet a storage bound.
        guard attempts.count <= 256 else { throw CocoaError(.fileWriteOutOfSpace) }
        let snapshot = Snapshot(schemaVersion: 2, taskID: receipt.taskID, targetVersion: receipt.targetVersion,
            status: receipt.status, completedStepCount: receipt.completedStepCount,
            totalStepCount: receipt.totalStepCount, attempts: attempts)
        try writeAtomically(JSONEncoder().encode(snapshot))
    }

    private func refuseSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
    }

    private func writeAtomically(_ data: Data) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) { try refuseSymlink(directory) }
        else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let temporary = directory.appendingPathComponent(".pending-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? manager.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
