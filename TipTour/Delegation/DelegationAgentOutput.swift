import Foundation

/// Normalizes each CLI's JSONL stream without treating its claims as git evidence.
struct DelegationAgentOutput {
    var summary = ""
    var sessionID: String?
    var costInUSD: Double?
    var durationMilliseconds: Int?
    private var receivedTerminal = false
    private var terminalFailure: String?
    private var streamError: String?

    mutating func consume(_ event: [String: Any], tool: DelegationAgentTool) {
        let type = event["type"] as? String
        switch tool {
        case .claudeCode:
            guard type == "result" else { return }
            receivedTerminal = true
            summary = event["result"] as? String ?? ""
            sessionID = event["session_id"] as? String
            costInUSD = event["total_cost_usd"] as? Double
            durationMilliseconds = event["duration_ms"] as? Int
            terminalFailure = event["is_error"] as? Bool == true
                ? (summary.isEmpty ? "Claude Code 报告出错" : summary) : nil
        case .codex:
            switch type {
            case "thread.started":
                sessionID = event["thread_id"] as? String
            case "item.completed":
                guard let item = event["item"] as? [String: Any],
                      item["type"] as? String == "agent_message" else { return }
                summary = item["text"] as? String ?? ""
            case "turn.completed":
                receivedTerminal = true
                terminalFailure = nil
            case "turn.failed":
                receivedTerminal = true
                terminalFailure = Self.errorMessage(in: event) ?? "Codex 报告出错"
            case "error":
                streamError = Self.errorMessage(in: event)
            default:
                break
            }
        case .kimiCode:
            switch event["role"] as? String {
            case "assistant":
                let text = Self.text(in: event["content"])
                let hasToolCalls = !(event["tool_calls"] as? [[String: Any]] ?? []).isEmpty
                receivedTerminal = !hasToolCalls && !text.isEmpty
                if !text.isEmpty { summary = text }
            case "tool":
                receivedTerminal = false
            case "meta" where type == "session.resume_hint":
                sessionID = event["session_id"] as? String
            default:
                break
            }
        case .stepCode:
            switch type {
            case "session":
                sessionID = event["id"] as? String
            case "agent_start":
                receivedTerminal = false
                terminalFailure = nil
            case "message_start", "tool_execution_start":
                receivedTerminal = false
            case "message_end":
                guard let message = event["message"] as? [String: Any] else { return }
                consumeStepMessage(message)
            case "tool_execution_end" where event["isError"] as? Bool == true:
                if let result = event["result"] as? [String: Any] {
                    let detail = Self.text(in: result["content"])
                    if !detail.isEmpty { streamError = String(detail.suffix(400)) }
                }
            case "agent_end":
                receivedTerminal = false
                guard let messages = event["messages"] as? [[String: Any]],
                      let message = messages.last(where: { $0["role"] as? String == "assistant" }) else { return }
                consumeStepMessage(message)
                receivedTerminal = message["stopReason"] as? String == "stop" && !Self.text(in: message["content"]).isEmpty
            default:
                break
            }
        }
    }

    private mutating func consumeStepMessage(_ message: [String: Any]) {
        guard message["role"] as? String == "assistant" else { return }
        receivedTerminal = false
        let text = Self.text(in: message["content"])
        if !text.isEmpty { summary = text }
        switch message["stopReason"] as? String {
        case "error":
            terminalFailure = message["errorMessage"] as? String ?? "Step Code 报告出错"
        case "aborted":
            terminalFailure = "Step Code 运行中断"
        case "length":
            terminalFailure = "Step Code 输出达到长度上限，本次未确认完成"
        default:
            terminalFailure = nil
        }
    }

    func failure(tool: DelegationAgentTool, exitStatus: Int32, standardError: String) -> String? {
        let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitStatus != 0 {
            let reason = terminalFailure ?? streamError ?? (detail.isEmpty ? nil : String(detail.suffix(400)))
            return "\(tool.displayName) 退出码 \(exitStatus)" + (reason.map { "：\($0)" } ?? "")
        }
        if let terminalFailure { return terminalFailure }
        guard receivedTerminal else {
            return streamError ?? (detail.isEmpty
                ? "\(tool.displayName) 没有给出最终结果（输出可能截断）"
                : String(detail.suffix(400)))
        }
        return nil
    }

    private static func errorMessage(in event: [String: Any]) -> String? {
        if let error = event["error"] as? [String: Any] { return error["message"] as? String }
        return event["message"] as? String ?? event["error"] as? String
    }

    private static func text(in content: Any?) -> String {
        if let text = content as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
