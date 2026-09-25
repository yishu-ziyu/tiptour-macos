import Foundation
import Testing
@testable import TipTour

/// Every test stubs Claude Code at the process seam: a real executable script
/// that prints the same stream-json events and makes (or skips) the same edits.
/// Assertions read the real git repositories back.
@Suite(.serialized)
struct CodingAgentDelegationTests {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("her-delegation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return (path as NSString).resolvingSymlinksInPath
    }

    private func git(_ arguments: [String], in directory: String) async -> String {
        await DelegationCommand.git(arguments, inDirectory: directory).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A project with one committed file and, like a real user, one
    /// uncommitted edit in a second file.
    private func makeProject() async throws -> DelegationProject {
        let repository = try makeTemporaryDirectory()
        _ = await git(["init", "-q", "-b", "main"], in: repository)
        _ = await git(["config", "user.email", "test@example.com"], in: repository)
        _ = await git(["config", "user.name", "Test"], in: repository)
        try "hello\n".write(toFile: repository + "/greeting.txt", atomically: true, encoding: .utf8)
        try "draft\n".write(toFile: repository + "/notes.txt", atomically: true, encoding: .utf8)
        _ = await git(["add", "."], in: repository)
        _ = await git(["commit", "-q", "-m", "init"], in: repository)
        try "draft, still editing\n".write(toFile: repository + "/notes.txt", atomically: true, encoding: .utf8)
        return DelegationProject(repositoryPath: repository)
    }

    /// Writes a fake `claude` that runs `body` in the worktree, then prints
    /// the given stream-json lines.
    private func makeStubClaude(body: String, events: [String]) throws -> String {
        let directory = try makeTemporaryDirectory()
        let path = directory + "/claude"
        let printed = events.map { "print -r -- '\($0)'" }.joined(separator: "\n")
        try "#!/bin/zsh\n\(body)\n\(printed)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private let successEvent = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","total_cost_usd":0.12,"duration_ms":900,"session_id":"session-1"}"#

    private func projectSnapshot(_ project: DelegationProject) async throws -> (head: String, status: String, notes: String) {
        (await git(["rev-parse", "HEAD"], in: project.repositoryPath),
         await git(["status", "--porcelain"], in: project.repositoryPath),
         try String(contentsOfFile: project.repositoryPath + "/notes.txt", encoding: .utf8))
    }

    // MARK: - Outcomes

    @Test func committedEditCountsAsChangedAndLeavesTheUsersTreeAlone() async throws {
        let project = try await makeProject()
        let before = try await projectSnapshot(project)
        let stub = try makeStubClaude(
            body: "print world > greeting.txt; git commit -qam 'Change greeting'",
            events: [#"{"type":"system","subtype":"task_summary","detail":"Editing greeting"}"#, successEvent])
        let delegation = CodingAgentDelegation(claudeCommand: stub, worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "greeting")
        let progress = ProgressRecorder()

        let receipt = await delegation.run(prompt: "change the greeting", in: workspace) { progress.append($0) }

        #expect(receipt.outcome == .changed)
        #expect(receipt.changedFiles == ["greeting.txt"])
        #expect(receipt.agentSummary == "Done.")
        #expect(receipt.costInUSD == 0.12)
        #expect(receipt.agentSessionID == "session-1")
        #expect(progress.values.contains(.working("Editing greeting")))
        let after = try await projectSnapshot(project)
        #expect(after.head == before.head)
        #expect(after.status == before.status)
        #expect(after.notes == "draft, still editing\n")
    }

    @Test func claimedSuccessWithoutEditsIsNotDone() async throws {
        let project = try await makeProject()
        let stub = try makeStubClaude(body: ":", events: [successEvent])
        let delegation = CodingAgentDelegation(claudeCommand: stub, worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "noop")

        let receipt = await delegation.run(prompt: "change the greeting", in: workspace) { _ in }

        #expect(receipt.outcome == .noChange)
        #expect(receipt.changedFiles.isEmpty)
        #expect(receipt.agentSummary == "Done.")
    }

    @Test func uncommittedEditCountsAndIsCommittedOnMerge() async throws {
        let project = try await makeProject()
        let stub = try makeStubClaude(body: "print world > greeting.txt", events: [successEvent])
        let delegation = CodingAgentDelegation(claudeCommand: stub, worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "greeting")

        let receipt = await delegation.run(prompt: "change the greeting", in: workspace) { _ in }
        #expect(receipt.outcome == .changed)

        _ = try await delegation.merge(workspace, commitMessage: "Change greeting")
        let merged = try String(contentsOfFile: project.repositoryPath + "/greeting.txt", encoding: .utf8)
        #expect(merged == "world\n")
        #expect(try String(contentsOfFile: project.repositoryPath + "/notes.txt", encoding: .utf8) == "draft, still editing\n")
        #expect(!FileManager.default.fileExists(atPath: workspace.worktreePath))
        #expect(await git(["branch", "--list", workspace.branchName], in: project.repositoryPath).isEmpty)
    }

    @Test func agentErrorIsNotDone() async throws {
        let project = try await makeProject()
        let stub = try makeStubClaude(
            body: "print world > greeting.txt",
            events: [#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"API overloaded"}"#])
        let delegation = CodingAgentDelegation(claudeCommand: stub, worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "greeting")

        let receipt = await delegation.run(prompt: "change the greeting", in: workspace) { _ in }

        #expect(receipt.outcome == .agentFailed(reason: "API overloaded"))
        #expect(receipt.changedFiles == ["greeting.txt"], "The readback still reports what is really in the worktree")
    }

    @Test func missingClaudeCommandIsReportedAsFailure() async throws {
        let project = try await makeProject()
        let delegation = CodingAgentDelegation(claudeCommand: "/nonexistent/claude",
                                               worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "greeting")

        let receipt = await delegation.run(prompt: "change the greeting", in: workspace) { _ in }

        guard case .agentFailed(let reason) = receipt.outcome else {
            Issue.record("expected a failure, got \(receipt.outcome)")
            return
        }
        #expect(reason.contains("/nonexistent/claude"))
    }

    @Test func cancelStopsTheRunAndSaysSo() async throws {
        let project = try await makeProject()
        let stub = try makeStubClaude(body: "sleep 30", events: [successEvent])
        let delegation = CodingAgentDelegation(claudeCommand: stub, worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "slow")
        let started = Date()

        async let receipt = delegation.run(prompt: "take your time", in: workspace) { _ in }
        try await Task.sleep(nanoseconds: 500_000_000)
        delegation.cancel()

        #expect(await receipt.outcome == .cancelled)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func mergeThatWouldOverwriteTheUsersEditIsRefused() async throws {
        let project = try await makeProject()
        let stub = try makeStubClaude(body: "print rewritten > notes.txt; git commit -qam 'Rewrite notes'",
                                      events: [successEvent])
        let delegation = CodingAgentDelegation(claudeCommand: stub, worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "notes")
        _ = await delegation.run(prompt: "rewrite notes", in: workspace) { _ in }

        await #expect(throws: DelegationError.self) {
            _ = try await delegation.merge(workspace, commitMessage: "Rewrite notes")
        }
        #expect(try String(contentsOfFile: project.repositoryPath + "/notes.txt", encoding: .utf8) == "draft, still editing\n")
        #expect(FileManager.default.fileExists(atPath: workspace.worktreePath), "The work survives for another try")
    }

    @Test func discardRemovesTheWorkspaceAndLeavesTheProject() async throws {
        let project = try await makeProject()
        let before = try await projectSnapshot(project)
        let stub = try makeStubClaude(body: "print world > greeting.txt; git commit -qam 'Change greeting'",
                                      events: [successEvent])
        let delegation = CodingAgentDelegation(claudeCommand: stub, worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "greeting")
        _ = await delegation.run(prompt: "change the greeting", in: workspace) { _ in }

        await delegation.discard(workspace)

        #expect(!FileManager.default.fileExists(atPath: workspace.worktreePath))
        #expect(await git(["branch", "--list", workspace.branchName], in: project.repositoryPath).isEmpty)
        let after = try await projectSnapshot(project)
        #expect(after.head == before.head && after.status == before.status && after.notes == before.notes)
    }

    @Test func hookLeftoversAreReportedButNeverMerged() async throws {
        let project = try await makeProject()
        let stub = try makeStubClaude(
            body: "mkdir -p .statamcp; print log > .statamcp/debug.txt; print world > greeting.txt; git commit -qam 'Change greeting'",
            events: [successEvent])
        let delegation = CodingAgentDelegation(claudeCommand: stub, worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "greeting")

        let receipt = await delegation.run(prompt: "change the greeting", in: workspace) { _ in }
        #expect(receipt.untrackedFiles == [".statamcp/debug.txt"])
        #expect(receipt.changedFiles == ["greeting.txt"])

        _ = try await delegation.merge(workspace, commitMessage: "Change greeting")
        #expect(!FileManager.default.fileExists(atPath: project.repositoryPath + "/.statamcp/debug.txt"))
    }

    // MARK: - Current project

    @Test func currentProjectSkipsHerWorktreesTemporaryAndMissingDirectories() async throws {
        let project = try await makeProject()
        let nestedDirectory = project.repositoryPath + "/Sources"
        try FileManager.default.createDirectory(atPath: nestedDirectory, withIntermediateDirectories: true)
        let herWorktreesRoot = try makeTemporaryDirectory()
        let notARepository = try makeTemporaryDirectory()
        let excludedRoot = try makeTemporaryDirectory()
        let sessions = try makeTemporaryDirectory()

        // Oldest first: only the oldest session points at the real project.
        let sessionWorkingDirectories = [
            nestedDirectory,
            notARepository,
            "/does/not/exist",
            project.repositoryPath + "/.claude/worktrees/some-agent",
            herWorktreesRoot + "/os-greeting-abc123",
            excludedRoot + "/scratch",
        ]
        for (index, workingDirectory) in sessionWorkingDirectories.enumerated() {
            let directory = sessions + "/project-\(index)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let file = directory + "/session.jsonl"
            try "{\"type\":\"summary\"}\n{\"type\":\"user\",\"cwd\":\"\(workingDirectory)\"}\n"
                .write(toFile: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10))],
                                                  ofItemAtPath: file)
        }

        let found = await DelegationProjectLocator.mostRecentProject(
            claudeProjectsDirectoryPath: sessions,
            excludedPathPrefixes: [herWorktreesRoot, excludedRoot])

        // git names the repository by its canonical path (/private/var/…),
        // which is the path every later git command runs against.
        let repositoryAsGitReportsIt = await git(["rev-parse", "--show-toplevel"], in: project.repositoryPath)
        #expect(found == DelegationProject(repositoryPath: repositoryAsGitReportsIt))
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DelegationProgress] = []
    func append(_ progress: DelegationProgress) { lock.withLock { recorded.append(progress) } }
    var values: [DelegationProgress] { lock.withLock { recorded } }
}
