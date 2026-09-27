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

    private func modelReply(say: String, action: String = "none", draft: String = "", screenGoal: String = "",
                            refersTo: Int = 0, project: String = "current") -> String {
        let content = try! JSONSerialization.data(withJSONObject: ["say": say, "action": action, "draft": draft,
                                                                   "screen_goal": screenGoal, "refers_to": refersTo,
                                                                   "project": project])
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
        screenGoals: ScreenGoalRecorder? = nil,
        history: DelegationHistory? = nil,
        herBundleIdentifier: String? = nil,
        notices: RecordingNoticePoster? = nil,
        noticeRules: DelegationNoticeRules? = nil,
        isUserLooking: @escaping @MainActor () -> Bool = { false },
        keepAwake: DelegationKeepAwake? = nil
    ) throws -> DelegationSession {
        ScriptedStepFun.queue(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedStepFun.self]
        let client = DelegationModelClient(apiKey: "test-key", session: URLSession(configuration: configuration))
        let conversation = DelegationConversation(complete: { try await client.complete($0) })
        let delegation = CodingAgentDelegation(claudeCommand: claude, worktreesRootPath: try makeTemporaryDirectory(),
                                               codexCommand: codex, kimiCommand: kimi, stepCommand: step)
        return DelegationSession(conversation: conversation, delegation: delegation,
                                 findProject: findProject ?? { project }, onScreenGoal: { goal, finished in
                                     screenGoals?.goals.append(goal)
                                     if let result = screenGoals?.result { finished(result) }
                                 },
                                 history: history, herBundleIdentifier: herBundleIdentifier,
                                 noticePoster: notices, noticeRules: noticeRules, isUserLooking: isUserLooking,
                                 keepAwake: keepAwake)
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

    /// The repository the current draft is bound to.
    private func currentDraftProject(_ session: DelegationSession) -> DelegationProject? {
        session.entries.compactMap {
            if case .draft(_, _, let project, _, true) = $0 { return project }
            return nil
        }.last
    }

    /// The draft the panel currently offers to send, as the user sees it.
    private func currentDraftText(_ session: DelegationSession) -> String? {
        session.entries.compactMap {
            if case .draft(_, let text, _, _, true) = $0 { return text }
            return nil
        }.last
    }

    /// Hands "把日志窗口改成中文" to a Codex stub that fails like the real 502, recording it in `historyURL`.
    private func recordFailedCodexHandOff(project: DelegationProject, historyURL: URL) async throws -> DelegationReport {
        let session = try makeSession(
            project: project, claude: "/nonexistent/claude",
            codex: try makeStubCodex(body: """
            print -r -- '{"type":"turn.failed","error":{"message":"unexpected status 502 Bad Gateway"}}'
            exit 1
            """),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "把日志窗口改成中文")],
            history: DelegationHistory(fileURL: historyURL))
        await session.send("日志窗口改成中文")
        session.selectAgentTool(.codex)
        await session.sendCurrentDraft()
        let report = try #require(reports(session).first)
        guard case .agentFailed = report.receipt.outcome else {
            Issue.record("The stub must fail like the real 502")
            return report
        }
        return report
    }

    private func failedReceipt(_ project: DelegationProject) -> DelegationReceipt {
        let workspace = DelegationWorkspace(project: project, branchName: "b", worktreePath: "/w", baseCommit: "c")
        return DelegationReceipt(workspace: workspace, outcome: .agentFailed(reason: "502"), agentSummary: "", changedFiles: [],
                                 untrackedFiles: [], diffStat: "", costInUSD: nil, durationMilliseconds: nil, agentSessionID: nil)
    }

    /// The id of the only record in a history file.
    private func noticeRecordID(_ historyURL: URL) -> UUID? {
        guard let data = try? Data(contentsOf: historyURL),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return (array.last?["id"] as? String).flatMap(UUID.init(uuidString:))
    }

    private func addXcodeProject(to project: DelegationProject, named name: String, bundleIdentifier: String) throws {
        let bundle = project.repositoryPath + "/\(name).xcodeproj"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        try "PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier);\n".write(toFile: bundle + "/project.pbxproj", atomically: true, encoding: .utf8)
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
        #expect(report.headline == "工作区里有改动：涉及 1 个文件。确认后再合进 \(project.name) 的 main 分支。")
        #expect(herLines(session).contains { $0.hasPrefix("交给 Claude Code 了") })
        #expect(try greeting(project) == "hello\n", "Nothing reaches the project before the user merges")

        await session.mergePendingChange()
        #expect(try greeting(project) == "world\n")
        #expect(session.phase == .idle)
    }

    @Test func aChangeMadeAfterTheUserLookedIsNotMerged() async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "把 greeting.txt 改成 world")])
        await session.send("把问候语改成 world")
        await session.sendCurrentDraft()
        let shown = try #require(reports(session).last)
        // Something edits the workspace after the receipt was shown.
        try "world, and more\n".write(toFile: shown.receipt.workspace.worktreePath + "/greeting.txt", atomically: true, encoding: .utf8)

        await session.mergePendingChange()
        #expect(try greeting(project) == "hello\n", "What the user did not see stays out of the project")
        #expect(session.phase == .awaitingDecision)
        #expect(herLines(session).last == "你看过之后工作区又变了，没有合进去。下面是现在的改动，看过再决定。")
        let now = try #require(reports(session).last)
        #expect(now.receipt.diffStat != shown.receipt.diffStat || now.receipt.diffDigest != shown.receipt.diffDigest)
        #expect(now.sinceShownTitle == "和你上次看到的不一样")
        #expect(now.sinceShownDetail == "文件还是这 1 个，里面的改动变了。下面的改动统计是现在的。")
        #expect(now.sinceShownNote(for: "greeting.txt") == "内容变了")
        #expect(now.agentSummaryCaption.hasSuffix("做完时说 · 写在内容变动之前"))
        #expect(shown.sinceShownTitle == nil && shown.agentSummaryCaption.hasSuffix(" 说"), "The first receipt carries no notice")

        await session.mergePendingChange()
        #expect(try greeting(project) == "world, and more\n", "Once seen, the new content can be merged")
        #expect(session.phase == .idle)
    }

    @Test func aChangeIsMergedOnlyIntoTheBranchTheTaskStartedFrom() async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "把 greeting.txt 改成 world")])
        await session.send("把问候语改成 world")
        await session.sendCurrentDraft()
        _ = await DelegationCommand.git(["checkout", "-q", "-b", "experiment"], inDirectory: project.repositoryPath)

        await session.mergePendingChange()
        #expect(try greeting(project) == "hello\n")
        #expect(session.phase == .awaitingDecision)
        #expect(herLines(session).last == "任务开始时 \(project.name) 在 main 分支，现在在 experiment 分支，所以没有合进去。切回 main 再点「合进来」，或者丢掉。")

        _ = await DelegationCommand.git(["checkout", "-q", "main"], inDirectory: project.repositoryPath)
        await session.mergePendingChange()
        #expect(try greeting(project) == "world\n")
    }

    @Test func newFilesThatWillNotBeMergedAreNamedInTheReceiptAndNotice() async throws {
        let project = try await makeProject()
        let notices = RecordingNoticePoster()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt; print note > notes.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改问候语，顺便记一笔")],
            notices: notices)
        await session.send("改问候语，顺便记一笔")
        await session.sendCurrentDraft()

        let report = try #require(reports(session).last)
        #expect(report.headline.hasSuffix("另有 1 个新建但没提交的文件（notes.txt），合并时不会带上；合进来或丢掉后都会随工作区删除，不进废纸篓。"))
        #expect(try #require(notices.posted.first).body.contains("另有 1 个新建的文件没提交（notes.txt），合并时不会带上，之后会随工作区删除。"))
        let worktree = report.receipt.workspace.worktreePath
        await session.mergePendingChange()
        #expect(!FileManager.default.fileExists(atPath: project.repositoryPath + "/notes.txt"), "As the receipt said")
        #expect(!FileManager.default.fileExists(atPath: worktree + "/notes.txt"))
        #expect(herLines(session).last?.hasSuffix("工作区清掉了。没提交的 notes.txt 也随工作区删了，不进废纸篓。") == true)
    }

    @Test func discardingSaysTheUncommittedNewFilesAreGoneToo() async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt; print note > notes.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改问候语，顺便记一笔")])
        await session.send("改问候语，顺便记一笔")
        await session.sendCurrentDraft()
        let worktree = try #require(reports(session).last).receipt.workspace.worktreePath

        await session.discardPendingChange()
        #expect(!FileManager.default.fileExists(atPath: worktree + "/notes.txt"))
        #expect(herLines(session).last == "丢掉了，项目没动。没提交的 notes.txt 也随工作区删了，不进废纸篓。")
    }

    @Test func aReceiptRebuiltAfterARestartShowsWhatItShowedBefore() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let before = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt; print note > notes.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")],
            history: DelegationHistory(fileURL: historyURL))
        await before.send("问候语改成 world")
        await before.sendCurrentDraft()
        let shown = try #require(reports(before).last)

        let after = try makeSession(project: project, claude: "/nonexistent/claude", replies: [],
                                    history: DelegationHistory(fileURL: historyURL))
        let restored = try #require(reports(after).last)
        #expect(restored.receipt.diffStat == shown.receipt.diffStat)
        #expect(restored.receipt.untrackedFiles == ["notes.txt"])
        #expect(restored.headline == shown.headline)
        await after.mergePendingChange()
        #expect(try greeting(project) == "world\n", "Unchanged since it was shown, so it merges")
    }

    @Test func aRecordDeletedByHandWhileHerRunsStaysDeleted() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let history = DelegationHistory(fileURL: historyURL)
        let old = history.begin(userWords: ["旧的"], draft: "旧的", project: project, tool: .claudeCode)
        let kept = history.begin(userWords: ["新的"], draft: "新的", project: project, tool: .claudeCode)
        // The user opens the file and removes the old record while Her is running.
        var array = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [[String: Any]])
        array.removeAll { $0["id"] as? String == old.uuidString }
        try JSONSerialization.data(withJSONObject: array).write(to: historyURL)

        history.decide(kept, .discarded)
        let text = DelegationHistory(fileURL: historyURL).promptText()
        #expect(!text.contains("草稿：旧的"))
        #expect(text.contains("用户决定：已丢掉"))
    }

    @Test func aRuleRemovedByHandStopsApplyingAtOnce() throws {
        let url = URL(fileURLWithPath: try makeTemporaryDirectory() + "/notice-rules.json")
        let rules = DelegationNoticeRules(fileURL: url)
        rules.silence(.failed)
        #expect(rules.silences(.failed))
        try "[]".write(to: url, atomically: true, encoding: .utf8)
        #expect(!rules.silences(.failed))
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

    @Test func whatJevDidComesBackToTheConversation() async throws {
        let project = try await makeProject()
        let screenGoals = ScreenGoalRecorder()
        screenGoals.result = "没有开始：上一件屏幕上的事还在做。"
        let session = try makeSession(project: project, claude: try makeStubClaude(body: ":"),
                                      replies: [modelReply(say: "好。", action: "screen", screenGoal: "点击 保存 按钮"),
                                                modelReply(say: "没点成，上一件还在做。")],
                                      screenGoals: screenGoals)

        await session.send("帮我点一下保存")
        #expect(herLines(session).last == "屏幕上那件事：没有开始：上一件屏幕上的事还在做。", "She said she would; the panel says it did not start")

        await session.send("弄好了吗")
        let seen = try #require(ScriptedStepFun.userMessages.last)
        #expect(seen.contains("【应用记录，不是用户说的话】屏幕上那件事：没有开始"), "The model answers from what happened")
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

    // MARK: - Remembering hand-offs across restarts

    @Test func aFailedHandOffIsStillKnownAfterARestart() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let failed = try await recordFailedCodexHandOff(project: project, historyURL: historyURL)

        // A new app launch: a fresh session reading the same file.
        let after = try makeSession(project: project, claude: "/nonexistent/claude",
                                    replies: [modelReply(say: "好。")],
                                    history: DelegationHistory(fileURL: historyURL))
        await after.send("上次 Codex 那个失败提示我看不懂，改一下")
        let seen = try #require(ScriptedStepFun.systemMessages.last)
        #expect(seen.contains("日志窗口改成中文"))
        #expect(seen.contains("把日志窗口改成中文"))
        #expect(seen.contains("Codex"))
        #expect(seen.contains(project.repositoryPath))
        #expect(seen.contains("没做成。原始报错："))
        #expect(seen.contains("502 Bad Gateway"))
        #expect(seen.contains("Her 当时在回执里给用户看的原话：「\(failed.headline)」"))
        #expect(try greeting(project) == "hello\n")
    }

    @Test func aDraftAboutAnEarlierHandOffStartsWithWhatHerRecorded() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let shown = try await recordFailedCodexHandOff(project: project, historyURL: historyURL).headline

        let after = try makeSession(
            project: project, claude: "/nonexistent/claude",
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改 Her 显示失败的写法", refersTo: 1),
                      modelReply(say: "改好了，再看一眼。", action: "draft", draft: "改 Her 显示失败的写法，下一步写在前面")],
            history: DelegationHistory(fileURL: historyURL))
        await after.send("上次 Codex 那个失败提示我看不懂，改一下")
        let first = try #require(currentDraftText(after))
        #expect(first.hasPrefix("背景：接着 "))
        #expect(first.contains("交给 Codex 的任务（项目 \(project.name)）：把日志窗口改成中文"))
        #expect(first.contains("Her 当时给用户看的原话：「\(shown)」"))
        #expect(first.hasSuffix("\n\n改 Her 显示失败的写法"))

        await after.send("下一步写在前面")
        let revised = try #require(currentDraftText(after))
        #expect(revised.contains("Her 当时给用户看的原话：「\(shown)」"), "A revision keeps the background")
        #expect(revised.hasSuffix("改 Her 显示失败的写法，下一步写在前面"))
    }

    @Test func carryingOnAMergedChangeKeepsItsToolAndAShortBackground() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let before = try makeSession(
            project: project, claude: "/nonexistent/claude",
            codex: try makeStubCodex(body: """
            print world > greeting.txt
            print -r -- '{"type":"item.completed","item":{"type":"agent_message","text":"- **修改位置**: greeting.txt 第 1 行"}}'
            """),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "目标：问候语改成 world\n范围：只改 greeting.txt")],
            history: DelegationHistory(fileURL: historyURL))
        await before.send("问候语改成 world")
        before.selectAgentTool(.codex)
        await before.sendCurrentDraft()
        await before.mergePendingChange()
        #expect(try greeting(project) == "world\n")

        let after = try makeSession(
            project: project, claude: "/nonexistent/claude",
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "问候语改成 world!", refersTo: 1)],
            history: DelegationHistory(fileURL: historyURL))
        await after.send("刚才那个再调一下，加个感叹号")
        #expect(after.selectedAgentTool == .codex, "The earlier task went to Codex and the user named no other tool")
        #expect(herLines(after).contains("执行工具沿用那次的 Codex；要换，在草稿的「执行工具」里选。"))
        let draft = try #require(currentDraftText(after))
        #expect(draft.hasPrefix("背景：接着 "))
        #expect(draft.contains("交给 Codex 的任务（项目 \(project.name)）：目标：问候语改成 world\n"), "Only the draft's first line")
        #expect(draft.contains("当时的结果：改了 1 个文件（greeting.txt），用户已合进项目\n"))
        #expect(!draft.contains("修改位置") && !draft.contains("Changed the greeting"), "The tool's explanation stays out of the draft")
        #expect(!draft.contains("Her 当时给用户看的原话"), "A change that was made needs no quote")
    }

    @Test func aFailedRunPassesOnNoTool() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        _ = try await recordFailedCodexHandOff(project: project, historyURL: historyURL)
        let after = try makeSession(
            project: project, claude: "/nonexistent/claude",
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "把日志窗口改成中文", refersTo: 1)],
            history: DelegationHistory(fileURL: historyURL))
        await after.send("上次那个失败的，重做一遍")
        #expect(after.selectedAgentTool == .claudeCode, "Codex failed that run; which tool to try is the user's call")
        #expect(herLines(after) == ["看一眼草稿。"])
    }

    @Test func aSentDraftIsRecordedWithoutItsBackground() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        _ = try await recordFailedCodexHandOff(project: project, historyURL: historyURL)
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改 Her 显示失败的写法", refersTo: 1)],
            history: DelegationHistory(fileURL: historyURL))
        await session.send("上次那个失败提示改一下")
        await session.sendCurrentDraft()
        await session.discardPendingChange()

        let text = DelegationHistory(fileURL: historyURL).promptText()
        #expect(text.contains("草稿：改 Her 显示失败的写法"))
        #expect(!text.contains("背景："), "The record keeps the model's draft, not Her's background")
    }

    @Test func aReferenceOutsideTheRecordAddsNothing() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let session = try makeSession(project: project, claude: "/nonexistent/claude",
                                      replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改问候语", refersTo: 3)],
                                      history: DelegationHistory(fileURL: historyURL))
        await session.send("上次那个")
        #expect(currentDraftText(session) == "改问候语")
    }

    @Test func aFailureRecordedBeforeTheShownWordsWereKeptStillShowsThem() throws {
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let failure = "Codex 退出码 1：unexpected status 502 Bad Gateway: Unknown error, url: http://127.0.0.1:10101/backend-api/codex/responses"
        let legacy = """
        [{"id":"6F9D2C1E-6C1B-4E1F-9E1A-000000000001","sentAt":"2026-09-26T14:03:00Z","userWords":["日志窗口改成中文"],\
        "draft":"把日志窗口改成中文","projectPath":"/p/os","tool":"codex","result":"failed","failure":"\(failure)","changedFiles":[]}]
        """
        try legacy.write(to: historyURL, atomically: true, encoding: .utf8)

        let text = DelegationHistory(fileURL: historyURL).promptText()
        #expect(text.contains("Her 当时在回执里给用户看的原话：「没做成：\(failure)」"))
    }

    @Test func aComplaintAboutHerOwnWordsIsBoundToHerOwnCode() async throws {
        let herSource = try await makeProject()
        try addXcodeProject(to: herSource, named: "Her", bundleIdentifier: "com.example.her")
        let testsOnly = try await makeProject()
        try addXcodeProject(to: testsOnly, named: "Other", bundleIdentifier: "com.example.her.tests")
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        _ = try await recordFailedCodexHandOff(project: herSource, historyURL: historyURL)
        let session = try makeSession(
            project: testsOnly, claude: "/nonexistent/claude",
            replies: [modelReply(say: "那句是说本机服务返回了 502。", action: "draft", draft: "改 Her 显示失败的写法",
                                 refersTo: 1, project: "her")],
            history: DelegationHistory(fileURL: historyURL), herBundleIdentifier: "com.example.her")

        await session.send("上次 Codex 那个失败提示我看不懂，改一下")

        #expect(currentDraftProject(session) == herSource, "Not the recently used repository")
        #expect(herLines(session) == ["那句是说本机服务返回了 502。"])
        let seen = try #require(ScriptedStepFun.systemMessages.last)
        #expect(seen.contains("Her 自己的代码（你说的话、回执和这些规则都在这里）：\n\(herSource.name)（\(herSource.repositoryPath)）"))
    }

    @Test func aRedoIsBoundToTheProjectOfThatHandOff() async throws {
        let original = try await makeProject()
        let recent = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        _ = try await recordFailedCodexHandOff(project: original, historyURL: historyURL)
        let session = try makeSession(
            project: recent, claude: "/nonexistent/claude",
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "重做：把日志窗口改成中文", refersTo: 1, project: "record")],
            history: DelegationHistory(fileURL: historyURL))

        await session.send("上次 Codex 那个任务再交一次")

        #expect(currentDraftProject(session) == original)
    }

    @Test func whenHerOwnCodeIsUnknownTheDraftStaysAndSheSaysSo() async throws {
        let recent = try await makeProject()
        let session = try makeSession(
            project: recent, claude: "/nonexistent/claude",
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改 Her 显示失败的写法", project: "her")],
            herBundleIdentifier: "com.example.her")

        await session.send("你那个失败提示我看不懂，改一下")

        #expect(currentDraftProject(session) == recent)
        #expect(herLines(session).last == "没找到 Her 自己的代码在哪，草稿先绑在 \(recent.name)；发出去前点「更换项目」选 Her 的仓库。")
        #expect(ScriptedStepFun.systemMessages.last?.contains("（不知道在哪：最近用过的项目里没有 Her 的代码）") == true)
    }

    @Test func theUsersOwnProjectChoiceIsNeverReplaced() async throws {
        let herSource = try await makeProject()
        try addXcodeProject(to: herSource, named: "Her", bundleIdentifier: "com.example.her")
        let recent = try await makeProject()
        let chosen = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        _ = try await recordFailedCodexHandOff(project: herSource, historyURL: historyURL)
        let session = try makeSession(
            project: recent, claude: "/nonexistent/claude",
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改问候语"),
                      modelReply(say: "改好了。", action: "draft", draft: "改问候语和提示", refersTo: 1, project: "her")],
            history: DelegationHistory(fileURL: historyURL), herBundleIdentifier: "com.example.her")
        await session.send("问候语改一下")
        await session.selectDraftProject(chosen.repositoryPath)

        await session.send("顺便把 Her 的失败提示也改了")

        #expect(currentDraftProject(session) == chosen)
    }

    @Test(arguments: [false, true])
    func theUsersDecisionIsRemembered(merge: Bool) async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let session = try makeSession(
            project: project,
            claude: try makeStubClaude(body: "print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")],
            history: DelegationHistory(fileURL: historyURL))
        await session.send("问候语改成 world")
        await session.sendCurrentDraft()
        if merge { await session.mergePendingChange() } else { await session.discardPendingChange() }

        let reopened = DelegationHistory(fileURL: historyURL).promptText()
        #expect(reopened.contains("改了 1 个文件（greeting.txt）"))
        #expect(reopened.contains(merge ? "用户决定：已合进项目" : "用户决定：已丢掉"))
        #expect(try greeting(project) == (merge ? "world\n" : "hello\n"))
    }

    @Test func aHandOffCutOffByQuittingIsNotShownAsDone() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        _ = DelegationHistory(fileURL: historyURL).begin(userWords: ["改问候语"], draft: "改成 world", project: project, tool: .kimiCode)

        let reopened = DelegationHistory(fileURL: historyURL).promptText()
        #expect(reopened.contains("没有收到结果：执行期间 Her 被关掉了"))
        #expect(!reopened.contains("正在执行"))
        #expect(reopened.contains("Kimi Code"))
    }

    @Test func anUnreadableHistoryIsKeptAsideNotOverwritten() async throws {
        let project = try await makeProject()
        let directory = try makeTemporaryDirectory()
        let historyURL = URL(fileURLWithPath: directory + "/delegation-history.json")
        try "not json".write(to: historyURL, atomically: true, encoding: .utf8)

        let history = DelegationHistory(fileURL: historyURL)
        #expect(history.promptText() == "（还没有记录）")
        _ = history.begin(userWords: ["新任务"], draft: "新草稿", project: project, tool: .codex)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.contains("unreadable") }
        #expect(kept.count == 1)
        #expect(try String(contentsOfFile: directory + "/" + kept[0], encoding: .utf8) == "not json")
        #expect(DelegationHistory(fileURL: historyURL).promptText().contains("新草稿"))
    }

    @Test(arguments: ["上次交给 Codex 的任务没做成：这台 Mac 上的本机服务返回了 502。",
                      "上次发给 Codex 的那份马上就失败了，本机服务返回了 502。"])
    func recallingAnEarlierHandOffIsNotTakenForAPromise(recall: String) async throws {
        let project = try await makeProject()
        let session = try makeSession(project: project, claude: "/nonexistent/claude", replies: [modelReply(say: recall)])

        await session.send("上次 Codex 为什么失败了？")

        #expect(herLines(session) == [recall])
        #expect(ScriptedStepFun.remaining == 0)
    }

    @Test(arguments: [
        ("上次那个日志窗口改中文的活，换 Kimi 再做一次", DelegationAgentTool?.some(.kimiCode)),
        ("上次用 Codex 失败了，这次换 Kimi", .some(.kimiCode)),
        ("上次 Codex 那个失败提示我看不懂，改一下", nil),
        ("还是用 Claude，不用 Codex", nil),
        ("不要用 Codex", nil),
        ("Her 想调用 Codex 帮你干活，那句提示我看不懂", nil),
    ])
    func askingForAnotherToolGetsHerOwnReminder(words: String, asked: DelegationAgentTool?) async throws {
        let project = try await makeProject()
        let session = try makeSession(project: project, claude: "/nonexistent/claude",
                                      replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "把日志窗口改成中文")])

        await session.send(words)

        let reminder = asked.map { "现在选的还是 Claude Code；要用 \($0.displayName)，在草稿的「执行工具」里选。" }
        #expect(herLines(session) == ["看一眼草稿。"] + (reminder.map { [$0] } ?? []))
        let draft = try #require(session.entries.first { if case .draft = $0 { return true } else { return false } })
        guard case .draft(_, _, _, let tool, _) = draft else { return }
        #expect(tool == .claudeCode, "Only the user switches the tool")
    }

    @Test func herClaimingAToolSwitchIsFollowedByWhatIsActuallySelected() async throws {
        let project = try await makeProject()
        let session = try makeSession(project: project, claude: "/nonexistent/claude",
                                      replies: [modelReply(say: "这是重做版草稿，执行工具改为 Kimi Code，请核对后点「发出去」。",
                                                           action: "draft", draft: "重做：把日志窗口改成中文")])

        await session.send("上次那个任务再做一次")

        #expect(herLines(session).last == "现在选的还是 Claude Code；要用 Kimi Code，在草稿的「执行工具」里选。")
        #expect(session.selectedAgentTool == .claudeCode)
    }

    @Test func anEmptyModelAnswerIsNotReportedAsNoConnection() async throws {
        let project = try await makeProject()
        let session = try makeSession(project: project, claude: "/nonexistent/claude", replies: [""])

        await session.send("上次那个")

        let line = try #require(herLines(session).last)
        #expect(line.hasPrefix("阶跃这次的回答没法用"))
        #expect(line.contains("模型没给出回答"))
        #expect(!line.contains("没连上"))
        #expect(session.phase == .idle)
    }

    // MARK: - Telling the user when a hand-off ends

    @Test func aHandOffThatEndsWhileYouAreAwayIsToldOnceInPlainWords() async throws {
        let project = try await makeProject()
        let notices = RecordingNoticePoster()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")], notices: notices)
        await session.send("问候语改成 world")
        await session.sendCurrentDraft()

        #expect(notices.prepared == 1, "Permission is asked when a hand-off starts")
        #expect(notices.posted.count == 1)
        let notice = try #require(notices.posted.first)
        #expect(notice.category == .changed)
        #expect(notice.title == "Claude Code 做完了 · \(project.name)")
        #expect(notice.body == "「问候语改成 world」改了 1 个文件。现在告诉你，是因为改动在单独的工作区里，等你决定合不合进项目。点开看改动。")
        #expect(try greeting(project) == "hello\n", "Nothing is merged until the user decides")
    }

    @Test func aFailureIsToldWithTheReasonAndWhatToDecide() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let notices = RecordingNoticePoster()
        let session = try makeSession(
            project: project, claude: "/nonexistent/claude",
            codex: try makeStubCodex(body: """
            print -r -- '{"type":"turn.failed","error":{"message":"unexpected status 502 Bad Gateway"}}'
            exit 1
            """),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "把日志窗口改成中文")],
            history: DelegationHistory(fileURL: historyURL), notices: notices)
        await session.send("日志窗口改成中文")
        session.selectAgentTool(.codex)
        await session.sendCurrentDraft()

        let notice = try #require(notices.posted.first)
        #expect(notices.posted.count == 1)
        #expect(notice.category == .failed)
        #expect(notice.title == "Codex 没做成 · \(project.name)")
        #expect(notice.body.hasPrefix("「日志窗口改成中文」停下了："))
        #expect(notice.body.contains("502 Bad Gateway"))
        #expect(notice.body.hasSuffix("现在告诉你，是因为要你决定重试还是换个做法。点开看原始报错。"))
        #expect(notice.recordID != nil, "The notice points at the recorded hand-off")
    }

    @Test func nothingPopsUpWhileYouAreLookingAtThePanel() async throws {
        let project = try await makeProject()
        let notices = RecordingNoticePoster()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")],
            notices: notices, isUserLooking: { true })
        await session.send("问候语改成 world")
        await session.sendCurrentDraft()

        #expect(notices.posted.isEmpty)
        #expect(reports(session).count == 1, "The receipt in the panel is how she tells you")
    }

    @Test func aSilencedKindStaysSilentAfterARestartAndOtherKindsStillCome() async throws {
        let project = try await makeProject()
        let rulesURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/notice-rules.json")
        let notices = RecordingNoticePoster()
        // What the 「这类不再提醒」 button does, through the notification's own payload.
        let failedNotice = try #require(DelegationNotice(recordID: UUID(), receipt: failedReceipt(project), task: "改成 world"))
        let tapped = try #require(DelegationNotice.decode(userInfo: failedNotice.userInfo))
        #expect(tapped.category == .failed && tapped.recordID == failedNotice.recordID)
        DelegationNoticeRules(fileURL: rulesURL).silence(tapped.category, from: tapped.recordID)

        // A new app launch reads the same rules file.
        let failing = try makeSession(
            project: project, claude: "/nonexistent/claude",
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")],
            notices: notices, noticeRules: DelegationNoticeRules(fileURL: rulesURL))
        await failing.send("问候语改成 world")
        await failing.sendCurrentDraft()
        #expect(reports(failing).first.map { if case .agentFailed = $0.receipt.outcome { true } else { false } } == true)
        #expect(notices.posted.isEmpty, "The silenced kind stays silent after a restart")

        let succeeding = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")],
            notices: notices, noticeRules: DelegationNoticeRules(fileURL: rulesURL))
        await succeeding.send("问候语改成 world")
        await succeeding.sendCurrentDraft()
        #expect(notices.posted.map(\.category) == [.changed])
        #expect(DelegationNoticeRules(fileURL: rulesURL).rules.map(\.category) == [.failed])
    }

    @Test func theNoticeQuotesTheRequestNotSmallTalkBeforeIt() async throws {
        let project = try await makeProject()
        let notices = RecordingNoticePoster()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt"),
            replies: [modelReply(say: "现在是下午。"),
                      modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world"),
                      modelReply(say: "改好了。", action: "draft", draft: "改成 world，并保留换行")],
            notices: notices)
        await session.send("现在几点")
        await session.send("问候语改成 world")
        await session.send("换行留着")
        await session.sendCurrentDraft()

        #expect(try #require(notices.posted.first).body.hasPrefix("「问候语改成 world」"))
    }

    @Test func aRedoQuotesTheOriginalRequest() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        _ = try await recordFailedCodexHandOff(project: project, historyURL: historyURL)
        let notices = RecordingNoticePoster()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "重做", refersTo: 1, project: "record")],
            history: DelegationHistory(fileURL: historyURL), notices: notices)
        await session.send("上次那个再做一次")
        await session.sendCurrentDraft()

        #expect(try #require(notices.posted.first).body.hasPrefix("「日志窗口改成中文」"))
    }

    @Test func newFilesLeftUncommittedAreNotCalledNoChange() async throws {
        let project = try await makeProject()
        let notices = RecordingNoticePoster()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print new > brand-new.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "加一个文件")], notices: notices)
        await session.send("加一个文件")
        await session.sendCurrentDraft()

        let notice = try #require(notices.posted.first)
        #expect(notice.category == .noChange)
        #expect(notice.body.contains("没有提交任何改动；它新建的 1 个文件没提交（brand-new.txt），已随工作区删除，不进废纸篓"))
        #expect(!notice.body.contains("没有任何改动"))
        let report = try #require(reports(session).last)
        #expect(!FileManager.default.fileExists(atPath: report.receipt.workspace.worktreePath + "/brand-new.txt"))
        #expect(report.headline.hasSuffix("说做完了，但没有提交任何改动，这次不算做成。它新建但没提交的 brand-new.txt 已随工作区删除，不进废纸篓。"))
    }

    @Test func whenNotificationsAreOffSheSaysSoOnce() async throws {
        let project = try await makeProject()
        let notices = RecordingNoticePoster()
        notices.allowed = false
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world"),
                      modelReply(say: "看一眼草稿。", action: "draft", draft: "再改一次")],
            notices: notices)
        await session.send("问候语改成 world")
        await session.sendCurrentDraft()
        await session.discardPendingChange()
        await session.send("再改一次")
        await session.sendCurrentDraft()

        let told = herLines(session).filter { $0.hasPrefix("系统通知被关了") }
        #expect(told == ["系统通知被关了：这次做完我不会弹提醒，回来看这里就行。要开的话去 系统设置 → 通知 → Her。"])
    }

    @Test func aDecisionStillOwedComesBackAfterARestartAndCanBeMerged() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let notices = RecordingNoticePoster()
        let before = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt", summary: "- **修改位置**: greeting.txt 第 1 行"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")],
            history: DelegationHistory(fileURL: historyURL), notices: notices)
        await before.send("问候语改成 world")
        await before.sendCurrentDraft()
        let recordID = try #require(notices.posted.first?.recordID)

        // Her quits before the user decides; a new launch reads the same record.
        let after = try makeSession(project: project, claude: "/nonexistent/claude", replies: [],
                                    history: DelegationHistory(fileURL: historyURL), notices: notices)
        #expect(after.phase == .awaitingDecision)
        let resumed = try #require(herLines(after).first)
        #expect(resumed.hasPrefix("Her 重启前的这件事还在等你决定："))
        #expect(resumed.hasSuffix("的「问候语改成 world」：改了 1 个文件（greeting.txt）。"),
                "One short line; the tool's own explanation is in the receipt below it")
        #expect(reports(after).first?.receipt.changedFiles == ["greeting.txt"])

        await after.mergePendingChange()
        #expect(try greeting(project) == "world\n")
        #expect(notices.withdrawn == [recordID], "The notice leaves Notification Center once decided")
        let again = try makeSession(project: project, claude: "/nonexistent/claude", replies: [],
                                    history: DelegationHistory(fileURL: historyURL))
        #expect(again.phase == .idle, "A decided change does not come back")
    }

    @Test func clickingANoticeWhoseReceiptIsGoneSaysWhatItWas() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        _ = try await recordFailedCodexHandOff(project: project, historyURL: historyURL)
        let notices = RecordingNoticePoster()
        let session = try makeSession(project: project, claude: "/nonexistent/claude", replies: [],
                                      history: DelegationHistory(fileURL: historyURL), notices: notices)
        let id = try #require(noticeRecordID(historyURL))

        session.openNotice(for: id)

        let line = try #require(herLines(session).last)
        #expect(line.hasPrefix("你点开的是这件事："))
        #expect(line.contains("交给 Codex 的「日志窗口改成中文」：没做成。原始报错："))
        #expect(notices.withdrawn == [id])
    }

    @Test func anEditMadeByHandWhileHerRunsIsKept() throws {
        let rulesURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/notice-rules.json")
        let rules = DelegationNoticeRules(fileURL: rulesURL)
        rules.silence(.failed)
        let handEdited = """
        [{"category":"failed","createdAt":"2026-09-27T10:00:00Z"},{"category":"noChange","createdAt":"2026-09-27T10:01:00Z"}]
        """
        try handEdited.write(to: rulesURL, atomically: true, encoding: .utf8)

        rules.restore(.failed)

        #expect(DelegationNoticeRules(fileURL: rulesURL).rules.map(\.category) == [.noChange])
    }

    @Test func aHandOffYouStoppedIsNotAnnounced() async throws {
        let project = try await makeProject()
        let notices = RecordingNoticePoster()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "sleep 30"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "慢慢改")], notices: notices)
        await session.send("慢慢改")
        async let sent: Void = session.sendCurrentDraft()
        try await Task.sleep(nanoseconds: 500_000_000)
        session.stop()
        await sent

        #expect(reports(session).first?.receipt.outcome == .cancelled)
        #expect(notices.posted.isEmpty)
    }

    @Test func theMacIsKeptAwakeOnlyWhileTheToolRuns() async throws {
        let project = try await makeProject()
        let marker = try makeTemporaryDirectory() + "/tool-ran"
        let keepAwake = RecordingKeepAwake(marker: marker)
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: "touch '\(marker)'; print world > greeting.txt"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")], keepAwake: keepAwake)
        await session.send("问候语改成 world")
        await session.sendCurrentDraft()

        #expect(keepAwake.events == ["begin before the tool ran", "end after the tool ran"])
    }

    @Test func anUnreadableRulesFileIsKeptAsideNotOverwritten() async throws {
        let directory = try makeTemporaryDirectory()
        let rulesURL = URL(fileURLWithPath: directory + "/notice-rules.json")
        try "not json".write(to: rulesURL, atomically: true, encoding: .utf8)

        let rules = DelegationNoticeRules(fileURL: rulesURL)
        #expect(rules.rules.isEmpty)
        rules.silence(.noChange)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.contains("unreadable") }
        #expect(kept.count == 1)
        #expect(try String(contentsOfFile: directory + "/" + kept[0], encoding: .utf8) == "not json")
        #expect(DelegationNoticeRules(fileURL: rulesURL).silences(.noChange))
    }

    @Test func noHistoryMeansHerSaysSheHasNoRecord() async throws {
        let project = try await makeProject()
        let session = try makeSession(project: project, claude: "/nonexistent/claude", replies: [modelReply(say: "好。")])
        await session.send("上次那个")
        #expect(ScriptedStepFun.systemMessages.last?.contains("以前交出去的任务（Her 本机记录，新的在前，重启后仍在）：\n（还没有记录）") == true)
    }

    @Test func theChangedSinceShownNoticeSurvivesARestart() async throws {
        let project = try await makeProject()
        let historyURL = URL(fileURLWithPath: try makeTemporaryDirectory() + "/delegation-history.json")
        let before = try makeSession(
            project: project, claude: try makeStubClaude(body: "print world > greeting.txt; git commit -qam greet"),
            replies: [modelReply(say: "看一眼草稿。", action: "draft", draft: "改成 world")],
            history: DelegationHistory(fileURL: historyURL))
        await before.send("问候语改成 world")
        await before.sendCurrentDraft()
        let shown = try #require(reports(before).last)
        try "world, and more\n".write(toFile: shown.receipt.workspace.worktreePath + "/greeting.txt", atomically: true, encoding: .utf8)
        await before.mergePendingChange()
        let refused = try #require(reports(before).last)

        let after = try makeSession(project: project, claude: "/nonexistent/claude", replies: [],
                                    history: DelegationHistory(fileURL: historyURL))
        let restored = try #require(reports(after).last)
        #expect(restored.sinceShownTitle == refused.sinceShownTitle)
        #expect(restored.sinceShownDetail == refused.sinceShownDetail)
        await after.mergePendingChange()
        #expect(try greeting(project) == "world, and more\n", "What the restored receipt shows is what merges")
    }

    @Test func aReceiptWhoseFilesChangedSaysWhichOnes() {
        let workspace = DelegationWorkspace(project: DelegationProject(repositoryPath: "/p"), branchName: "b", worktreePath: "/w", baseCommit: "c")
        func receipt(_ files: [String], digest: String) -> DelegationReceipt {
            DelegationReceipt(workspace: workspace, outcome: .changed, agentSummary: "改好了。", changedFiles: files, untrackedFiles: [],
                              diffStat: "", costInUSD: nil, durationMilliseconds: nil, agentSessionID: nil, diffDigest: digest)
        }
        let shown = receipt(["a.swift", "b.swift"], digest: "1")
        let now = receipt(["a.swift", "c.swift"], digest: "2")

        let report = DelegationReport(receipt: now, sinceShown: DelegationChangeSinceShown(shown: shown, now: now))
        #expect(report.sinceShownDetail == "涉及的文件也变了：多了 c.swift，少了 b.swift。下面的改动统计是现在的。")
        #expect(report.sinceShownNote(for: "c.swift") == "新出现")
        #expect(report.sinceShownNote(for: "a.swift") == nil, "Whether a.swift itself changed is not known")

        let restored = DelegationReport(receipt: now, sinceShown: DelegationChangeSinceShown(shown: receipt(["a.swift"], digest: ""), now: now))
        #expect(restored.sinceShownTitle == "没法确认是不是你上次看到的")
        #expect(restored.agentSummaryCaption.hasSuffix("之后内容可能变过"))
    }

    @Test func gitOutputInTheSummaryIsNotTakenForAQuestion() {
        let workspace = DelegationWorkspace(project: DelegationProject(repositoryPath: "/p"), branchName: "b", worktreePath: "/w", baseCommit: "c")
        let receipt = DelegationReceipt(workspace: workspace, outcome: .changed,
            agentSummary: "完成。\n- greeting.txt：内容覆盖为 world\n- `notes.txt` 按要求保持未跟踪状态（`git status` 显示 `?? notes.txt`），未纳入提交",
            changedFiles: ["greeting.txt"], untrackedFiles: ["notes.txt"], diffStat: "", costInUSD: nil, durationMilliseconds: nil, agentSessionID: nil)

        #expect(DelegationReport(receipt: receipt).followUpQuestion == nil)
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
    /// What JEV reports back; nil leaves the goal unfinished.
    var result: String?
}

/// Answers the StepFun chat endpoint with queued model contents, in order.
@MainActor
final class RecordingNoticePoster: DelegationNoticePoster {
    var allowed = true
    private(set) var prepared = 0
    private(set) var posted: [DelegationNotice] = []
    private(set) var withdrawn: [UUID] = []
    func prepare() async -> Bool { prepared += 1; return allowed }
    func post(_ notice: DelegationNotice) { posted.append(notice) }
    func withdraw(_ recordID: UUID) { withdrawn.append(recordID) }
}

/// Notes whether the stub tool had run at each begin and end.
@MainActor
final class RecordingKeepAwake: DelegationKeepAwake {
    private let marker: String
    private(set) var events: [String] = []
    init(marker: String) { self.marker = marker }
    func begin(reason: String) { events.append("begin " + (FileManager.default.fileExists(atPath: marker) ? "after" : "before") + " the tool ran") }
    func end() { events.append("end " + (FileManager.default.fileExists(atPath: marker) ? "after" : "before") + " the tool ran") }
}

final class ScriptedStepFun: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String] = []
    nonisolated(unsafe) private static var recordedSystemMessages: [String] = []
    nonisolated(unsafe) private static var recordedUserMessages: [String] = []

    static func queue(_ contents: [String]) {
        lock.withLock {
            replies = contents
            recordedSystemMessages = []
            recordedUserMessages = []
        }
    }
    static var remaining: Int { lock.withLock { replies.count } }
    static var systemMessages: [String] { lock.withLock { recordedSystemMessages } }
    /// Per request, every user-role message it carried, joined by newlines.
    static var userMessages: [String] { lock.withLock { recordedUserMessages } }

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
            let users = messages.filter { $0["role"] == "user" }.compactMap { $0["content"] }.joined(separator: "\n")
            Self.lock.withLock { Self.recordedUserMessages.append(users) }
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
