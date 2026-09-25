//
//  CodingAgentDelegation.swift
//  TipTour
//
//  Hands one piece of coding work to Claude Code and reports what really
//  changed. Stage 4 minimal version (docs/development/2026-09-25-claude-code-delegation-map.md).
//
//  The shape follows the open-source orchestrators studied in
//  docs/research/delegation-references.md: every hand-off runs in its own git
//  worktree and branch (vibe-kanban), so the user's own uncommitted work is
//  never touched and nothing reaches their branch until they approve a merge.
//  Whether the work was done is decided by reading the worktree back with git,
//  never by what Claude Code says about itself.
//

import Foundation

/// A git repository the user works in.
struct DelegationProject: Equatable, Sendable {
    let repositoryPath: String

    var name: String { URL(fileURLWithPath: repositoryPath).lastPathComponent }
}

/// One hand-off's private worktree and branch, created from the project's HEAD.
struct DelegationWorkspace: Equatable, Sendable {
    let project: DelegationProject
    let branchName: String
    let worktreePath: String
    let baseCommit: String
}

enum DelegationOutcome: Equatable, Sendable {
    /// Independent readback found commits or tracked edits since the base.
    case changed
    /// Claude Code finished, but the worktree holds nothing new.
    case noChange
    /// Claude Code could not be started or ended with an error.
    case agentFailed(reason: String)
    case cancelled
}

struct DelegationReceipt: Equatable, Sendable {
    let workspace: DelegationWorkspace
    let outcome: DelegationOutcome
    /// Claude Code's own closing words. Shown to the user, never used to decide
    /// the outcome.
    let agentSummary: String
    /// Tracked files that differ from the base, read back with git.
    let changedFiles: [String]
    /// Untracked files that appeared in the worktree. Reported, never merged
    /// automatically: hooks also leave files here (for example `.statamcp/`).
    let untrackedFiles: [String]
    let diffStat: String
    let costInUSD: Double?
    let durationMilliseconds: Int?
    /// Lets a later request resume the same Claude Code conversation.
    let agentSessionID: String?
}

enum DelegationProgress: Equatable, Sendable {
    /// A short line about what Claude Code is doing right now.
    case working(String)
}

enum DelegationError: Error, Equatable, LocalizedError {
    case gitFailed(command: String, message: String)
    case mergeRefused(message: String)

    var errorDescription: String? {
        switch self {
        case .gitFailed(let command, let message):
            return "git \(command) 失败：\(message)"
        case .mergeRefused(let message):
            return "没能合并：\(message)"
        }
    }
}

struct DelegationCommandResult: Sendable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
}

enum DelegationCommand {
    static let gitExecutablePath = "/usr/bin/git"

    /// Runs a tool to completion off the main thread.
    static func run(_ executablePath: String, _ arguments: [String], inDirectory directoryPath: String? = nil) async -> DelegationCommandResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            if let directoryPath { process.currentDirectoryURL = URL(fileURLWithPath: directoryPath) }
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return DelegationCommandResult(exitStatus: -1, standardOutput: "", standardError: error.localizedDescription)
            }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return DelegationCommandResult(
                exitStatus: process.terminationStatus,
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: String(decoding: errorData, as: UTF8.self)
            )
        }.value
    }

    static func git(_ arguments: [String], inDirectory directoryPath: String) async -> DelegationCommandResult {
        await run(gitExecutablePath, ["-C", directoryPath] + arguments)
    }
}

/// Finds the project the user last worked on with Claude Code.
///
/// Claude Code writes one JSONL file per session under
/// `~/.claude/projects/<encoded path>/`, and each record carries the session's
/// `cwd`. The directory name alone cannot be decoded (non-ASCII characters are
/// flattened to `-`), so the `cwd` inside the newest files is what counts.
/// Her's own hand-offs, temporary directories and Claude's scratch spaces
/// also produce sessions; those are skipped because they are not the user's
/// project.
enum DelegationProjectLocator {
    static var defaultClaudeProjectsDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
    }

    static func defaultExcludedPathPrefixes(worktreesRootPath: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            worktreesRootPath,
            "/private/var/folders/", "/var/folders/", "/tmp/", "/private/tmp/",
            home + "/Library/Application Support/Claude/",
        ]
    }

    static func mostRecentProject(
        claudeProjectsDirectoryPath: String = defaultClaudeProjectsDirectoryPath,
        excludedPathPrefixes: [String]
    ) async -> DelegationProject? {
        let fileManager = FileManager.default
        guard let projectDirectories = try? fileManager.contentsOfDirectory(atPath: claudeProjectsDirectoryPath) else {
            return nil
        }
        var sessionFiles: [(path: String, modified: Date)] = []
        for directoryName in projectDirectories {
            let directoryPath = (claudeProjectsDirectoryPath as NSString).appendingPathComponent(directoryName)
            guard let fileNames = try? fileManager.contentsOfDirectory(atPath: directoryPath) else { continue }
            for fileName in fileNames where fileName.hasSuffix(".jsonl") {
                let filePath = (directoryPath as NSString).appendingPathComponent(fileName)
                let modified = (try? fileManager.attributesOfItem(atPath: filePath)[.modificationDate] as? Date) ?? .distantPast
                sessionFiles.append((filePath, modified))
            }
        }
        sessionFiles.sort { $0.modified > $1.modified }

        var alreadyCheckedWorkingDirectories = Set<String>()
        for sessionFile in sessionFiles.prefix(40) {
            guard let workingDirectory = firstWorkingDirectory(inSessionFileAt: sessionFile.path),
                  alreadyCheckedWorkingDirectories.insert(workingDirectory).inserted else { continue }
            if workingDirectory.contains("/.claude/worktrees/") { continue }
            if excludedPathPrefixes.contains(where: { workingDirectory.hasPrefix($0) }) { continue }
            guard fileManager.fileExists(atPath: workingDirectory) else { continue }
            let topLevel = await DelegationCommand.git(["rev-parse", "--show-toplevel"], inDirectory: workingDirectory)
            guard topLevel.exitStatus == 0 else { continue }
            let repositoryPath = topLevel.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if excludedPathPrefixes.contains(where: { repositoryPath.hasPrefix($0) }) { continue }
            return DelegationProject(repositoryPath: repositoryPath)
        }
        return nil
    }

    /// Reads only the start of the file: session logs grow to megabytes and the
    /// working directory appears in the first records.
    private static func firstWorkingDirectory(inSessionFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 256 * 1024), as: UTF8.self)
        for line in head.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let workingDirectory = record["cwd"] as? String, !workingDirectory.isEmpty else { continue }
            return workingDirectory
        }
        return nil
    }
}

final class CodingAgentDelegation: @unchecked Sendable {
    static var defaultWorktreesRootPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Her/worktrees").path
    }

    /// The command that starts Claude Code. It is resolved through the user's
    /// login shell, so `claude` finds the same install the user's terminal does.
    private let claudeCommand: String
    private let worktreesRootPath: String
    private let processLock = NSLock()
    private var runningAgentProcess: Process?
    private var cancellationRequested = false

    init(claudeCommand: String = "claude", worktreesRootPath: String = CodingAgentDelegation.defaultWorktreesRootPath) {
        self.claudeCommand = claudeCommand
        self.worktreesRootPath = worktreesRootPath
    }

    // MARK: - Workspace

    func prepareWorkspace(for project: DelegationProject, taskSlug: String) async throws -> DelegationWorkspace {
        // A new hand-off starts un-cancelled; a stop pressed after this point
        // (even before Claude Code launches) still applies to it.
        processLock.withLock { cancellationRequested = false }
        let head = await DelegationCommand.git(["rev-parse", "HEAD"], inDirectory: project.repositoryPath)
        guard head.exitStatus == 0 else {
            throw DelegationError.gitFailed(command: "rev-parse HEAD", message: head.standardError)
        }
        let baseCommit = head.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueSuffix = String(UUID().uuidString.prefix(6)).lowercased()
        let safeSlug = Self.branchSafe(taskSlug)
        let branchName = "her/\(safeSlug)-\(uniqueSuffix)"
        let worktreePath = (worktreesRootPath as NSString)
            .appendingPathComponent("\(project.name)-\(safeSlug)-\(uniqueSuffix)")
        try? FileManager.default.createDirectory(atPath: worktreesRootPath, withIntermediateDirectories: true)
        let add = await DelegationCommand.git(["worktree", "add", "-b", branchName, worktreePath, baseCommit],
                                              inDirectory: project.repositoryPath)
        guard add.exitStatus == 0 else {
            throw DelegationError.gitFailed(command: "worktree add", message: add.standardError)
        }
        return DelegationWorkspace(project: project, branchName: branchName, worktreePath: worktreePath, baseCommit: baseCommit)
    }

    private static func branchSafe(_ slug: String) -> String {
        let allowed = slug.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "task" : String(collapsed.prefix(32))
    }

    // MARK: - Run

    /// Runs Claude Code headless inside the workspace and reads the result back.
    ///
    /// `--permission-mode auto` lets it edit and run commands on its own while
    /// its classifier still blocks risky actions; the worktree is what keeps
    /// the user's own branch safe.
    func run(
        prompt: String,
        in workspace: DelegationWorkspace,
        onProgress: @escaping @Sendable (DelegationProgress) -> Void
    ) async -> DelegationReceipt {
        let claudeArguments = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", "auto"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$0\" \"$@\"", claudeCommand] + claudeArguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspace.worktreePath)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        let alreadyCancelled: Bool = processLock.withLock {
            runningAgentProcess = process
            return cancellationRequested
        }
        if alreadyCancelled {
            return await readBack(workspace, agentResult: nil, failure: nil, cancelled: true)
        }
        do {
            try process.run()
        } catch {
            processLock.withLock { runningAgentProcess = nil }
            return await readBack(workspace, agentResult: nil,
                                  failure: "没能启动 Claude Code：\(error.localizedDescription)", cancelled: false)
        }

        var agentResult: [String: Any]?
        do {
            for try await line in outputPipe.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let progress = Self.progress(from: event) { onProgress(progress) }
                if event["type"] as? String == "result" { agentResult = event }
            }
        } catch {
            // The pipe closes when the process ends; a read error here only
            // means the stream stopped early, which the exit status reports.
        }
        let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        await Task.detached { process.waitUntilExit() }.value
        let wasCancelled: Bool = processLock.withLock {
            runningAgentProcess = nil
            return cancellationRequested
        }

        var failure: String?
        if !wasCancelled {
            if agentResult == nil {
                let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                failure = detail.isEmpty ? "Claude Code 没有给出结果（退出码 \(process.terminationStatus)）" : String(detail.suffix(400))
            } else if agentResult?["is_error"] as? Bool == true {
                failure = (agentResult?["result"] as? String) ?? "Claude Code 报告出错"
            }
        }
        return await readBack(workspace, agentResult: agentResult, failure: failure, cancelled: wasCancelled)
    }

    /// Stops the running hand-off. The receipt it returns says cancelled.
    func cancel() {
        let process: Process? = processLock.withLock {
            cancellationRequested = true
            return runningAgentProcess
        }
        process?.terminate()
    }

    private static func progress(from event: [String: Any]) -> DelegationProgress? {
        if event["type"] as? String == "system", event["subtype"] as? String == "task_summary",
           let detail = event["detail"] as? String, !detail.isEmpty {
            return .working(detail)
        }
        guard event["type"] as? String == "assistant",
              let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        for block in content where block["type"] as? String == "tool_use" {
            let toolName = block["name"] as? String ?? ""
            let input = block["input"] as? [String: Any] ?? [:]
            if ["Edit", "Write", "MultiEdit"].contains(toolName), let filePath = input["file_path"] as? String {
                return .working("改 \(URL(fileURLWithPath: filePath).lastPathComponent)")
            }
            if toolName == "Read", let filePath = input["file_path"] as? String {
                return .working("读 \(URL(fileURLWithPath: filePath).lastPathComponent)")
            }
        }
        return nil
    }

    // MARK: - Independent readback

    private func readBack(
        _ workspace: DelegationWorkspace,
        agentResult: [String: Any]?,
        failure: String?,
        cancelled: Bool
    ) async -> DelegationReceipt {
        let worktree = workspace.worktreePath
        // Compares the worktree (committed and uncommitted tracked edits) with
        // the base, so work Claude Code forgot to commit still counts.
        let changedNames = await DelegationCommand.git(["diff", "--name-only", workspace.baseCommit], inDirectory: worktree)
        let stat = await DelegationCommand.git(["diff", "--stat", workspace.baseCommit], inDirectory: worktree)
        let untracked = await DelegationCommand.git(["ls-files", "--others", "--exclude-standard"], inDirectory: worktree)
        let changedFiles = Self.lines(changedNames.standardOutput)
        let outcome: DelegationOutcome
        if cancelled {
            outcome = .cancelled
        } else if let failure {
            outcome = .agentFailed(reason: failure)
        } else {
            outcome = changedFiles.isEmpty ? .noChange : .changed
        }
        return DelegationReceipt(
            workspace: workspace,
            outcome: outcome,
            agentSummary: (agentResult?["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            changedFiles: changedFiles,
            untrackedFiles: Self.lines(untracked.standardOutput),
            diffStat: stat.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            costInUSD: agentResult?["total_cost_usd"] as? Double,
            durationMilliseconds: agentResult?["duration_ms"] as? Int,
            agentSessionID: agentResult?["session_id"] as? String
        )
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - After the user decides

    /// Merges the workspace branch into the project's current branch, then
    /// removes the workspace. Tracked edits Claude Code left uncommitted are
    /// committed first; untracked files are left out on purpose.
    ///
    /// Returns the project's new HEAD.
    func merge(_ workspace: DelegationWorkspace, commitMessage: String) async throws -> String {
        let worktree = workspace.worktreePath
        let pending = await DelegationCommand.git(["diff", "--name-only", "HEAD"], inDirectory: worktree)
        if !Self.lines(pending.standardOutput).isEmpty {
            _ = await DelegationCommand.git(["add", "-u"], inDirectory: worktree)
            let commit = await DelegationCommand.git(["commit", "-m", commitMessage], inDirectory: worktree)
            guard commit.exitStatus == 0 else {
                throw DelegationError.gitFailed(command: "commit", message: commit.standardError + commit.standardOutput)
            }
        }
        let merge = await DelegationCommand.git(["merge", "--no-edit", workspace.branchName],
                                                inDirectory: workspace.project.repositoryPath)
        guard merge.exitStatus == 0 else {
            _ = await DelegationCommand.git(["merge", "--abort"], inDirectory: workspace.project.repositoryPath)
            let message = (merge.standardError + merge.standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DelegationError.mergeRefused(message: String(message.suffix(400)))
        }
        await removeWorkspace(workspace, forceDeleteBranch: false)
        let head = await DelegationCommand.git(["rev-parse", "HEAD"], inDirectory: workspace.project.repositoryPath)
        return head.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Throws the workspace and its branch away without touching the project.
    func discard(_ workspace: DelegationWorkspace) async {
        await removeWorkspace(workspace, forceDeleteBranch: true)
    }

    private func removeWorkspace(_ workspace: DelegationWorkspace, forceDeleteBranch: Bool) async {
        let repository = workspace.project.repositoryPath
        _ = await DelegationCommand.git(["worktree", "remove", "--force", workspace.worktreePath], inDirectory: repository)
        _ = await DelegationCommand.git(["branch", forceDeleteBranch ? "-D" : "-d", workspace.branchName], inDirectory: repository)
    }
}
