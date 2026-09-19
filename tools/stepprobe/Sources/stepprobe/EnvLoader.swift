//
//  EnvLoader.swift
//  stepprobe
//
//  Reads provider credentials from the repository's git-ignored `.env`.
//  The app itself never reads this file — it keeps keys in the Keychain — so
//  the two paths stay separate and a secret is never compiled into a bundle.
//

import Foundation

enum EnvLoader {
    /// Walks up from the current directory so the probe works whether it is
    /// invoked from `tools/stepprobe` or from the repository root.
    static func loadDotEnv() {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent(".env")
            if let contents = try? String(contentsOf: candidate, encoding: .utf8) {
                apply(contents)
                return
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        print("⚠️  stepprobe: no .env found — run `cp .env.example .env` at the repository root")
    }

    private static func apply(_ contents: String) {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separatorIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separatorIndex])
                .trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespaces)
            // Strip one layer of matching quotes so both `KEY=v` and `KEY="v"` work.
            if value.count >= 2,
               let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            guard !key.isEmpty, setenv(key, value, 1) == 0 else { continue }
        }
    }

    static func require(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw ProbeError.missingCredential(name)
        }
        return value
    }
}

enum ProbeError: LocalizedError {
    case missingCredential(String)
    case http(status: Int, body: String)
    case malformedResponse(String)
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let name):
            return "Missing credential \(name). Add it to the repository root .env (see .env.example)."
        case .http(let status, let body):
            return "HTTP \(status): \(body.prefix(400))"
        case .malformedResponse(let detail):
            return "Malformed response: \(detail)"
        case .usage(let message):
            return message
        }
    }
}
