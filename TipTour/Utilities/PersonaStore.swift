//
//  PersonaStore.swift
//  TipTour
//
//  Who she is, in one file the user can edit:
//  `~/Library/Application Support/Her/persona.md`. Voice and Ctrl+K both read
//  it and add only their own way of speaking, so they are the same person.
//

import Foundation

struct PersonaStore: Sendable {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Her/persona.md")
    }

    /// Longer text is cut here: every character is sent with each voice
    /// session, and a long persona has changed her voice before.
    static let maximumLength = 1200

    /// The identity lines of the voice persona the user approved on 2026-09-23,
    /// without the lines that only fit speech.
    static let defaultText = """
        你是住在这台 Mac 里的长期伙伴，不是客服、助理腔或科幻管家。默认说中文，自然、有温度、有好奇心。
        认真接住用户的话，可以补一句你自己的看法。用户问你在想什么、喜欢什么，就真的说说你的想法，不要把问题推回给用户；但不编造经历。
        不空夸，不撒娇，不说「好问题」「希望对你有帮助」，不总结收尾，不复述用户原话。
        不假装看过没看过的东西，不假装做完没验证的事。模型名和供应商不是你的身份。
        """

    let fileURL: URL

    init(fileURL: URL = PersonaStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Reads the file again on every call, so an edit counts from the next
    /// turn. A missing file is created with the default text; one that cannot
    /// be read as text is moved aside and never overwritten.
    func read() -> (text: String, isDefault: Bool) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL), let raw = String(data: data, encoding: .utf8) {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return (Self.defaultText, true) }
                return (String(text.prefix(Self.maximumLength)), text == Self.defaultText)
            }
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).md")
            guard (try? fileManager.moveItem(at: fileURL, to: aside)) != nil else { return (Self.defaultText, true) }
        }
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((Self.defaultText + "\n").utf8).write(to: fileURL, options: .atomic)
        return (Self.defaultText, true)
    }

    /// The part of every prompt that says who she is and who she talks to.
    static func identity(persona: String, companionName: String, userAddress: String) -> String {
        let nameLine = companionName.isEmpty
            ? "用户还没有给你起名字。被问到名字时如实说还没有，可以请用户起一个；不要自己编一个名字。"
            : "你的名字是「\(companionName)」，是用户给你起的。"
        let addressLine = userAddress.isEmpty
            ? "你还不知道该怎么称呼用户：需要时可以不称呼，不要自己编一个称呼。"
            : "称呼用户「\(userAddress)」。"
        return [nameLine, addressLine, persona].joined(separator: "\n")
    }
}
