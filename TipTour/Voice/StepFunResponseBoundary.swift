import Foundation

/// Protects a live connection from late events belonging to an older response.
/// All access in the client is serialized by its existing state lock.
struct StepFunResponseBoundary {
    private(set) var activeID: String?
    private var cancelled = false
    private var completed = false
    private var retiredIDs: [String] = []
    private var deliveredCallIDs: Set<String> = []

    mutating func begin(id: String?) -> Bool {
        if let id, retiredIDs.contains(id) || (id == activeID && !completed && !cancelled) { return false }
        if let activeID { retire(activeID) }
        activeID = id
        cancelled = false
        completed = false
        deliveredCallIDs = []
        return true
    }

    func accepts(responseID: String?) -> Bool {
        !cancelled && !completed && (responseID == nil || activeID == nil || responseID == activeID)
    }

    mutating func acceptCall(id: String, responseID: String?) -> Bool {
        guard !id.isEmpty, accepts(responseID: responseID) else { return false }
        return deliveredCallIDs.insert(id).inserted
    }

    mutating func cancel() {
        cancelled = true
        if let activeID { retire(activeID) }
    }

    mutating func complete() {
        completed = true
        if let activeID { retire(activeID) }
    }

    private mutating func retire(_ id: String) {
        guard !retiredIDs.contains(id) else { return }
        retiredIDs.append(id)
        retiredIDs = Array(retiredIDs.suffix(32))
    }
}

/// An action receipt may use the realtime voice only after its generated
/// transcript still says the program-produced receipt. Punctuation and spacing
/// are not semantic changes; every other added, removed or changed character is.
struct StepFunVerifiedReceiptSpeech {
    static func matches(expected: String, transcript: String) -> Bool {
        canonicalText(expected) == canonicalText(transcript)
    }

    private static func canonicalText(_ text: String) -> String {
        let ignoredCharacters = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
        return String(text.unicodeScalars.filter { !ignoredCharacters.contains($0) })
    }
}
