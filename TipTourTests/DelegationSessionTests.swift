import Foundation
import Testing
@testable import TipTour

/// The model is stubbed at its URL seam (a URLProtocol answering the StepFun
/// endpoint with scripted replies); Claude Code is a stub executable; git and
/// the worktrees are real. Assertions read what the user would see and what
/// the repository really holds.
@Suite(.serialized)
@MainActor
struct DelegationSessionTests {
    private func makeTemporaryDirectory() throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("her-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func makeProject(directoryName: String? = nil) async throws -> DelegationProject {
        var repository = try makeTemporaryDirectory()
        if let directoryName {
            repository += "/" + directoryName
            try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        }
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "T"]] {
            _ = await DelegationCommand.git(arguments, inDirectory: repository)
        }
        try "hello\n".write(toFile: repository + "/greeting.txt", atomically: true, encoding: .utf8)
        _ = await DelegationCommand.git(["add", "."], inDirectory: repository)
        _ = await DelegationCommand.git(["commit", "-q", "-m", "init"], inDirectory: repository)
        let root = await DelegationCommand.git(["rev-parse", "--show-toplevel"], inDirectory: repository)
        try #require(root.exitStatus == 0)
        return DelegationProject(repositoryPath: root.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func makeStubClaude(body: String, summary: String = "Done.") throws -> String {
        let path = try makeTemporaryDirectory() + "/claude"
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"\#(summary)","total_cost_usd":0.2,"duration_ms":4000,"session_id":"s"}"#
        try "#!/bin/zsh\n\(body)\nprint -r -- '\(result)'\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func makeStubCodex(body: String) throws -> String {
        let path = try makeTemporaryDirectory() + "/codex"
        let script = """
        #!/bin/zsh
        \(body)
        print -r -- '{"type":"thread.started","thread_id":"codex-session"}'
        print -r -- '{"type":"item.completed","item":{"type":"agent_message","text":"Changed the greeting."}}'
        print -r -- '{"type":"turn.completed","usage":{"input_tokens":20,"output_tokens":5}}'
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func makeStubAdditionalCLI(body: String, tool: DelegationAgentTool) throws -> String {
        let path = try makeTemporaryDirectory() + "/" + tool.rawValue
        let events = tool == .kimiCode ? AdditionalDelegationCLIEvents.kimiSuccess : AdditionalDelegationCLIEvents.stepSuccess
        let printed = events.map { "print -r -- '\($0)'" }.joined(separator: "\n")
        try "#!/bin/zsh\n\(body)\n\(printed)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func modelReply(say: String, action: String = "none", draft: String = "", screenGoal: String = "") -> String {
        let content = try! JSONSerialization.data(withJSONObject: ["say": say, "action": action, "draft": draft, "screen_goal": screenGoal])
        return String(decoding: content, as: UTF8.self)
    }

    private func makeSession(
        project: DelegationProject?,
        claude: String,
        codex: String = "/nonexistent/codex",
        kimi: String = "/nonexistent/kimi",
        step: String = "/nonexistent/step",
        replies: [String],
        findProject: (@MainActor () async -> DelegationProject?)? = nil,
        screenGoals: ScreenGoalRecorder? = nil
    ) throws -> DelegationSession {
        ScriptedStepFun.queue(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedStepFun.self]
        let client = DelegationModelClient(apiKey: "test-key", session: URLSession(configuration: configuration))
        let conversation = DelegationConversation(complete: { try await client.complete($0) })
        let delegation = CodingAgentDelegation(claudeCommand: claude, worktreesRootPath: try makeTemporaryDirectory(),
                                               codexCommand: codex, kimiCommand: kimi, stepCommand: step)
        return DelegationSession(conversation: conversation, delegation: delegation,
                                 findProject: findProject ?? { project }, onScreenGoal: { screenGoals?.goals.append($0) })
    }

    private func herLines(_ session: DelegationSession) -> [String] {
        session.entries.compactMap {
            if case .message(_, .her, let text) = $0 { return text }
            return nil
        }
    }

    private func reports(_ session: DelegationSession) -> [DelegationReport] {
        session.entries.compactMap {
            if case .report(_, let report) = $0 { return report }
            return nil
        }
    }

    private func greeting(_ project: DelegationProject) throws -> String {
        try String(contentsOfFile: project.repositoryPath + "/greeting.txt", encoding: .utf8)
    }

    private func waitForFile(at path: String) async throws -> Bool {
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: path) { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // MARK: -

    @Test func vagueRequestGetsAQuestionAndNothingRuns() async throws {
        let project = try await makeProject()
        let session = try makeSession(project: project, claude: try makeStubClaude(body: "print world > greeting.txt"),
                                      replies: [modelReply(say: "改哪个文件？改成什么？")])

        await session.send("帮我改一下")

        #expect(herLines(session) == ["改哪个文件？改成什么？"])
        #expect(session.phase == .idle)
        #expect(reports(session).isEmpty)
        #expect(try greeting(project) == "hello\n")
    }

    @Test func draftWaitsForTheUserAndOnlySendingRunsClaudeCode() async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project,
            claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿，没问题就点发出去。", action: "draft", draft: "把 greeting.txt 改成 world")])

        await session.send("把问候语改成 world")
        #expect(session.phase == .awaitingSend)
        #expect(reports(session).isEmpty, "Nothing may run before the user sends the draft")

        await session.sendCurrentDraft()
        #expect(session.phase == .awaitingDecision)
        let report = try #require(reports(session).first)
        #expect(report.receipt.outcome == .changed)
        #expect(report.headline == "工作区里有改动：涉及 1 个文件。确认后再合进项目。")
        #expect(herLines(session).contains { $0.hasPrefix("交给 Claude Code 了") })
        #expect(try greeting(project) == "hello\n", "Nothing reaches the project before the user merges")

        await session.mergePendingChange()
        #expect(try greeting(project) == "world\n")
        #expect(session.phase == .idle)
    }

    @Test func claimedSuccessWithoutChangesIsReportedAsNotDone() async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: ":", summary: "All done."),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "把 greeting.txt 改成 world")])

        await session.send("把问候语改成 world")
        await session.sendCurrentDraft()

        let report = try #require(reports(session).first)
        #expect(report.headline.contains("不算做成"))
        #expect(!report.headline.contains("工作区里有改动"))
        #expect(session.phase == .idle)
    }

    @Test(arguments: [DelegationAgentTool.codex, .kimiCode, .stepCode])
    func chosenToolSurvivesRevisionAndItsResultWaitsForTheUser(tool: DelegationAgentTool) async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project,
            claude: try makeStubClaude(body: "print wrong-tool > greeting.txt"),
            codex: try makeStubCodex(body: "print world > greeting.txt"),
            kimi: try makeStubAdditionalCLI(body: "print world > greeting.txt", tool: .kimiCode),
            step: try makeStubAdditionalCLI(body: "print world > greeting.txt", tool: .stepCode),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改问候语"),
                      modelReply(say: "草稿改好了。", action: "draft", draft: "只改问候语为 world")])

        await session.send("改问候语")
        session.selectAgentTool(tool)
        let selectedDraft = try #require(session.entries.last)
        #expect(selectedDraft == .draft(id: selectedDraft.id, text: "改问候语",
                                         project: project, tool: tool, isCurrent: true))
        #expect(reports(session).isEmpty)
        #expect(try greeting(project) == "hello\n")

        await session.send("只改问候语为 world")
        let revisedDraft = try #require(session.entries.last)
        #expect(revisedDraft == .draft(id: revisedDraft.id, text: "只改问候语为 world",
                                        project: project, tool: tool, isCurrent: true))
        #expect(ScriptedStepFun.systemMessages.last?.contains("当前选的是 \(tool.displayName)") == true)
        await session.sendCurrentDraft()

        let report = try #require(reports(session).first)
        #expect(report.receipt.agentTool == tool)
        #expect(report.receipt.outcome == .changed)
        let expectedSessionID = tool == .codex ? "codex-session" : tool == .kimiCode ? "kimi-session" : "step-session"
        #expect(report.receipt.agentSessionID == expectedSessionID)
        #expect(herLines(session).contains { $0.hasPrefix("交给 \(tool.displayName) 了") })
        #expect(!herLines(session).contains { $0.hasPrefix("交给 Claude Code 了") })
        #expect(try greeting(project) == "hello\n")
        session.startOver()
        session.selectAgentTool(.claudeCode)
        #expect(session.selectedAgentTool == tool)
        #expect(reports(session) == [report])
        #expect(session.phase == .awaitingDecision)

        await session.mergePendingChange()
        #expect(try greeting(project) == "world\n")
    }

    @Test(arguments: [DelegationAgentTool.codex, .kimiCode, .stepCode])
    func unavailableSelectedToolDoesNotFallBackToClaude(tool: DelegationAgentTool) async throws {
        let project = try await makeProject()
        let marker = try makeTemporaryDirectory() + "/claude-ran"
        let session = try makeSession(
            project: project,
            claude: try makeStubClaude(body: "touch '\(marker)'; print wrong-tool > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改问候语")])
        await session.send("改问候语")
        session.selectAgentTool(tool)
        await session.sendCurrentDraft()

        let report = try #require(reports(session).first)
        #expect(report.receipt.agentTool == tool)
        guard case .agentFailed = report.receipt.outcome else {
            Issue.record("A missing selected \(tool.displayName) must be reported as failure")
            return
        }
        #expect(report.headline.hasPrefix("没做成"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(try greeting(project) == "hello\n")
        #expect(session.phase == .idle)
    }

    @Test(arguments: [DelegationAgentTool.codex, .kimiCode, .stepCode])
    func selectedClaimWithoutAnEditNamesTheToolAndDoesNotOfferMerge(tool: DelegationAgentTool) async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project, claude: "/nonexistent/claude", codex: try makeStubCodex(body: ":"),
            kimi: try makeStubAdditionalCLI(body: ":", tool: .kimiCode),
            step: try makeStubAdditionalCLI(body: ":", tool: .stepCode),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改问候语")])
        await session.send("改问候语")
        session.selectAgentTool(tool)
        await session.sendCurrentDraft()

        let report = try #require(reports(session).first)
        #expect(report.headline == "\(tool.displayName) 说做完了，但工作区里没有任何改动，这次不算做成。")
        #expect(report.receipt.agentTool == tool)
        #expect(report.costText == nil)
        #expect(session.phase == .idle)
        #expect(try greeting(project) == "hello\n")
    }

    @Test func sendingUsesTheProjectTheDraftWasWrittenFor() async throws {
        let originalProject = try await makeProject()
        let recentProject = try await makeProject()
        var currentProject = originalProject
        let session = try makeSession(
            project: originalProject,
            claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "把 greeting.txt 改成 world")],
            findProject: { currentProject })

        await session.send("把问候语改成 world")
        let draftEntry = try #require(session.entries.last)
        #expect(draftEntry == .draft(id: draftEntry.id, text: "把 greeting.txt 改成 world",
                                     project: originalProject, isCurrent: true))
        currentProject = recentProject
        await session.sendCurrentDraft()

        let receipt = try #require(reports(session).first).receipt
        #expect(receipt.workspace.project == originalProject)
        #expect(try String(contentsOfFile: receipt.workspace.worktreePath + "/greeting.txt", encoding: .utf8) == "world\n")
        await session.mergePendingChange()
        #expect(try greeting(originalProject) == "world\n")
        #expect(try greeting(recentProject) == "hello\n")
    }

    @Test func revisingKeepsTheDraftProjectAndSendsTheRevisedRequest() async throws {
        let originalProject = try await makeProject()
        let recentProject = try await makeProject()
        var currentProject = originalProject
        let session = try makeSession(
            project: originalProject,
            claude: try makeStubClaude(body: "print -r -- \"$2\" > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world"),
                      modelReply(say: "草稿改好了。", action: "draft", draft: "改成 goodbye")],
            findProject: { currentProject })

        await session.send("把问候语改成 world")
        currentProject = recentProject
        await session.send("换成 goodbye")

        let draftProjects = session.entries.compactMap { entry -> DelegationProject? in
            if case .draft(_, _, let project, _, _) = entry { return project }
            return nil
        }
        #expect(draftProjects == [originalProject, originalProject])
        let revisionContext = try #require(ScriptedStepFun.systemMessages.last)
        #expect(revisionContext.contains("路径：\(originalProject.repositoryPath)"))
        #expect(!revisionContext.contains("路径：\(recentProject.repositoryPath)"))
        await session.sendCurrentDraft()
        let receipt = try #require(reports(session).first).receipt
        #expect(receipt.workspace.project == originalProject)
        let sentRequest = try String(contentsOfFile: receipt.workspace.worktreePath + "/greeting.txt", encoding: .utf8)
        #expect(sentRequest.hasSuffix("\n\n改成 goodbye\n"))
        #expect(sentRequest.contains("唯一允许修改的当前副本：\(receipt.workspace.worktreePath)"))
        #expect(sentRequest.contains("原项目路径：\(originalProject.repositoryPath)（仅用于识别项目）"))
        #expect(sentRequest.contains("不得返回原目录修改，不得重建工作区、合并或推送"))
        #expect(try greeting(originalProject) == "hello\n")
        await session.mergePendingChange()
        #expect(try greeting(originalProject) == sentRequest)
        #expect(try greeting(recentProject) == "hello\n")
    }

    @Test func aDraftWithoutAProjectDoesNotAdoptALaterProject() async throws {
        let recentProject = try await makeProject()
        var currentProject: DelegationProject?
        let session = try makeSession(
            project: nil,
            claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world"),
                      modelReply(say: "草稿改好了。", action: "draft", draft: "改成 goodbye")],
            findProject: { currentProject })

        await session.send("把问候语改成 world")
        currentProject = recentProject
        await session.send("换成 goodbye")
        await session.sendCurrentDraft()

        let draftEntry = try #require(session.entries.last(where: { if case .draft = $0 { return true }; return false }))
        #expect(draftEntry == .draft(id: draftEntry.id, text: "改成 goodbye", project: nil, isCurrent: true))
        let revisionContext = try #require(ScriptedStepFun.systemMessages.last)
        #expect(revisionContext.contains("还没找到项目"))
        #expect(herLines(session).last?.contains("选择项目") == true)
        #expect(session.phase == .awaitingSend)
        #expect(reports(session).isEmpty)
        #expect(try greeting(recentProject) == "hello\n")
    }

    @Test func explicitlyChosenProjectSurvivesRevisionAndToolSelection() async throws {
        let recentProject = try await makeProject()
        let targetProject = try await makeProject(directoryName: "Her 项目 中文")
        let confirmedRequest = "Her 项目 \(targetProject.repositoryPath) 的 greeting.txt 改成 world"
        let childPath = targetProject.repositoryPath + "/子目录 空格"
        try FileManager.default.createDirectory(atPath: childPath, withIntermediateDirectories: true)
        let session = try makeSession(
            project: recentProject,
            claude: try makeStubClaude(body: "print wrong-tool > greeting.txt"),
            codex: try makeStubCodex(body: "print -r -- \"$argv[-1]\" > outbound.txt; print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改问候语"),
                      modelReply(say: "草稿改好了。", action: "draft", draft: confirmedRequest)])
        await session.send("改问候语")
        await session.selectDraftProject(childPath)
        let selectedDraft = try #require(session.entries.last(where: { if case .draft = $0 { return true }; return false }))
        #expect(selectedDraft == .draft(id: selectedDraft.id, text: "改问候语", project: targetProject, isCurrent: true))
        #expect(session.phase == .awaitingSend)
        #expect(reports(session).isEmpty)
        let worktreesBeforeSend = await DelegationCommand.git(["worktree", "list", "--porcelain"], inDirectory: targetProject.repositoryPath)
        #expect(worktreesBeforeSend.standardOutput.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count == 1)

        session.selectAgentTool(.codex)
        await session.send("只改这个项目的问候语")
        let revisedDraft = try #require(session.entries.last)
        #expect(revisedDraft == .draft(id: revisedDraft.id, text: confirmedRequest, project: targetProject, tool: .codex, isCurrent: true))
        #expect(ScriptedStepFun.systemMessages.last?.contains("路径：\(targetProject.repositoryPath)") == true)
        await session.sendCurrentDraft()
        let receipt = try #require(reports(session).first).receipt
        #expect(receipt.workspace.project == targetProject)
        #expect(receipt.agentTool == .codex)
        #expect(receipt.outcome == .changed)
        #expect(try String(contentsOfFile: receipt.workspace.worktreePath + "/greeting.txt", encoding: .utf8) == "world\n")
        let outbound = try String(contentsOfFile: receipt.workspace.worktreePath + "/outbound.txt", encoding: .utf8)
        #expect(outbound.hasSuffix("\n\n\(confirmedRequest)\n"))
        #expect(outbound.contains("唯一允许修改的当前副本：\(receipt.workspace.worktreePath)"))
        #expect(outbound.contains("原项目路径：\(targetProject.repositoryPath)（仅用于识别项目）"))
        #expect(outbound.contains("不得返回原目录修改，不得重建工作区、合并或推送"))
        #expect(try greeting(targetProject) == "hello\n")
        #expect(try greeting(recentProject) == "hello\n")
        await session.mergePendingChange()
        #expect(try greeting(targetProject) == "world\n")
        #expect(try greeting(recentProject) == "hello\n")
    }

    @Test(arguments: [false, true])
    func invalidProjectSelectionPreservesDraftAndExplicitRetryRecovers(initiallyMissing: Bool) async throws {
        let originalProject = try await makeProject()
        let targetProject = try await makeProject(directoryName: "新项目 空格")
        let marker = try makeTemporaryDirectory() + "/ran"
        let session = try makeSession(
            project: initiallyMissing ? nil : originalProject,
            claude: "/nonexistent/claude",
            codex: try makeStubCodex(body: "touch '\(marker)'; print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")])
        await session.send("改问候语")
        session.selectAgentTool(.codex)
        let originalDraft = try #require(session.entries.last)
        await session.selectDraftProject(try makeTemporaryDirectory())
        #expect(session.entries.contains(originalDraft))
        #expect(session.phase == .awaitingSend)
        #expect(session.selectedAgentTool == .codex)
        #expect(herLines(session).last?.hasPrefix("没能选择这个项目") == true)
        #expect(reports(session).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker))
        await session.selectDraftProject(targetProject.repositoryPath + "/不存在")
        #expect(session.entries.contains(originalDraft))
        #expect(session.phase == .awaitingSend)
        #expect(!FileManager.default.fileExists(atPath: marker))

        await session.selectDraftProject(targetProject.repositoryPath)
        let selectedDraft = try #require(session.entries.last(where: { if case .draft = $0 { return true }; return false }))
        #expect(selectedDraft == .draft(id: originalDraft.id, text: "改成 world", project: targetProject, tool: .codex, isCurrent: true))
        await session.sendCurrentDraft()
        let receipt = try #require(reports(session).first).receipt
        #expect(receipt.workspace.project == targetProject)
        #expect(receipt.outcome == .changed)
        #expect(try greeting(originalProject) == "hello\n")
        #expect(try greeting(targetProject) == "hello\n")
        await session.discardPendingChange()
    }

    @Test(arguments: [false, true])
    func startingOverCanChooseTheNewRecentProject(initiallyMissing: Bool) async throws {
        let originalProject = try await makeProject()
        let recentProject = try await makeProject()
        var currentProject: DelegationProject? = initiallyMissing ? nil : originalProject
        let session = try makeSession(
            project: currentProject,
            claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 goodbye"),
                      modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")],
            findProject: { currentProject })

        await session.send("把问候语改成 goodbye")
        await session.selectDraftProject(originalProject.repositoryPath)
        currentProject = recentProject
        session.startOver()
        await session.send("把问候语改成 world")
        await session.sendCurrentDraft()

        let receipt = try #require(reports(session).first).receipt
        #expect(receipt.workspace.project == recentProject)
        await session.mergePendingChange()
        #expect(try greeting(recentProject) == "world\n")
        #expect(try greeting(originalProject) == "hello\n")
    }

    @Test func failedRunKeepsTheExplicitProjectAndCodexForTheNextDraft() async throws {
        let recentProject = try await makeProject()
        let selectedProject = try await makeProject(directoryName: "Her 项目 中文")
        let marker = try makeTemporaryDirectory() + "/first-attempt"
        let session = try makeSession(
            project: recentProject, claude: "/nonexistent/claude",
            codex: try makeStubCodex(body: """
            if [[ ! -f '\(marker)' ]]; then
                touch '\(marker)'
                print -r -- '{"type":"turn.failed","error":{"message":"502 Bad Gateway"}}'
                exit 1
            fi
            print world > greeting.txt
            """),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world"),
                      modelReply(say: "同一份草稿。", action: "draft", draft: "改成 world")])
        await session.send("改问候语")
        session.selectAgentTool(.codex)
        await session.selectDraftProject(selectedProject.repositoryPath)
        await session.selectDraftProject(selectedProject.repositoryPath + "/不存在")
        await session.sendCurrentDraft()
        let failure = try #require(reports(session).first).receipt
        guard case .agentFailed(let reason) = failure.outcome else {
            Issue.record("The first attempt must report the CLI's failure")
            return
        }
        #expect(reason.contains("502"))
        #expect(failure.workspace.project == selectedProject)
        #expect(failure.agentTool == .codex)
        #expect(session.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: failure.workspace.worktreePath))

        await session.send("为刚才失败任务重新生成同一草稿")
        let retryDraft = try #require(session.entries.last)
        #expect(retryDraft == .draft(id: retryDraft.id, text: "改成 world", project: selectedProject, tool: .codex, isCurrent: true))
        #expect(ScriptedStepFun.systemMessages.last?.contains("路径：\(selectedProject.repositoryPath)") == true)
        await session.sendCurrentDraft()
        let retry = try #require(reports(session).last).receipt
        #expect(retry.workspace.project == selectedProject)
        #expect(retry.agentTool == .codex)
        #expect(retry.outcome == .changed)
        #expect(try String(contentsOfFile: retry.workspace.worktreePath + "/greeting.txt", encoding: .utf8) == "world\n")
        #expect(try greeting(selectedProject) == "hello\n")
        #expect(try greeting(recentProject) == "hello\n")
        await session.mergePendingChange()
        #expect(try greeting(selectedProject) == "world\n")
        #expect(try greeting(recentProject) == "hello\n")
    }

    @Test(arguments: [DelegationAgentTool.claudeCode, .kimiCode, .stepCode])
    func preparingPreservesTheSelectedToolAndRejectsReentry(tool: DelegationAgentTool) async throws {
        let project = try await makeProject()
        let controls = try makeTemporaryDirectory()
        let enteredPath = controls + "/entered"
        let releasePath = controls + "/release"
        let hookPath = project.repositoryPath + "/.git/hooks/post-checkout"
        let hook = """
        #!/bin/zsh
        print entered > '\(enteredPath)'
        for attempt in {1..1000}; do
            [[ -f '\(releasePath)' ]] && exit 0
            sleep 0.01
        done
        exit 1
        """
        try hook.write(toFile: hookPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
        defer { try? "release".write(toFile: releasePath, atomically: true, encoding: .utf8) }
        let session = try makeSession(
            project: project,
            claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            kimi: try makeStubAdditionalCLI(body: "print world > greeting.txt", tool: .kimiCode),
            step: try makeStubAdditionalCLI(body: "print world > greeting.txt", tool: .stepCode),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")])
        await session.send("把问候语改成 world")
        session.selectAgentTool(tool)
        let draftEntries = session.entries
        let sending = Task { await session.sendCurrentDraft() }
        let hookEntered = try await waitForFile(at: enteredPath)
        try #require(hookEntered)

        #expect(session.phase == .preparing)
        #expect(session.isBusy)
        await session.sendCurrentDraft()
        await session.send("改另一个任务")
        session.startOver()
        session.selectAgentTool(.codex)
        await session.selectDraftProject(try makeTemporaryDirectory())
        #expect(session.entries == draftEntries)
        #expect(session.phase == .preparing)
        #expect(session.selectedAgentTool == tool)

        try "release".write(toFile: releasePath, atomically: true, encoding: .utf8)
        await sending.value
        let receipt = try #require(reports(session).first).receipt
        #expect(receipt.workspace.project == project)
        #expect(receipt.agentTool == tool)
        #expect(receipt.outcome == .changed)
        let worktrees = await DelegationCommand.git(["worktree", "list", "--porcelain"], inDirectory: project.repositoryPath)
        #expect(worktrees.standardOutput.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count == 2)
        #expect(try String(contentsOfFile: receipt.workspace.worktreePath + "/greeting.txt", encoding: .utf8) == "world\n")
        await session.mergePendingChange()
        #expect(try greeting(project) == "world\n")
    }

    @Test func failedPreparationKeepsTheBoundDraftForRetry() async throws {
        let originalProject = try await makeProject()
        let recentProject = try await makeProject()
        var currentProject = originalProject
        let session = try makeSession(
            project: originalProject,
            claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")],
            findProject: { currentProject })
        await session.send("把问候语改成 world")
        let originalDraft = try #require(session.entries.last)
        let gitPath = originalProject.repositoryPath + "/.git"
        let unavailableGitPath = originalProject.repositoryPath + "/.git-unavailable"
        try FileManager.default.moveItem(atPath: gitPath, toPath: unavailableGitPath)
        defer { try? FileManager.default.moveItem(atPath: unavailableGitPath, toPath: gitPath) }

        await session.sendCurrentDraft()

        #expect(session.phase == .awaitingSend)
        #expect(session.entries.contains(originalDraft))
        #expect(herLines(session).last?.hasPrefix("没能建好工作区") == true)
        #expect(reports(session).isEmpty)
        currentProject = recentProject
        try FileManager.default.moveItem(atPath: unavailableGitPath, toPath: gitPath)
        await session.sendCurrentDraft()
        let receipt = try #require(reports(session).first).receipt
        #expect(receipt.workspace.project == originalProject)
        await session.mergePendingChange()
        #expect(try greeting(originalProject) == "world\n")
        #expect(try greeting(recentProject) == "hello\n")
    }

    @Test func runningRejectsProjectChangesAndLeavesBothProjectsUntouched() async throws {
        let originalProject = try await makeProject()
        let otherProject = try await makeProject()
        let controls = try makeTemporaryDirectory()
        let enteredPath = controls + "/entered"
        let releasePath = controls + "/release"
        let session = try makeSession(
            project: originalProject,
            claude: try makeStubClaude(body: """
            touch '\(enteredPath)'
            for attempt in {1..1000}; do
                [[ -f '\(releasePath)' ]] && break
                sleep 0.01
            done
            print world > greeting.txt
            """),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")])
        defer { try? "release".write(toFile: releasePath, atomically: true, encoding: .utf8) }
        await session.send("改问候语")
        let sending = Task { await session.sendCurrentDraft() }
        let entered = try await waitForFile(at: enteredPath)
        try #require(entered)
        guard case .running = session.phase else {
            Issue.record("The executor must still be running")
            return
        }
        let runningEntries = session.entries
        await session.selectDraftProject(otherProject.repositoryPath)
        #expect(session.entries == runningEntries)
        #expect(try greeting(originalProject) == "hello\n")
        #expect(try greeting(otherProject) == "hello\n")
        try "release".write(toFile: releasePath, atomically: true, encoding: .utf8)
        await sending.value
        let receipt = try #require(reports(session).first).receipt
        #expect(receipt.workspace.project == originalProject)
        #expect(receipt.outcome == .changed)
        #expect(try String(contentsOfFile: receipt.workspace.worktreePath + "/greeting.txt", encoding: .utf8) == "world\n")
        await session.discardPendingChange()
    }

    @Test(arguments: DelegationAgentTool.allCases)
    func promiseWithoutADraftIsCorrectedOnce(tool: DelegationAgentTool) async throws {
        let project = try await makeProject()
        let promise = "好的，交给 \(tool.displayName)。"
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: ":"),
            replies: [modelReply(say: promise),
                      modelReply(say: "草稿在这，确认后点发出去。", action: "draft", draft: "把 greeting.txt 改成 world")])

        await session.send("把问候语改成 world")

        #expect(session.phase == .awaitingSend)
        #expect(herLines(session) == ["草稿在这，确认后点发出去。"])
        let draft = try #require(session.entries.last)
        #expect(draft == .draft(id: draft.id, text: "把 greeting.txt 改成 world", project: project, isCurrent: true))
        #expect(ScriptedStepFun.remaining == 0)
        #expect(reports(session).isEmpty)
        #expect(try greeting(project) == "hello\n")
    }

    @Test(arguments: [false, true])
    func aPendingChangeKeepsItsDecisionBeforeAnotherTask(shouldMerge: Bool) async throws {
        let originalProject = try await makeProject()
        let recentProject = try await makeProject()
        var currentProject = originalProject
        let session = try makeSession(
            project: originalProject,
            claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world"),
                      modelReply(say: "第二份草稿在这里。", action: "draft", draft: "也改成 world"),
                      modelReply(say: "只改了问候语。"),
                      modelReply(say: "看一眼草稿。", action: "draft", draft: "也改成 world")],
            findProject: { currentProject })

        await session.send("把问候语改成 world")
        await session.sendCurrentDraft()
        let pendingReport = try #require(reports(session).first)
        let pendingWorktree = pendingReport.receipt.workspace.worktreePath
        currentProject = recentProject
        let pendingEntries = session.entries
        await session.selectDraftProject(recentProject.repositoryPath)
        #expect(session.entries == pendingEntries)

        await session.send("把另一个项目的问候语也改成 world")

        #expect(session.phase == .awaitingDecision)
        #expect(herLines(session).last == "先决定上一份改动：点「合进来」或「丢掉」，再发新任务。")
        #expect(!session.entries.contains { if case .draft(_, _, _, _, true) = $0 { return true }; return false })
        await session.sendCurrentDraft()
        #expect(reports(session) == [pendingReport])
        #expect(try String(contentsOfFile: pendingWorktree + "/greeting.txt", encoding: .utf8) == "world\n")
        #expect(try greeting(recentProject) == "hello\n")

        await session.send("刚才具体改了什么？")
        #expect(herLines(session).last == "只改了问候语。")
        #expect(session.phase == .awaitingDecision)
        let pendingContext = try #require(ScriptedStepFun.systemMessages.last)
        #expect(pendingContext.contains("路径：\(originalProject.repositoryPath)"))
        #expect(!pendingContext.contains("路径：\(recentProject.repositoryPath)"))
        session.startOver()
        #expect(reports(session) == [pendingReport])
        #expect(session.phase == .awaitingDecision)
        if shouldMerge {
            await session.mergePendingChange()
        } else {
            await session.discardPendingChange()
        }
        #expect(try greeting(originalProject) == (shouldMerge ? "world\n" : "hello\n"))
        #expect(!FileManager.default.fileExists(atPath: pendingWorktree))
        #expect(session.phase == .idle)

        await session.send("把另一个项目的问候语改成 world")
        await session.sendCurrentDraft()
        let newReceipt = try #require(reports(session).last).receipt
        #expect(newReceipt.workspace.project == recentProject)
        await session.mergePendingChange()
        #expect(try greeting(recentProject) == "world\n")
        #expect(try greeting(originalProject) == (shouldMerge ? "world\n" : "hello\n"))
    }

    @Test(arguments: [false, true])
    func aPendingChangeRemainsActionableAfterAnotherReplyOrFailure(screenRequest: Bool) async throws {
        let project = try await makeProject()
        var replies = [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")]
        if screenRequest {
            replies.append(modelReply(say: "好。", action: "screen", screenGoal: "点击 保存 按钮"))
        }
        let session = try makeSession(
            project: project,
            claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: replies)
        await session.send("把问候语改成 world")
        await session.sendCurrentDraft()
        let originalReport = try #require(reports(session).first)

        await session.send(screenRequest ? "帮我点一下保存" : "刚才改了什么？")

        #expect(session.phase == .awaitingDecision)
        #expect(reports(session) == [originalReport])
        await session.mergePendingChange()
        #expect(try greeting(project) == "world\n")
        #expect(!FileManager.default.fileExists(atPath: originalReport.receipt.workspace.worktreePath))
    }

    @Test func guardAsksOnlyOnceEvenIfTheModelKeepsPromising() async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: ":"),
            replies: [modelReply(say: "我这就去改。"), modelReply(say: "我这就去改。")])

        await session.send("把问候语改成 world")

        #expect(ScriptedStepFun.remaining == 0, "exactly two model calls")
        #expect(session.phase == .idle)
        #expect(reports(session).isEmpty, "A promise alone never runs anything")
    }

    @Test func screenRequestsGoToJev() async throws {
        let project = try await makeProject()
        let screenGoals = ScreenGoalRecorder()
        let session = try makeSession(project: project, claude: try makeStubClaude(body: ":"),
                                      replies: [modelReply(say: "好。", action: "screen", screenGoal: "点击 保存 按钮")],
                                      screenGoals: screenGoals)

        await session.send("帮我点一下保存")

        #expect(screenGoals.goals == ["点击 保存 按钮"])
        #expect(reports(session).isEmpty)
    }

    @Test func missingProjectIsSaidPlainlyAndNothingRuns() async throws {
        let session = try makeSession(project: nil, claude: try makeStubClaude(body: ":"),
                                      replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改点什么")])

        await session.send("改点什么")
        await session.sendCurrentDraft()

        #expect(herLines(session).last?.contains("选择项目") == true)
        #expect(reports(session).isEmpty)
    }

    @Test func discardLeavesTheProjectAsItWas() async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "把 greeting.txt 改成 world")])
        await session.send("把问候语改成 world")
        await session.sendCurrentDraft()

        await session.discardPendingChange()

        #expect(try greeting(project) == "hello\n")
        #expect(herLines(session).last == "丢掉了，项目没动。")
    }

    @Test func claudeCodesClosingQuestionIsRelayed() {
        let workspace = DelegationWorkspace(project: DelegationProject(repositoryPath: "/p"), branchName: "b", worktreePath: "/w", baseCommit: "c")
        let receipt = DelegationReceipt(workspace: workspace, outcome: .changed,
            agentSummary: "两节都改成了中文。\n另外三节还是英文，你要的话我可以接着改。",
            changedFiles: ["a.swift"], untrackedFiles: [], diffStat: "", costInUSD: 0.4, durationMilliseconds: 72000, agentSessionID: nil)

        let report = DelegationReport(receipt: receipt)

        #expect(report.followUpQuestion == "另外三节还是英文，你要的话我可以接着改")
        #expect(report.costText == "用了 72 秒，约 $0.40 订阅额度")
    }
}

@MainActor
final class ScreenGoalRecorder {
    var goals: [String] = []
}

/// Answers the StepFun chat endpoint with queued model contents, in order.
final class ScriptedStepFun: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String] = []
    nonisolated(unsafe) private static var recordedSystemMessages: [String] = []

    static func queue(_ contents: [String]) {
        lock.withLock {
            replies = contents
            recordedSystemMessages = []
        }
    }
    static var remaining: Int { lock.withLock { replies.count } }
    static var systemMessages: [String] { lock.withLock { recordedSystemMessages } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url == DelegationModelClient.endpoint
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let requestBody = Self.bodyData(for: request),
           let object = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
           let messages = object["messages"] as? [[String: String]],
           let systemMessage = messages.first(where: { $0["role"] == "system" })?["content"] {
            Self.lock.withLock { Self.recordedSystemMessages.append(systemMessage) }
        }
        let content: String? = Self.lock.withLock { Self.replies.isEmpty ? nil : Self.replies.removeFirst() }
        let status = content == nil ? 500 : 200
        let body = content.map { ["choices": [["message": ["content": $0]]]] } ?? ["error": "no scripted reply"]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
