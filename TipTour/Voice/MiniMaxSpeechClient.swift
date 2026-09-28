//
//  MiniMaxSpeechClient.swift
//  TipTour
//
//  Text to speech for the 「声音稳定」 voice style: MiniMax `t2a_v2` with the
//  user's own voice, streamed as 24 kHz mono PCM16 so the existing player can
//  start before the whole reply is synthesized. The key is the user's MiniMax
//  Token Plan key, kept only in the Keychain.
//

import Foundation

nonisolated enum MiniMaxSpeechError: Error, Equatable {
    case http(status: Int, body: String)
    case provider(code: Int, message: String)
    case noAudio

    var userMessage: String {
        switch self {
        case .http(let status, _): return "MiniMax 没能念出来（HTTP \(status)）。"
        case .provider(let code, let message): return "MiniMax 没能念出来：\(message)（\(code)）"
        case .noAudio: return "MiniMax 没有返回声音。"
        }
    }
}

nonisolated final class MiniMaxSpeechClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.minimaxi.com/v1/t2a_v2")!
    static let defaultModel = "speech-2.8-hd"
    /// The same rate `RealtimeAudioPlayer` plays.
    static let sampleRate = 24_000

    private let apiKey: String
    private let voiceID: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, voiceID: String, model: String = MiniMaxSpeechClient.defaultModel, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.model = model
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.session = session ?? URLSession(configuration: configuration)
    }

    /// Streams `text` as PCM16 chunks to `onAudio`, in order, and returns once
    /// MiniMax has sent everything. Cancelling the task stops the stream.
    func speak(_ text: String, speed: Double = 1, onAudio: @escaping @Sendable (Data) async -> Void) async throws {
        let body: [String: Any] = [
            "model": model,
            "text": text,
            "stream": true,
            "stream_options": ["exclude_aggregated_audio": true],
            "language_boost": "Chinese",
            "output_format": "hex",
            "voice_setting": ["voice_id": voiceID, "speed": min(max(speed, 0.5), 2), "vol": 1, "pitch": 0],
            "audio_setting": ["sample_rate": Self.sampleRate, "format": "pcm", "channel": 1],
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var errorBody = Data()
            for try await byte in bytes { errorBody.append(byte); if errorBody.count > 2000 { break } }
            throw MiniMaxSpeechError.http(status: status, body: String(decoding: errorBody, as: UTF8.self))
        }
        var sentAudio = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let chunk = try Self.audio(fromLine: line) else { continue }
            sentAudio = true
            await onAudio(chunk)
        }
        if !sentAudio { throw MiniMaxSpeechError.noAudio }
    }

    /// The audio in one response line: an SSE `data:` line, or a bare JSON
    /// error body. Only in-progress chunks (status 1) carry new audio; a
    /// provider error in `base_resp` is thrown.
    static func audio(fromLine line: String) throws -> Data? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let payload = trimmed.hasPrefix("data:") ? String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) : trimmed
        guard payload.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        if let base = object["base_resp"] as? [String: Any],
           let code = (base["status_code"] as? NSNumber)?.intValue, code != 0 {
            throw MiniMaxSpeechError.provider(code: code, message: base["status_msg"] as? String ?? "未知错误")
        }
        guard let data = object["data"] as? [String: Any],
              (data["status"] as? NSNumber)?.intValue == 1,
              let hex = data["audio"] as? String, !hex.isEmpty else { return nil }
        return Self.bytes(fromHex: hex)
    }

    static func bytes(fromHex hex: String) -> Data? {
        let characters = Array(hex.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var result = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else { return nil }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
