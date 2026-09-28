//
//  CodingAgentDelegation.swift
//  TipTour
//
//  Hands one piece of coding work to an external CLI and reports what really
//  changed. Stage 4 minimal version (docs/development/2026-09-25-claude-code-delegation-map.md).
//
//  The shape follows the open-source orchestrators studied in
//  docs/research/delegation-references.md: every hand-off runs in its own git
//  worktree and branch (vibe-kanban), so the user's own uncommitted work is
//  never touched and nothing reaches their branch until they approve a merge.
//  Whether the work was done is decided by reading the worktree back with git,
//  never by what the agent says about itself.
//

import CryptoKit
import Foundation

/// A git repository the user works in.
struct DelegationProject: Codable, Equatable, Sendable {
    let repositoryPath: String

    var name: String { URL(fileURLWithPath: repositoryPath).lastPathComponent }
}

/// One hand-off's private worktree and branch, created from the project's HEAD.
struct DelegationWorkspace: Codable, Equatable, Sendable {
    let project: DelegationProject
    let branchName: String
    let worktreePath: String
    let baseCommit: String
    /// The project's branch when the workspace was made; the change is merged
    /// only into this branch. Nil for a detached HEAD or an older record.
    var projectBranch: String? = nil
}

enum DelegationOutcome: Codable, Equatable, Sendable {
    /// Independent readback found commits or tracked edits since the base.
    case changed
    /// The agent finished, but the worktree holds nothing new.
    case noChange
    /// The agent could not be started or ended with an error.
    case agentFailed(reason: String)
    case cancelled
}

enum DelegationAgentTool: String, CaseIterable, Codable, Sendable {
    case claudeCode, codex, kimiCode, stepCode

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .kimiCode: return "Kimi Code"
        case .stepCode: return "Step Code"
        }
    }
}

struct DelegationReceipt: Codable, Equatable, Sendable {
    let workspace: DelegationWorkspace
    let outcome: DelegationOutcome
    /// The agent's own closing words. Shown to the user, never used to decide
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
    /// Identifies the selected CLI's conversation for later reference.
    let agentSessionID: String?
    var agentTool: DelegationAgentTool = .claudeCode
    /// Fingerprint of the tracked changes the user was shown; a merge goes
    /// ahead only while the workspace still matches it. Empty when unknown.
    var diffDigest: String = ""
}

enum DelegationProgress: Equatable, Sendable {
    /// A short line about what Claude Code is doing right now.
    case working(String)
}

enum DelegationError: Error, Equatable, LocalizedError {
    case gitFailed(command: String, message: String)
    case mergeRefused(message: String)
    /// The workspace no longer holds what the user reviewed; nothing was merged.
    /// Carries the receipt read back just now.
    case changedSinceReview(DelegationReceipt)
    /// The project is on another branch than when the task started; nothing was merged.
    case branchMoved(expected: String, current: String)

    var errorDescription: String? {
        switch self {
        case .gitFailed(let command, let message):
            return "git \(command) 失败：\(message)"
        case .mergeRefused(let message):
            return "没能合并：\(message)"
        case .changedSinceReview:
            return "你看过之后工作区又变了，没有合进去"
        case .branchMoved(let expected, let current):
            return "任务开始时项目在 \(expected) 分支，现在在 \(current.isEmpty ? "没有分支的提交" : current)，没有合进去"
        }
    }
}

struct DelegationCommandResult: Sendable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
}

/// Delivers a process's exit through `terminationHandler`.
///
/// `Process.waitUntilExit()` waits for a notification that is delivered to
/// the run loop of the thread that launched the process. Swift concurrency
/// launches and waits on different pool threads, so that notification can
/// never arrive and the wait hangs forever even though the process is gone
/// (seen in `scripts/test-delegation.sh`: the stub had exited, the run never
/// returned).
final class DelegationProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    /// Call before `process.run()`.
    func attach(to process: Process) {
        process.terminationHandler = { [weak self] finishedProcess in
            self?.finish(finishedProcess.terminationStatus)
        }
    }

    func finish(_ status: Int32) {
        let continuation: CheckedContinuation<Int32, Never>? = lock.withLock {
            exitStatus = status
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let alreadyFinished: Int32? = lock.withLock {
                if let exitStatus { return exitStatus }
                waiter = continuation
                return nil
            }
            if let alreadyFinished { continuation.resume(returning: alreadyFinished) }
        }
    }
}

enum DelegationCommand {
    static let gitExecutablePath = "/usr/bin/git"

    /// Runs a tool to completion off the main thread.
    static func run(_ executablePath: String, _ arguments: [String], inDirectory directoryPath: String? = nil) async -> DelegationCommandResult {
        let exit = DelegationProcessExit()
        let output: (Data, Data)? = await Task.detached { () -> (Data, Data)? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            if let directoryPath { process.currentDirectoryURL = URL(fileURLWithPath: directoryPath) }
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.standardInput = FileHandle.nullDevice
            exit.attach(to: process)
            do {
                try process.run()
            } catch {
                exit.finish(-1)
                return nil
            }
            // Drain stderr concurrently so a chatty command cannot fill its
            // pipe and block while stdout is still being read.
            let errorReader = Task.detached { errorPipe.fileHandleForReading.readDataToEndOfFile() }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return (outputData, await errorReader.value)
        }.value
        let exitStatus = await exit.wait()
        guard let output else {
            return DelegationCommandResult(exitStatus: -1, standardOutput: "", standardError: "could not launch \(executablePath)")
        }
        return DelegationCommandResult(
            exitStatus: exitStatus,
            standardOutput: String(decoding: output.0, as: UTF8.self),
            standardError: String(decoding: output.1, as: UTF8.self)
        )
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
    private let codexCommand: String
    private let kimiCommand: String
    private let stepCommand: String
    private let worktreesRootPath: String
    private let processLock = NSLock()
    private var runningAgentProcess: Process?
    private var cancellationRequested = false

    init(claudeCommand: String = "claude", worktreesRootPath: String = CodingAgentDelegation.defaultWorktreesRootPath,
         codexCommand: String = "codex", kimiCommand: String = "kimi", stepCommand: String = "step") {
        self.claudeCommand = claudeCommand
        self.codexCommand = codexCommand
        self.kimiCommand = kimiCommand
        self.stepCommand = stepCommand
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
        let branch = await DelegationCommand.git(["branch", "--show-current"], inDirectory: project.repositoryPath)
        let projectBranch = branch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return DelegationWorkspace(project: project, branchName: branchName, worktreePath: worktreePath, baseCommit: baseCommit,
                                   projectBranch: projectBranch.isEmpty ? nil : projectBranch)
    }

    private static func branchSafe(_ slug: String) -> String {
        let allowed = slug.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "task" : String(collapsed.prefix(32))
    }

    // MARK: - Run

    /// Runs the selected CLI headless inside the workspace and reads the result back.
    ///
    /// Each CLI keeps its own authentication. Codex uses workspace-write;
    /// the other tools use their headless approval policies in the private worktree.
    func run(
        prompt: String,
        in workspace: DelegationWorkspace,
        tool: DelegationAgentTool = .claudeCode,
        onProgress: @escaping @Sendable (DelegationProgress) -> Void
    ) async -> DelegationReceipt {
        let command: String
        let arguments: [String]
        switch tool {
        case .claudeCode:
            command = claudeCommand
            arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", "auto"]
        case .codex:
            command = codexCommand
            arguments = ["--no-daemon", "-a", "never", "exec", "--sandbox", "workspace-write", "--json",
                         "-m", "gpt-6-luna", "-c", "model_reasoning_effort=\"high\"", "--", prompt]
        case .kimiCode:
            command = kimiCommand
            arguments = ["-p", prompt, "--output-format", "stream-json"]
        case .stepCode:
            command = stepCommand
            arguments = ["--mode", "json", "--print", "--approval-mode", "auto",
                         "--non-interactive-approval", "allow", "--no-update-check", "--", prompt]
        }
        let fallbackCommand: String
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch (tool, command) {
        case (.kimiCode, "kimi"):
            fallbackCommand = home.appendingPathComponent(".local/bin/kimi").path
        case (.stepCode, "step"):
            fallbackCommand = home.appendingPathComponent(".stepcode/bin/step").path
        default:
            fallbackCommand = ""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", """
        readonly her_tool_command="$0"
        readonly her_tool_fallback="$1"
        readonly her_worktree="$2"
        shift 2
        readonly -a her_tool_arguments=("$@")
        if [[ "$her_tool_command" == step && -n "$her_tool_fallback" && -r "$HOME/.zshrc" ]]; then
            source "$HOME/.zshrc" >/dev/null
        fi
        builtin cd -- "$her_worktree" || exit 126
        executable="$her_tool_command"
        if ! command -v -- "$executable" >/dev/null 2>&1 && [[ -n "$her_tool_fallback" ]]; then
            executable="$her_tool_fallback"
        fi
        exec "$executable" "${her_tool_arguments[@]}"
        """, command, fallbackCommand, workspace.worktreePath] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspace.worktreePath)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        let agentExit = DelegationProcessExit()
        agentExit.attach(to: process)
        do {
            let launched = try processLock.withLock {
                guard !cancellationRequested else { return false }
                try process.run()
                runningAgentProcess = process
                return true
            }
            if !launched {
                return await readBack(workspace, tool: tool, agentResult: DelegationAgentOutput(), failure: nil, cancelled: true)
            }
        } catch {
            processLock.withLock { runningAgentProcess = nil }
            return await readBack(workspace, tool: tool, agentResult: DelegationAgentOutput(),
                                  failure: "没能启动 \(tool.displayName)：\(error.localizedDescription)", cancelled: false)
        }

        let errorReader = Task.detached { errorPipe.fileHandleForReading.readDataToEndOfFile() }
        var agentResult = DelegationAgentOutput()
        do {
            for try await line in outputPipe.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if tool == .claudeCode, let progress = Self.progress(from: event) { onProgress(progress) }
                agentResult.consume(event, tool: tool)
            }
        } catch {
            // The pipe closes when the process ends; a read error here only
            // means the stream stopped early, which the exit status reports.
        }
        let errorOutput = String(decoding: await errorReader.value, as: UTF8.self)
        let agentExitStatus = await agentExit.wait()
        let wasCancelled: Bool = processLock.withLock {
            runningAgentProcess = nil
            return cancellationRequested
        }

        let failure = agentResult.failure(tool: tool, exitStatus: agentExitStatus, standardError: errorOutput)
        return await readBack(workspace, tool: tool, agentResult: agentResult, failure: failure, cancelled: wasCancelled)
    }

    /// Stops the running hand-off. The receipt it returns says cancelled.
    func cancel() {
        let process: Process? = processLock.withLock {
            cancellationRequested = true
            return runningAgentProcess
        }
        if let process, process.isRunning { process.terminate() }
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
        tool: DelegationAgentTool,
        agentResult: DelegationAgentOutput,
        failure: String?,
        cancelled: Bool
    ) async -> DelegationReceipt {
        let contents = await Self.contents(of: workspace)
        let changedFiles = contents.changedFiles
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
            agentSummary: agentResult.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            changedFiles: changedFiles,
            untrackedFiles: contents.untrackedFiles,
            diffStat: contents.diffStat,
            costInUSD: agentResult.costInUSD,
            durationMilliseconds: agentResult.durationMilliseconds,
            agentSessionID: agentResult.sessionID,
            agentTool: tool,
            diffDigest: contents.diffDigest
        )
    }

    private struct WorkspaceContents: Equatable {
        let changedFiles: [String]
        let untrackedFiles: [String]
        let diffStat: String
        let diffDigest: String
    }

    /// Compares the worktree (committed and uncommitted tracked edits) with
    /// the base, so work the tool forgot to commit still counts.
    private static func contents(of workspace: DelegationWorkspace) async -> WorkspaceContents {
        let worktree = workspace.worktreePath
        let changedNames = await DelegationCommand.git(["diff", "--name-only", workspace.baseCommit], inDirectory: worktree)
        let stat = await DelegationCommand.git(["diff", "--stat", workspace.baseCommit], inDirectory: worktree)
        let patch = await DelegationCommand.git(["diff", workspace.baseCommit], inDirectory: worktree)
        let untracked = await DelegationCommand.git(["ls-files", "--others", "--exclude-standard"], inDirectory: worktree)
        let digest = SHA256.hash(data: Data(patch.standardOutput.utf8)).map { String(format: "%02x", $0) }.joined()
        return WorkspaceContents(changedFiles: lines(changedNames.standardOutput), untrackedFiles: lines(untracked.standardOutput),
                                 diffStat: stat.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), diffDigest: digest)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - After the user decides

    /// Merges what the user reviewed into the branch the task started from,
    /// then removes the workspace. Tracked edits the tool left uncommitted are
    /// committed first; untracked files are left out on purpose. Nothing is
    /// merged when the workspace changed since `reviewed` was read back, or
    /// when the project has moved to another branch.
    ///
    /// Returns the project's new HEAD.
    func merge(_ reviewed: DelegationReceipt, commitMessage: String) async throws -> String {
        let workspace = reviewed.workspace
        let worktree = workspace.worktreePath
        let now = await Self.contents(of: workspace)
        guard !reviewed.diffDigest.isEmpty, now.diffDigest == reviewed.diffDigest else {
            throw DelegationError.changedSinceReview(DelegationReceipt(
                workspace: workspace, outcome: now.changedFiles.isEmpty ? .noChange : .changed,
                agentSummary: reviewed.agentSummary, changedFiles: now.changedFiles, untrackedFiles: now.untrackedFiles,
                diffStat: now.diffStat, costInUSD: reviewed.costInUSD, durationMilliseconds: reviewed.durationMilliseconds,
                agentSessionID: reviewed.agentSessionID, agentTool: reviewed.agentTool, diffDigest: now.diffDigest))
        }
        if let expected = workspace.projectBranch {
            let branch = await DelegationCommand.git(["branch", "--show-current"], inDirectory: workspace.project.repositoryPath)
            let current = branch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current == expected else { throw DelegationError.branchMoved(expected: expected, current: current) }
        }
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
