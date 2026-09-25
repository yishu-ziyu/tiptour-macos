//
//  DelegationConversation.swift
//  TipTour
//
//  The Ctrl+K conversation that turns what the user says into a request for
//  Claude Code. Modelled on happy's voice layer (docs/research/delegation-references.md):
//  she listens first, asks when the request is unclear, and writes a complete
//  draft once it is clear. She never sends anything herself; the user sends
//  the draft with a button, and the app — not the model — says that it went.
//

import Foundation

struct DelegationChatMessage: Equatable, Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let content: String
}

/// What she decided to do with the user's latest words.
enum DelegationTurnAction: Equatable, Sendable {
    /// Just talk: a clarifying question or a short reply.
    case reply
    /// A complete request for Claude Code, waiting for the user to send it.
    case draft(String)
    /// Something to click on screen; handed to JEV.
    case screen(goal: String)
}

struct DelegationTurn: Equatable, Sendable {
    let say: String
    let action: DelegationTurnAction
    /// True when the say-do guard had to ask the model a second time.
    let neededCorrection: Bool
}

enum DelegationConversationError: Error, LocalizedError, Equatable {
    case http(status: Int, body: String)
    case unreadableAnswer(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body): return "阶跃接口返回 \(status)：\(body.prefix(200))"
        case .unreadableAnswer(let detail): return "没读懂模型的回答：\(detail.prefix(200))"
        }
    }
}

/// The StepFun chat call behind the conversation. The URL is the Step Plan
/// channel `StepFunVisionClient` already uses, so the user's coding
/// subscription pays for it and no new key is needed.
final class DelegationModelClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.stepfun.com/step_plan/v1/chat/completions")!
    /// Same model as `StepFunVisionClient.defaultModel`: about a second per
    /// answer at low effort, fast enough for a typed conversation.
    static let defaultModel = "step-3.7-flash"

    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String = DelegationModelClient.defaultModel, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = session ?? URLSession(configuration: configuration)
    }

    func complete(_ messages: [DelegationChatMessage]) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": 2000,
            "temperature": 0.3,
            "reasoning_effort": "low",
            "response_format": ["type": "json_object"],
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DelegationConversationError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DelegationConversationError.unreadableAnswer(String(decoding: data, as: UTF8.self))
        }
        return content
    }
}

/// Keeps the transcript and asks the model for her next turn.
final class DelegationConversation: @unchecked Sendable {
    private let complete: @Sendable ([DelegationChatMessage]) async throws -> String
    private(set) var transcript: [DelegationChatMessage] = []

    init(complete: @escaping @Sendable ([DelegationChatMessage]) async throws -> String) {
        self.complete = complete
    }

    func reset() { transcript = [] }

    /// Adds the user's words and returns her turn.
    ///
    /// Say-do guard (from sambuild04/screen-voice-agent, adapted): if she says
    /// she will write or send something but returns no draft, she is asked
    /// once more to either produce the draft or say why she cannot. At most
    /// once per user message, so it cannot loop.
    func respond(to userText: String, projectContext: String) async throws -> DelegationTurn {
        transcript.append(DelegationChatMessage(role: .user, content: userText))
        let systemMessage = DelegationChatMessage(role: .system, content: Self.instructions(projectContext: projectContext))
        var turn = try Self.parse(try await complete([systemMessage] + transcript))
        var neededCorrection = false
        if Self.promisesActionWithoutOne(turn) {
            neededCorrection = true
            let correction = DelegationChatMessage(role: .system, content: Self.correction)
            let retried = try Self.parse(try await complete([systemMessage] + transcript
                + [DelegationChatMessage(role: .assistant, content: Self.encode(turn)), correction]))
            turn = retried
        }
        transcript.append(DelegationChatMessage(role: .assistant, content: Self.encode(turn)))
        return DelegationTurn(say: turn.say, action: turn.action, neededCorrection: neededCorrection)
    }

    // MARK: - Prompt

    static func instructions(projectContext: String) -> String {
        """
        你是住在用户 Mac 上的中文伙伴。用户在 ⌃K 输入框里用文字跟你说话。
        你能做两件事：把写代码、改项目的活交给 Claude Code；或者让 JEV 在屏幕上点一个控件。
        Claude Code 会在当前项目的一个单独工作区里改，改完由用户看差异再决定合不合，所以用户手上的改动不会被碰。

        规则：
        - 默认先听。用户想要的效果、取舍或范围没说清时，用一句话问清楚，action 为 "none"。
        - 不要问文件名、路径或代码细节：Claude Code 会自己在项目里找。只问用户才知道的事，比如想要什么效果、有没有参考、哪些不能动。
        - 要求清楚了，就写 draft：给 Claude Code 的完整要求，写明目标、范围和约束（只改需要改的；先读项目说明；不要运行 xcodebuild；改完自检；提交一次，不要推送；最后用两三句话说明改了什么）。action 为 "draft"，say 用一句话请用户看一眼草稿，确认后点「发出去」。
        - 用户对草稿提意见时，按意见改好整份 draft 再给出来。
        - 你自己不会发出任何东西。不要说「已经交给 Claude Code 了」「我这就去改」之类的话：只有用户点了「发出去」才会交出去，那句话由应用来说。
        - 用户要在屏幕上点某个东西时，action 为 "screen"，screen_goal 写清要点哪个控件。
        - 闲聊或问问题时 action 为 "none"，简短自然地回一两句。
        - say 不超过两句，不空夸，不用「好问题」这类客套。

        只输出一个 JSON 对象：{"say": "...", "action": "none" | "draft" | "screen", "draft": "...", "screen_goal": "..."}。不用的字段留空字符串。

        当前项目：
        \(projectContext)
        """
    }

    static let correction = """
    你上一句说要写草稿或要去做，但没有给出 draft，也没有给出 screen_goal。现在要么给出对应的 draft 或 screen_goal，要么用一句话说明为什么做不了；不要重复上一句。
    """

    // MARK: - Parsing

    private struct RawTurn {
        let say: String
        let action: DelegationTurnAction
    }

    private static func parse(_ answer: String) throws -> RawTurn {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
              let data = String(trimmed[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DelegationConversationError.unreadableAnswer(answer)
        }
        let say = (object["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = (object["draft"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let screenGoal = (object["screen_goal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch object["action"] as? String {
        case "draft" where !draft.isEmpty: return RawTurn(say: say, action: .draft(draft))
        case "screen" where !screenGoal.isEmpty: return RawTurn(say: say, action: .screen(goal: screenGoal))
        default: return RawTurn(say: say, action: .reply)
        }
    }

    private static func encode(_ turn: RawTurn) -> String {
        var object: [String: String] = ["say": turn.say, "action": "none", "draft": "", "screen_goal": ""]
        switch turn.action {
        case .reply: break
        case .draft(let draft): object["action"] = "draft"; object["draft"] = draft
        case .screen(let goal): object["action"] = "screen"; object["screen_goal"] = goal
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A reply that commits to acting ("我这就写/交给/去改") but carries no draft
    /// or screen goal. Asking the user to do something first is not a promise.
    private static func promisesActionWithoutOne(_ turn: RawTurn) -> Bool {
        guard case .reply = turn.action else { return false }
        let say = turn.say
        let waitsForUser = ["请你", "等你", "你确认", "确认吗", "你先", "你看", "？", "?"].contains { say.contains($0) }
        if waitsForUser { return false }
        let commitments = ["交给 Claude Code", "交给Claude Code", "我这就", "马上", "这就去", "我来写", "我去改", "我来改", "写好草稿", "发给"]
        return commitments.contains { say.contains($0) }
    }
}
