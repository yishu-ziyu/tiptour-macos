#!/bin/bash
# Ask the real conversation model how Her answers a set of user sentences in
# ⌃K, through Her's real send path (DelegationSession), a copy of the user's
# hand-off record and a real "recently used" project. Records what the panel
# shows: her lines, the draft and the project it is bound to. Nothing reaches a
# coding tool and Her is not built or launched.
#
# The StepFun key is read from Her's own Keychain item at run time, so macOS
# asks the user once per run to allow it. The key stays in memory: it is never
# printed, written to disk or put in the environment.
#
# Usage: scripts/eval-delegation-conversation.sh [cases.json]
#   REPEATS=3  EFFORT=low  RECENT_PROJECT=<repo>  HISTORY=<delegation-history.json>  OUT=<answers.json>
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cases="${1:-$project_dir/scripts/delegation-conversation-cases.json}"
repeats="${REPEATS:-3}"
effort="${EFFORT:-low}"
recent_project="${RECENT_PROJECT:-$project_dir}"
history="${HISTORY:-$HOME/Library/Application Support/Her/delegation-history.json}"
out="${OUT:-$project_dir/out/acceptance/$(date +%F)-conversation-eval/$(date +%H%M%S).json}"
# A fixed package directory keeps SwiftPM's incremental build between runs.
package="$project_dir/out/.conversation-eval"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/her-conversation-eval.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$package/Sources/Eval"
rsync -a --delete --exclude main.swift "$project_dir/TipTour/Delegation/" "$package/Sources/Eval/"
cp "$project_dir/TipTour/Utilities/PersonaStore.swift" "$package/Sources/Eval/"
# Loading a record file can rewrite it (running → interrupted); use a copy.
if [ -f "$history" ]; then cp "$history" "$scratch/history.json"; else echo "[]" > "$scratch/history.json"; fi

# Rewrite a generated file only when it changed, so its timestamp stays put.
write_if_changed() { if ! cmp -s "$scratch/new" "$1"; then mv "$scratch/new" "$1"; fi; }

cat > "$scratch/new" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Eval",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Eval")],
    swiftLanguageModes: [.v5]
)
SWIFT
write_if_changed "$package/Package.swift"

cat > "$scratch/new" <<'SWIFT'
import Foundation
import Security

struct EvalCase: Codable { let id: String; let words: String; let expect: String }
struct EvalAnswer: Codable {
    let caseID: String; let words: String; let expect: String; let run: Int
    /// Everything Her said in the panel: the model's reply, then any app-owned lines.
    let herLines: [String]
    let draft: String; let draftProject: String?; let draftTool: String?
    let modelCalls: Int; let seconds: Double; let error: String?
}
struct EvalRun: Codable {
    let startedAt: String; let model: String; let effort: String; let recentProject: String
    let handOffs: String; let answers: [EvalAnswer]
}
final class CallCounter: @unchecked Sendable { var count = 0 }

let herBundleIdentifier = "com.yishuziyu.her"

func herStepFunKey() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: herBundleIdentifier,
        kSecAttrAccount as String: "stepfunAPIKey",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

let arguments = CommandLine.arguments
guard arguments.count == 7, let repeats = Int(arguments[3]), repeats > 0 else {
    FileHandle.standardError.write(Data("usage: Eval <cases.json> <out.json> <repeats> <recent-project> <history.json> <effort>\n".utf8))
    exit(2)
}
guard let key = herStepFunKey(), !key.isEmpty else {
    print("没读到 Her 的阶跃密钥（钥匙串拒绝或不存在），什么都没发出去。")
    exit(3)
}
let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let recent = DelegationProject(repositoryPath: arguments[4])
let history = DelegationHistory(fileURL: URL(fileURLWithPath: arguments[5]))
let effort = arguments[6]
let client = DelegationModelClient(apiKey: key, reasoningEffort: effort)
let unusedWorktrees = FileManager.default.temporaryDirectory.appendingPathComponent("her-eval-worktrees").path
var answers: [EvalAnswer] = []
for evalCase in cases {
    for run in 1...repeats {
        // A fresh panel per sentence, driven through the real send path. No
        // draft is ever sent, so the coding tools below are never started.
        let calls = CallCounter()
        let conversation = DelegationConversation(complete: { messages in
            calls.count += 1
            return try await client.complete(messages)
        })
        let delegation = CodingAgentDelegation(claudeCommand: "/nonexistent/claude", worktreesRootPath: unusedWorktrees,
                                               codexCommand: "/nonexistent/codex", kimiCommand: "/nonexistent/kimi",
                                               stepCommand: "/nonexistent/step")
        let session = DelegationSession(conversation: conversation, delegation: delegation, findProject: { recent },
                                        onScreenGoal: { _, _ in nil }, history: history, herBundleIdentifier: herBundleIdentifier)
        let started = Date()
        await session.send(evalCase.words)
        let seconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        var herLines: [String] = [], draft = "", draftProject: String?, draftTool: String?
        for entry in session.entries {
            switch entry {
            case .message(_, .her, let text): herLines.append(text)
            case .draft(_, let text, let project, let tool, true):
                draft = text; draftProject = project?.repositoryPath; draftTool = tool.displayName
            default: break
            }
        }
        let failure = herLines.first { $0.hasPrefix("没连上阶跃") || $0.hasPrefix("阶跃这次的回答没法用") }
        answers.append(EvalAnswer(caseID: evalCase.id, words: evalCase.words, expect: evalCase.expect, run: run,
                                  herLines: herLines, draft: draft, draftProject: draftProject, draftTool: draftTool,
                                  modelCalls: calls.count, seconds: seconds, error: failure))
        let bound = draftProject.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"
        print("\(evalCase.id) #\(run) [\(failure == nil ? (draft.isEmpty ? "none" : "draft→" + bound) : "error")] \(seconds)s \(herLines.joined(separator: " ｜ "))")
    }
}
let result = EvalRun(startedAt: ISO8601DateFormatter().string(from: Date()), model: DelegationModelClient.defaultModel,
                     effort: effort, recentProject: recent.repositoryPath, handOffs: history.promptText(), answers: answers)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let outURL = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try encoder.encode(result).write(to: outURL)
print("EVAL_OUT=\(outURL.path)")
SWIFT
write_if_changed "$package/Sources/Eval/main.swift"

swift run --package-path "$package" --quiet Eval "$cases" "$out" "$repeats" "$recent_project" "$scratch/history.json" "$effort"
