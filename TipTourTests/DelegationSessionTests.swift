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

    private func makeProject() async throws -> DelegationProject {
        let repository = try makeTemporaryDirectory()
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "T"]] {
            _ = await DelegationCommand.git(arguments, inDirectory: repository)
        }
        try "hello\n".write(toFile: repository + "/greeting.txt", atomically: true, encoding: .utf8)
        _ = await DelegationCommand.git(["add", "."], inDirectory: repository)
        _ = await DelegationCommand.git(["commit", "-q", "-m", "init"], inDirectory: repository)
        return DelegationProject(repositoryPath: repository)
    }

    private func makeStubClaude(body: String, summary: String = "Done.") throws -> String {
        let path = try makeTemporaryDirectory() + "/claude"
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"\#(summary)","total_cost_usd":0.2,"duration_ms":4000,"session_id":"s"}"#
        try "#!/bin/zsh\n\(body)\nprint -r -- '\(result)'\n".write(toFile: path, atomically: true, encoding: .utf8)
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
        replies: [String],
        screenGoals: ScreenGoalRecorder? = nil
    ) throws -> DelegationSession {
        ScriptedStepFun.queue(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedStepFun.self]
        let client = DelegationModelClient(apiKey: "test-key", session: URLSession(configuration: configuration))
        let conversation = DelegationConversation(complete: { try await client.complete($0) })
        let delegation = CodingAgentDelegation(claudeCommand: claude, worktreesRootPath: try makeTemporaryDirectory())
        return DelegationSession(conversation: conversation, delegation: delegation,
                                 findProject: { project }, onScreenGoal: { screenGoals?.goals.append($0) })
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
        #expect(report.headline.hasPrefix("改好了"))
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
        #expect(!report.headline.contains("改好了"))
        #expect(session.phase == .idle)
    }

    @Test func promiseWithoutADraftIsCorrectedOnce() async throws {
        let project = try await makeProject()
        let session = try makeSession(
            project: project, claude: try makeStubClaude(body: ":"),
            replies: [modelReply(say: "好，我这就交给 Claude Code。"),
                      modelReply(say: "草稿在这，确认后点发出去。", action: "draft", draft: "把 greeting.txt 改成 world")])

        await session.send("把问候语改成 world")

        #expect(session.phase == .awaitingSend)
        #expect(!herLines(session).contains("好，我这就交给 Claude Code。"), "The broken promise is never shown")
        #expect(session.entries.contains { if case .draft(_, _, true) = $0 { return true }; return false })
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

        #expect(herLines(session).last?.contains("没找到你最近用 Claude Code 的项目") == true)
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

    static func queue(_ contents: [String]) { lock.withLock { replies = contents } }
    static var remaining: Int { lock.withLock { replies.count } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url == DelegationModelClient.endpoint
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
}
