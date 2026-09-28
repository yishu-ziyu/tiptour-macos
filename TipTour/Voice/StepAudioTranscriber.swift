//
//  StepAudioTranscriber.swift
//  TipTour
//
//  Speech to text for the 「声音稳定」 voice style: one finished utterance
//  (16 kHz mono PCM16) goes to Step Plan's `stepaudio-2.5-asr` and comes back
//  as text. Step Plan offers this model only over HTTP + SSE, so the whole
//  utterance is sent after the user lets go of the shortcut.
//

import Foundation

nonisolated enum StepAudioTranscriberError: Error, Equatable {
    case http(status: Int, body: String)
    case provider(String)
    case unreadableAnswer(String)

    var userMessage: String {
        switch self {
        case .http(let status, _): return "阶跃没能转成文字（HTTP \(status)）。"
        case .provider(let message): return "阶跃没能转成文字：\(message)"
        case .unreadableAnswer: return "阶跃的转写结果读不懂。"
        }
    }
}

nonisolated final class StepAudioTranscriber: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.stepfun.com/step_plan/v1/audio/asr/sse")!
    static let model = "stepaudio-2.5-asr"
    static let sampleRate = 16_000

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.session = session ?? URLSession(configuration: configuration)
    }

    /// The text of one utterance. Empty when nothing was said.
    func transcribe(pcm16: Data) async throws -> String {
        let body: [String: Any] = ["audio": [
            "data": pcm16.base64EncodedString(),
            "input": [
                "transcription": ["model": Self.model, "language": "zh", "enable_itn": true],
                "format": ["type": "pcm", "codec": "pcm_s16le", "rate": Self.sampleRate, "bits": 16, "channel": 1],
            ],
        ]]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw StepAudioTranscriberError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try Self.text(fromEventStream: String(decoding: data, as: UTF8.self))
    }

    /// The final text from an SSE body: `transcript.text.done` when present,
    /// otherwise the deltas joined. An `error` event is thrown.
    static func text(fromEventStream stream: String) throws -> String {
        var deltas = ""
        var sawEvent = false
        for line in stream.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            sawEvent = true
            switch type {
            case "transcript.text.done":
                return (object["text"] as? String ?? deltas).trimmingCharacters(in: .whitespacesAndNewlines)
            case "transcript.text.delta":
                deltas += object["delta"] as? String ?? ""
            case "error":
                throw StepAudioTranscriberError.provider(object["message"] as? String ?? "未知错误")
            default:
                continue
            }
        }
        guard sawEvent else { throw StepAudioTranscriberError.unreadableAnswer(String(stream.prefix(300))) }
        return deltas.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
