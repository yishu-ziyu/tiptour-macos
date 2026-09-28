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

/// Which repository a draft should change, as the model sees it; the session
/// resolves it to a path and never lets it override the user's own choice.
enum DelegationProjectChoice: String, Sendable {
    /// The project in the prompt's 「当前项目」.
    case current
    /// The project of the earlier hand-off named by `refersTo`.
    case record
    /// Her's own source repository.
    case her
}

struct DelegationTurn: Equatable, Sendable {
    let say: String
    let action: DelegationTurnAction
    /// True when the say-do guard had to ask the model a second time.
    let neededCorrection: Bool
    /// The earlier hand-off this turn is about: its fixed reference in the
    /// list the model was shown (such as "a1b2c3"), or nil.
    let refersTo: String?
    let project: DelegationProjectChoice
}

enum DelegationConversationError: Error, LocalizedError, Equatable {
    case http(status: Int, body: String)
    case unreadableAnswer(String)
    /// The model returned no text at all; the detail says why it stopped.
    case emptyAnswer(detail: String)

    /// The model did answer, but the answer could not be used.
    var isUnusableAnswer: Bool {
        if case .http = self { return false }
        return true
    }

    var errorDescription: String? {
        switch self {
        case .http(let status, let body): return "阶跃接口返回 \(status)：\(body.prefix(200))"
        case .unreadableAnswer(let detail): return "没读懂模型的回答：\(detail.prefix(200))"
        case .emptyAnswer(let detail): return "模型没给出回答（停止原因：\(detail)）"
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
    private let reasoningEffort: String
    private let session: URLSession

    init(apiKey: String, model: String = DelegationModelClient.defaultModel, reasoningEffort: String = "low",
         session: URLSession? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = session ?? URLSession(configuration: configuration)
    }

    func complete(_ messages: [DelegationChatMessage]) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": 4000,
            "temperature": 0.3,
            "reasoning_effort": reasoningEffort,
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
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DelegationConversationError.unreadableAnswer(String(decoding: data, as: UTF8.self))
        }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let usage = (object["usage"] as? [String: Any])?["completion_tokens"].map { "，输出 \($0) 个 token" } ?? ""
            throw DelegationConversationError.emptyAnswer(detail: (choice["finish_reason"] as? String ?? "未知") + usage)
        }
        return content
    }
}

/// Keeps the transcript and asks the model for her next turn.
final class DelegationConversation: @unchecked Sendable {
    private let complete: @Sendable ([DelegationChatMessage]) async throws -> String
    /// Who she is, read again for every turn so a new name or an edited
    /// persona.md counts from the next sentence.
    private let identity: @Sendable () -> String
    private(set) var transcript: [DelegationChatMessage] = []

    init(complete: @escaping @Sendable ([DelegationChatMessage]) async throws -> String,
         identity: @escaping @Sendable () -> String = {
             PersonaStore.identity(persona: PersonaStore.defaultText, companionName: "", userAddress: "")
         }) {
        self.complete = complete
        self.identity = identity
    }

    func reset() { transcript = [] }

    /// How many messages the model sees at most; older ones stay in the panel.
    static let keptMessages = 12

    /// Something that happened outside the conversation, recorded in the
    /// model's view as data, never as the user's words.
    func noteAppEvent(_ text: String) {
        transcript.append(DelegationChatMessage(role: .user, content: Self.appRecord(text)))
        trimTranscript()
    }

    /// The last turns before a restart, so "刚才那个" still has something to
    /// point at. Only the model's own replies come back as hers; the app's
    /// sentences, drafts and receipts come back as app records.
    func restore(_ lines: [DelegationConversationLog.Line]) {
        transcript = lines.compactMap { line in
            let text = (line.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch line.kind {
            case .user:
                return text.isEmpty ? nil : DelegationChatMessage(role: .user, content: text)
            case .her:
                return text.isEmpty ? nil : DelegationChatMessage(role: .assistant, content: Self.encode(
                    RawTurn(say: text, action: .reply, refersTo: nil, project: .current)))
            case .app:
                return text.isEmpty ? nil : DelegationChatMessage(role: .user, content: Self.appRecord(text))
            case .draft:
                let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return DelegationChatMessage(role: .user, content: Self.appRecord("写过一份草稿：\(firstLine)"))
            case .report:
                return line.report.map { DelegationChatMessage(role: .user, content: Self.appRecord("回执：\($0.headline)")) }
            case .startOver:
                return nil
            }
        }
        if !transcript.isEmpty {
            transcript.append(DelegationChatMessage(role: .user, content: Self.appRecord(
                "Her 在 \(Self.nowText()) 重启过，上面是重启前的记录。重启前没发出去的草稿不能再发，面板上没有它的「发出去」按钮；用户要继续那件事，按原来的要求重新写一份 draft。")))
        }
        trimTranscript()
    }

    private static func nowText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }

    private static func appRecord(_ text: String) -> String { "【应用记录，不是用户说的话】\(text)" }

    /// Keeps what goes to the model bounded: the newest `keptMessages`, and
    /// only the latest draft in full.
    private func trimTranscript() {
        let isDraft: (DelegationChatMessage) -> Bool = { message in
            guard message.role == .assistant, let turn = try? Self.parse(message.content), case .draft = turn.action else { return false }
            return true
        }
        let latestDraft = transcript.lastIndex(where: isDraft)
        transcript = transcript.enumerated().map { index, message in
            guard index != latestDraft, isDraft(message), let turn = try? Self.parse(message.content) else { return message }
            return DelegationChatMessage(role: .assistant, content: Self.encode(
                RawTurn(say: turn.say, action: .draft("（较早的草稿，已省略）"), refersTo: turn.refersTo, project: turn.project)))
        }
        if transcript.count > Self.keptMessages { transcript = Array(transcript.suffix(Self.keptMessages)) }
    }

    /// Adds the user's words and returns her turn.
    ///
    /// Say-do guard (from sambuild04/screen-voice-agent, adapted): if she says
    /// she will write or send something but returns no draft, she is asked
    /// once more to either produce the draft or say why she cannot. At most
    /// once per user message, so it cannot loop.
    func respond(to userText: String, projectContext: String, tool: DelegationAgentTool = .claudeCode,
                 recentHandOffs: String = "（还没有记录）", herCode: String = "（不知道在哪）") async throws -> DelegationTurn {
        transcript.append(DelegationChatMessage(role: .user, content: userText))
        let systemMessage = DelegationChatMessage(role: .system, content: Self.instructions(
            projectContext: projectContext, tool: tool, recentHandOffs: recentHandOffs, herCode: herCode, identity: identity()))
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
        trimTranscript()
        return DelegationTurn(say: turn.say, action: turn.action, neededCorrection: neededCorrection,
                              refersTo: turn.refersTo, project: turn.project)
    }

    // MARK: - Prompt

    static func instructions(projectContext: String, tool: DelegationAgentTool = .claudeCode,
                             recentHandOffs: String = "（还没有记录）", herCode: String = "（不知道在哪）",
                             identity: String = PersonaStore.identity(persona: PersonaStore.defaultText,
                                                                      companionName: "", userAddress: "")) -> String {
        """
        \(identity)
        用户在 ⌃K 输入框里用文字跟你说话。
        你能做两件事：整理写代码、改项目的任务草稿；或者让 JEV 在屏幕上点一个控件。
        用户在草稿里选择执行工具，当前选的是 \(tool.displayName)。可选 \(DelegationAgentTool.allCases.map(\.displayName).joined(separator: "、"))，你不能自行切换。
        执行工具会在当前项目的一个单独工作区里改，改完由用户看差异再决定合不合，所以用户手上的改动不会被碰。

        规则：
        - 默认先听。用户想要的效果、取舍或范围没说清时，用一句话问清楚，action 为 "none"。
        - 不要问文件名、路径或代码细节：执行工具会自己在项目里找。只问用户才知道的事，比如想要什么效果、有没有参考、哪些不能动。
        - 当前项目只是从最近使用记录中找到的，不保证是用户这次的目标。用户点名的项目或路径与当前项目不符时，提醒用户在草稿里点「更换项目」核对实际绑定；仅在正文写路径不会切换项目，不能声称已经切换。
        - 要求清楚了，就写 draft：给执行工具的完整要求，写明目标、范围和约束（只改需要改的；先读项目说明；不要运行 xcodebuild；改完自检；提交一次，不要推送；最后用两三句话说明改了什么）。草稿只描述任务，不写「请用某某执行」，也不替执行工具写示例文案。action 为 "draft"，say 用一句话请用户看一眼草稿，确认后点「发出去」。
        - 执行工具由用户在草稿的「执行工具」里选，应用会自己提醒；say 里不要提这次用哪个执行工具。Codex 当前用用户选定的 GPT-6 Luna、High 推理档位，仅对本次执行生效；其他执行工具沿用各自本机配置。你不能通过对话修改模型，不要声称已换模型或自动升级。
        - 用户提到以前的事（「上次」「刚才」「那次失败」）时，对照下面「以前交出去的任务」：能确定是哪次就直接用，不要让用户重述；不确定是哪次，或听不出他要改的是那件事本身还是 Her 当时的提示，用一句话问清。用户说「刚才」「上次」时，按时间对到离现在最近的那件；拿不准是哪件时，说出那件的时间和内容来问。这次和以前某次任务有关时，refers_to 填下面列表里那次方括号中的编号（如 a1b2c3，编号不会变；无关留空字符串）：应用会把那次的背景和 Her 当时给用户看的原话原样放在草稿最前面，draft 里不用再写；重做时在 draft 里写明是重做。记录里没有的事不要编。
        - 用户嫌 Her 自己说过或显示过的话看不懂、不好时，要改的是 Her 产生这类话的方式，不是重做那次任务：say 先用一句大白话讲清那句话的意思；知道 Her 自己的代码在哪就写 draft（project 填 "her"），要求 Her 以后先说发生了什么和下一步、原始报错放在后面；不知道就问一句要不要改 Her。
        - draft 要改哪个项目由 project 说：默认 "current"（下面的当前项目）；重做以前某次任务填 "record"（refers_to 那次的项目）；改 Her 自己的话或做法填 "her"。应用按它绑定项目，用户还能在草稿里「更换项目」。
        - 解释报错只说原文能证明的。地址是 127.0.0.1 或 localhost，说明错误是这台 Mac 上的本机服务返回的；502 表示中间的转发服务收到了请求，但没从后面的服务拿到有效回应，具体原因报错里看不出来。
        - 用户对草稿提意见时，按意见改好整份 draft 再给出来。
        - 你自己不会发出或修改任何东西。say 里不要用「我」做修改或发送的主语（如「我来改」「我准备改」「已经交出去了」）：改东西的是执行工具，要等用户点「发出去」，那句话由应用来说。
        - 用户要在屏幕上点某个东西时，action 为 "screen"，screen_goal 写清要点哪个控件。
        - 闲聊或问问题时 action 为 "none"，简短自然地回一两句。
        - 用户在这里给你起名字或说该怎么称呼他时，这里存不下：如实说可以在语音里告诉你，或去「设置」里填；不要说记住了。
        - say 不超过两句，不空夸，不用「好问题」这类客套。

        只输出一个 JSON 对象：{"say": "...", "action": "none" | "draft" | "screen", "draft": "...", "screen_goal": "...", "refers_to": "", "project": "current" | "record" | "her"}。不用的文字字段留空字符串。

        当前项目：
        \(projectContext)

        Her 自己的代码（你说的话、回执和这些规则都在这里）：
        \(herCode)

        现在是 \(Self.nowText())。
        以前交出去的任务（Her 本机记录，新的在前，重启后仍在）：
        \(recentHandOffs)
        """
    }

    static let correction = """
    你上一句说要写草稿或要去做，但没有给出 draft，也没有给出 screen_goal。现在要么给出对应的 draft 或 screen_goal，要么用一句话说明为什么做不了；不要重复上一句。
    """

    // MARK: - Parsing

    private struct RawTurn {
        let say: String
        let action: DelegationTurnAction
        let refersTo: String?
        let project: DelegationProjectChoice
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
        let reference = (object["refers_to"] as? String ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] ").union(.whitespacesAndNewlines)).lowercased()
        let action: DelegationTurnAction
        switch object["action"] as? String {
        case "draft" where !draft.isEmpty: action = .draft(draft)
        case "screen" where !screenGoal.isEmpty: action = .screen(goal: screenGoal)
        default: action = .reply
        }
        let project = DelegationProjectChoice(rawValue: (object["project"] as? String ?? "").lowercased()) ?? .current
        return RawTurn(say: say, action: action, refersTo: reference.isEmpty || reference == "0" ? nil : reference, project: project)
    }

    private static func encode(_ turn: RawTurn) -> String {
        var object: [String: Any] = ["say": turn.say, "action": "none", "draft": "", "screen_goal": "", "refers_to": turn.refersTo ?? "",
                                     "project": turn.project.rawValue]
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
        let handOffs = DelegationAgentTool.allCases.flatMap { ["交给 \($0.displayName)", "交给\($0.displayName)"] }
        let commitments = ["我这就", "马上", "这就去", "我来写", "我去改", "我来改", "写好草稿", "发给"]
        // "交给 Codex 的任务" names a task rather than promising a hand-off.
        return clausesAboutNow(say).contains { clause in
            handOffs.contains { phrase in clause.ranges(of: phrase).contains { !clause[$0.upperBound...].hasPrefix("的") } }
                || commitments.contains { clause.contains($0) }
        }
    }

    /// The clauses of `text` about now: clauses recalling an earlier hand-off
    /// ("上次交给 Codex 的任务没做成") are left out.
    static func clausesAboutNow(_ text: String) -> [Substring] {
        let pastMarkers = ["上次", "之前", "以前", "当时", "那次", "刚才", "昨天", "前天"]
        return text.split(whereSeparator: { "，。！？；,.!?;\n".contains($0) })
            .filter { clause in !pastMarkers.contains { clause.contains($0) } }
    }
}
