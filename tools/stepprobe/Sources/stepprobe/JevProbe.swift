//
//  JevProbe.swift
//  stepprobe
//
//  Measures the decision model that chooses which locally detected control to
//  act on: latency, token cost, and — most importantly — how its confidence
//  distribution behaves when the candidate list is in Chinese rather than
//  English. TypeSafe states that CJK accuracy is lower, and our screens are
//  full of Chinese labels, so this is the probe that decides whether the hand
//  needs a fallback.
//

import Foundation

struct JevProbeRequest {
    /// The content Jev evaluates. Text only — never pixels.
    var state: [String: Any]
    var questions: [String: [String: Any]]
    /// Pin the version: the `jev-latest` alias moves when a release ships, which
    /// would silently invalidate thresholds tuned against a specific version.
    var model: String
    /// Mirrors how production uses it: one bounded call, no retry.
    var timeoutSeconds: Double
}

struct JevProbeResult {
    var model: String
    var elapsedMilliseconds: Int
    var inputTokens: Int
    var outputTokens: Int
    var answers: [String: Any]
}

struct JevProbe {
    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration)
    }

    func run(_ request: JevProbeRequest) async throws -> JevProbeResult {
        let body: [String: Any] = [
            "state": request.state,
            "model": request.model,
            "questions": request.questions,
        ]

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = request.timeoutSeconds

        let startedAt = DispatchTime.now()
        let (data, response) = try await session.data(for: urlRequest)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProbeError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ProbeError.http(status: httpResponse.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let decodedObject = try JSONSerialization.jsonObject(with: data)
        guard let object = decodedObject as? [String: Any] else {
            throw ProbeError.malformedResponse("top level is not a JSON object")
        }
        let usage = object["usage"] as? [String: Any]

        return JevProbeResult(
            model: (object["model"] as? String) ?? request.model,
            elapsedMilliseconds: elapsedMilliseconds,
            inputTokens: (usage?["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage?["output_tokens"] as? Int) ?? 0,
            answers: (object["answers"] as? [String: Any]) ?? [:]
        )
    }
}
