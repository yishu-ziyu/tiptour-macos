import Foundation
import Testing
@testable import TipTour

/// Every test stubs the selected CLI at the process seam: a real executable
/// script that emits JSONL events and makes (or skips) the same edits.
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

    /// Runs `body` in the worktree, then emits the selected CLI's JSONL events.
    private func makeStubAgent(body: String, events: [String], exitStatus: Int = 0) throws -> String {
        let directory = try makeTemporaryDirectory()
        let path = directory + "/agent"
        let printed = events.map { "print -r -- '\($0)'" }.joined(separator: "\n")
        try "#!/bin/zsh\n\(body)\n\(printed)\nexit \(exitStatus)\n".write(toFile: path, atomically: true, encoding: .utf8)
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
        let stub = try makeStubAgent(
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
        let stub = try makeStubAgent(body: ":", events: [successEvent])
        let delegation = CodingAgentDelegation(claudeCommand: stub, worktreesRootPath: try makeTemporaryDirectory())
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "noop")

        let receipt = await delegation.run(prompt: "change the greeting", in: workspace) { _ in }

        #expect(receipt.outcome == .noChange)
        #expect(receipt.changedFiles.isEmpty)
        #expect(receipt.agentSummary == "Done.")
    }

    @Test func uncommittedEditCountsAndIsCommittedOnMerge() async throws {
        let project = try await makeProject()
        let stub = try makeStubAgent(body: "print world > greeting.txt", events: [successEvent])
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
        let stub = try makeStubAgent(
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
        let stub = try makeStubAgent(body: "sleep 30", events: [successEvent])
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
        let stub = try makeStubAgent(body: "print rewritten > notes.txt; git commit -qam 'Rewrite notes'",
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
        let stub = try makeStubAgent(body: "print world > greeting.txt; git commit -qam 'Change greeting'",
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
        let stub = try makeStubAgent(
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

    // MARK: - Codex outcomes

    private var codexSuccessEvents: [String] {
        [#"{"type":"thread.started","thread_id":"codex-thread-1"}"#,
         #"{"type":"item.completed","item":{"type":"agent_message","text":"Changed greeting."}}"#,
         #"{"type":"turn.completed","usage":{"input_tokens":20,"output_tokens":10}}"#]
    }

    private func successEvents(for tool: DelegationAgentTool) -> [String] {
        switch tool {
        case .claudeCode: return [successEvent]
        case .codex: return codexSuccessEvents
        case .kimiCode: return AdditionalDelegationCLIEvents.kimiSuccess
        case .stepCode: return AdditionalDelegationCLIEvents.stepSuccess
        }
    }

    private func makeDelegation(command: String) throws -> CodingAgentDelegation {
        CodingAgentDelegation(claudeCommand: command, worktreesRootPath: try makeTemporaryDirectory(),
                              codexCommand: command, kimiCommand: command, stepCommand: command)
    }

    @Test(arguments: [DelegationAgentTool.kimiCode, .stepCode], [false, true])
    func additionalCLIResultRequiresRealEdits(tool: DelegationAgentTool, edits: Bool) async throws {
        let project = try await makeProject()
        let before = try await projectSnapshot(project)
        let prompt = "change greeting; $(false) `false` 'quoted'"
        let promptArgument = tool == .kimiCode ? "$2" : "$argv[-1]"
        let stub = try makeStubAgent(body: edits ? "print -r -- \"\(promptArgument)\" > greeting.txt" : ":", events: successEvents(for: tool))
        let delegation = try makeDelegation(command: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "additional")

        let receipt = await delegation.run(prompt: prompt, in: workspace, tool: tool) { _ in }

        #expect(receipt.agentTool == tool)
        #expect(receipt.outcome == (edits ? .changed : .noChange))
        #expect(receipt.changedFiles == (edits ? ["greeting.txt"] : []))
        #expect(receipt.agentSummary == "Changed greeting.")
        #expect(receipt.agentSessionID == (tool == .kimiCode ? "kimi-session" : "step-session"))
        #expect(try String(contentsOfFile: workspace.worktreePath + "/greeting.txt", encoding: .utf8) == (edits ? prompt + "\n" : "hello\n"))
        let after = try await projectSnapshot(project)
        #expect(after.head == before.head && after.status == before.status && after.notes == before.notes)
    }

    @Test func kimiUnfinishedToolCallRejectsEarlierAssistantText() async throws {
        let project = try await makeProject()
        let stub = try makeStubAgent(body: "print world > greeting.txt", events: [
            #"{"role":"assistant","content":"Changed greeting."}"#,
            AdditionalDelegationCLIEvents.kimiSuccess[1],
            AdditionalDelegationCLIEvents.kimiSuccess[2]])
        let delegation = try makeDelegation(command: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "truncated")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: .kimiCode) { _ in }

        guard case .agentFailed = receipt.outcome else {
            Issue.record("An unfinished Kimi tool call was treated as completion")
            return
        }
        #expect(receipt.changedFiles == ["greeting.txt"])
        #expect(receipt.agentTool == .kimiCode)
    }

    @Test(arguments: ["error", "aborted", "length", "toolUse"])
    func stepIncompleteOrFailedTerminalMessageNeverCountsAsChanged(stopReason: String) async throws {
        let project = try await makeProject()
        let stub = try makeStubAgent(body: "print world > greeting.txt", events: AdditionalDelegationCLIEvents.stepEvents(stopReason: stopReason))
        let delegation = try makeDelegation(command: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "step-failure")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: .stepCode) { _ in }

        guard case .agentFailed = receipt.outcome else {
            Issue.record("Step \(stopReason) was treated as completion")
            return
        }
        #expect(receipt.changedFiles == ["greeting.txt"])
        #expect(receipt.agentSessionID == "step-session")
        #expect(receipt.agentTool == .stepCode)
        #expect(receipt.agentSummary == "Changed greeting.")
    }

    @Test func stepMessageEndAloneIsNotAgentCompletion() async throws {
        let project = try await makeProject()
        let stub = try makeStubAgent(body: "print world > greeting.txt", events: Array(AdditionalDelegationCLIEvents.stepSuccess.dropLast()))
        let delegation = try makeDelegation(command: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "step-truncated")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: .stepCode) { _ in }

        guard case .agentFailed = receipt.outcome else {
            Issue.record("Step message_end without agent_end was treated as completion")
            return
        }
        #expect(receipt.changedFiles == ["greeting.txt"])
        #expect(receipt.agentSummary == "Changed greeting.")
    }

    @Test(arguments: [false, true])
    func stepToolFailureIsReportedUnlessALaterRunCompletes(recovered: Bool) async throws {
        let project = try await makeProject()
        var events = AdditionalDelegationCLIEvents.stepEvents(stopReason: recovered ? "stop" : "toolUse")
        events.insert(#"{"type":"tool_execution_end","toolCallId":"edit-1","toolName":"edit","result":{"content":[{"type":"text","text":"Edit requires approval"}]},"isError":true}"#, at: 2)
        let stub = try makeStubAgent(body: recovered ? "print world > greeting.txt" : ":", events: events, exitStatus: recovered ? 0 : 1)
        let delegation = try makeDelegation(command: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "step-tool-failure")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: .stepCode) { _ in }

        if recovered {
            #expect(receipt.outcome == .changed)
            #expect(receipt.changedFiles == ["greeting.txt"])
        } else {
            guard case .agentFailed(let reason) = receipt.outcome else {
                Issue.record("A denied Step edit was treated as completion")
                return
            }
            #expect(reason.contains("Edit requires approval"))
            #expect(receipt.changedFiles.isEmpty)
        }
        #expect(receipt.agentTool == .stepCode)
        #expect(receipt.agentSessionID == "step-session")
        #expect(try String(contentsOfFile: project.repositoryPath + "/greeting.txt", encoding: .utf8) == "hello\n")
    }

    @Test func codexEditsAreReadBackWithoutChangingTheUsersCheckout() async throws {
        let project = try await makeProject()
        let before = try await projectSnapshot(project)
        let prompt = "--change greeting; $(false) `false` 'quoted'"
        let stub = try makeStubAgent(body: """
            [[ "$#" == 13 && "$1" == --no-daemon && "$2" == -a && "$3" == never && "$4" == exec && "$5" == --sandbox && "$6" == workspace-write && "$7" == --json ]] || exit 19
            [[ "$8" == -m && "$9" == gpt-6-luna && "${10}" == -c && "${11}" == 'model_reasoning_effort="high"' ]] || exit 19
            [[ "${12}" == -- ]] || exit 19
            print -r -- "${13}" > greeting.txt
            """, events: codexSuccessEvents)
        let delegation = CodingAgentDelegation(worktreesRootPath: try makeTemporaryDirectory(), codexCommand: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "codex")

        let receipt = await delegation.run(prompt: prompt, in: workspace, tool: .codex) { _ in }

        #expect(receipt.outcome == .changed)
        #expect(receipt.agentTool == .codex)
        #expect(receipt.agentSessionID == "codex-thread-1")
        #expect(receipt.agentSummary == "Changed greeting.")
        #expect(receipt.costInUSD == nil)
        #expect(receipt.durationMilliseconds == nil)
        #expect(receipt.changedFiles == ["greeting.txt"])
        #expect(try String(contentsOfFile: workspace.worktreePath + "/greeting.txt", encoding: .utf8) == prompt + "\n")
        let after = try await projectSnapshot(project)
        #expect(after.head == before.head && after.status == before.status && after.notes == before.notes)
    }

    @Test func codexClaimWithoutEditsIsNoChange() async throws {
        let project = try await makeProject()
        let stub = try makeStubAgent(body: ":", events: codexSuccessEvents)
        let delegation = CodingAgentDelegation(worktreesRootPath: try makeTemporaryDirectory(), codexCommand: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "codex")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: .codex) { _ in }

        #expect(receipt.outcome == .noChange)
        #expect(receipt.changedFiles.isEmpty)
        #expect(receipt.agentSummary == "Changed greeting.")
    }

    @Test func codexTerminalFailureRetainsRealEditsAndSession() async throws {
        let project = try await makeProject()
        let stub = try makeStubAgent(body: "print world > greeting.txt", events: [
            codexSuccessEvents[0],
            #"{"type":"error","message":"Retrying transport"}"#,
            #"{"type":"turn.failed","error":{"message":"Authentication failed"}}"#])
        let delegation = CodingAgentDelegation(worktreesRootPath: try makeTemporaryDirectory(), codexCommand: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "codex")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: .codex) { _ in }

        #expect(receipt.outcome == .agentFailed(reason: "Authentication failed"))
        #expect(receipt.changedFiles == ["greeting.txt"])
        #expect(receipt.agentSessionID == "codex-thread-1")
    }

    @Test func codexTruncatedOutputIsFailedEvenWithRealEdits() async throws {
        let project = try await makeProject()
        let stub = try makeStubAgent(body: "print world > greeting.txt", events: Array(codexSuccessEvents.prefix(2)))
        let delegation = CodingAgentDelegation(worktreesRootPath: try makeTemporaryDirectory(), codexCommand: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "codex")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: .codex) { _ in }

        guard case .agentFailed(let reason) = receipt.outcome else {
            Issue.record("Truncated Codex output was treated as success")
            return
        }
        #expect(reason.contains("没有给出最终结果"))
        #expect(receipt.changedFiles == ["greeting.txt"])
        #expect(receipt.agentSummary == "Changed greeting.")
    }

    @Test(arguments: [DelegationAgentTool.claudeCode, .codex, .kimiCode, .stepCode])
    func nonzeroExitIsFailedDespiteCompletedEvent(tool: DelegationAgentTool) async throws {
        let project = try await makeProject()
        let stub = try makeStubAgent(body: "print world > greeting.txt", events: successEvents(for: tool), exitStatus: 7)
        let delegation = try makeDelegation(command: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "failure")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: tool) { _ in }

        guard case .agentFailed(let reason) = receipt.outcome else {
            Issue.record("Nonzero CLI exit was treated as success")
            return
        }
        #expect(reason.contains("退出码 7"))
        #expect(receipt.agentTool == tool)
        #expect(receipt.changedFiles == ["greeting.txt"])
    }

    @Test func codexWarningsAndLargeStderrDoNotBlockSuccessfulReadback() async throws {
        let project = try await makeProject()
        let stub = try makeStubAgent(body: "head -c 262144 /dev/zero >&2; print world > greeting.txt", events: [
            #"{"type":"item.completed","item":{"type":"error","message":"Optional MCP unavailable"}}"#,
            #"{"type":"error","message":"Transient retry"}"#] + codexSuccessEvents)
        let delegation = CodingAgentDelegation(worktreesRootPath: try makeTemporaryDirectory(), codexCommand: stub)
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "codex")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: .codex) { _ in }

        #expect(receipt.outcome == .changed)
        #expect(receipt.agentSummary == "Changed greeting.")
    }

    @Test(arguments: [DelegationAgentTool.codex, .kimiCode, .stepCode])
    func missingSelectedCommandIsFailedWithoutFallback(tool: DelegationAgentTool) async throws {
        let project = try await makeProject()
        let claudeStub = try makeStubAgent(body: "print fallback > greeting.txt", events: [successEvent])
        let delegation = CodingAgentDelegation(claudeCommand: claudeStub, worktreesRootPath: try makeTemporaryDirectory(),
                                               codexCommand: "/nonexistent/codex", kimiCommand: "/nonexistent/kimi", stepCommand: "/nonexistent/step")
        let workspace = try await delegation.prepareWorkspace(for: project, taskSlug: "missing")

        let receipt = await delegation.run(prompt: "change greeting", in: workspace, tool: tool) { _ in }

        guard case .agentFailed(let reason) = receipt.outcome else {
            Issue.record("Missing \(tool.displayName) command was not failed")
            return
        }
        #expect(reason.contains("/nonexistent/"))
        #expect(receipt.changedFiles.isEmpty)
        #expect(receipt.agentTool == tool)
        #expect(try String(contentsOfFile: workspace.worktreePath + "/greeting.txt", encoding: .utf8) == "hello\n")
    }

    @Test(arguments: [DelegationAgentTool.codex, .kimiCode, .stepCode])
    func cancellingSelectedToolDoesNotStopAnotherDelegation(tool: DelegationAgentTool) async throws {
        let project = try await makeProject()
        let slowStub = try makeStubAgent(body: "sleep 30", events: successEvents(for: tool))
        let independentStub = try makeStubAgent(body: "sleep 1; print world > greeting.txt", events: successEvents(for: tool))
        let cancelledDelegation = try makeDelegation(command: slowStub)
        let independentDelegation = try makeDelegation(command: independentStub)
        let cancelledWorkspace = try await cancelledDelegation.prepareWorkspace(for: project, taskSlug: "cancelled")
        let independentWorkspace = try await independentDelegation.prepareWorkspace(for: project, taskSlug: "independent")
        let started = Date()

        async let cancelledReceipt = cancelledDelegation.run(prompt: "wait", in: cancelledWorkspace, tool: tool) { _ in }
        async let independentReceipt = independentDelegation.run(prompt: "change", in: independentWorkspace, tool: tool) { _ in }
        try await Task.sleep(nanoseconds: 500_000_000)
        cancelledDelegation.cancel()

        #expect(await cancelledReceipt.outcome == .cancelled)
        #expect(await independentReceipt.outcome == .changed)
        #expect(Date().timeIntervalSince(started) < 10)
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

enum AdditionalDelegationCLIEvents {
    static let kimiSuccess = [
        #"{"role":"meta","type":"system.version","version":"0.42.0"}"#,
        #"{"role":"assistant","tool_calls":[{"type":"function","id":"edit-1","function":{"name":"Edit","arguments":"{}"}}]}"#,
        #"{"role":"tool","tool_call_id":"edit-1","content":"Updated greeting.txt"}"#,
        #"{"role":"assistant","content":"Changed greeting."}"#,
        #"{"role":"meta","type":"session.resume_hint","session_id":"kimi-session"}"#
    ]

    // Step fixtures follow the installed CLI's docs/json.md and session-format.md.
    static var stepSuccess: [String] { stepEvents(stopReason: "stop") }

    static func stepEvents(stopReason: String) -> [String] {
        let message: [String: Any] = [
            "role": "assistant", "provider": "step", "model": "configured-model", "stopReason": stopReason,
            "content": [["type": "thinking", "thinking": "Private reasoning"],
                        ["type": "text", "text": "Changed greeting."]]
        ]
        let events: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "step-session", "timestamp": "2026-09-26T12:00:00Z", "cwd": "/fixture"],
            ["type": "agent_start"], ["type": "message_end", "message": message],
            ["type": "agent_end", "messages": [message]]
        ]
        return events.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DelegationProgress] = []
    func append(_ progress: DelegationProgress) { lock.withLock { recorded.append(progress) } }
    var values: [DelegationProgress] { lock.withLock { recorded } }
}
