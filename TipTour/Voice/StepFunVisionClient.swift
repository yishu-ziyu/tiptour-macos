//
//  StepFunVisionClient.swift
//  TipTour
//
//  The "eye": a multimodal model that looks at a screenshot and says which of
//  the locally detected controls the user means.
//
//  Scope is deliberately narrow, and measurement is the reason.
//
//  These models do not report usable pixel coordinates. Markers placed at known
//  positions in a real 3420x2224 screenshot came back 276-2082 px off, with no
//  stable scale factor across input resolutions (docs/model-research-findings.md
//  §5). So this client never asks for a coordinate and never returns one. Local
//  perception owns geometry; the vision model only contributes semantics —
//  "which of these numbered regions is the save button".
//
//  That division also removes the worst failure mode. A model that invents a
//  coordinate produces a confident click in the wrong place; a model that picks
//  the wrong number produces a wrong click too, but the number is checkable and
//  the candidate list is what the user was told about.
//
//  Two integration traps this client encodes, both found by running it:
//  - reasoning content is billed against max_tokens, so a small budget yields an
//    empty answer with finish_reason == "length". Always budget generously.
//  - JSON Mode avoids markdown fences and a competing response schema.
//

import Foundation

/// One region the vision model is asked to choose between.
///
/// Built from a local detection. The box is used only to crop the screenshot
/// for the model's benefit — it is never sent as a number and never comes back.
struct StepFunVisionCandidate {
    let identifier: String
    let label: String
    let kind: String
    /// Screenshot-space rectangle used to draw the numbered overlay the model sees.
    let box: [Double]
}

struct StepFunVisionChoice {
    /// Identifier of the chosen candidate, or nil when the model declined.
    let chosenIdentifier: String?
    /// Short spoken explanation. Useful when the choice is skipped, and for logs.
    let rationale: String
    let elapsedMilliseconds: Int
    let promptTokens: Int
    let completionTokens: Int
}

enum StepFunVisionError: LocalizedError {
    case emptyAnswer(finishReason: String)
    case http(status: Int, body: String)
    case unreadableAnswer(String)

    var errorDescription: String? {
        switch self {
        case .emptyAnswer(let finishReason):
            return "Vision model returned no answer (finish_reason=\(finishReason)). Raise max_tokens — reasoning consumes the budget."
        case .http(let status, let body):
            return "Vision model returned HTTP \(status): \(body.prefix(300))"
        case .unreadableAnswer(let detail):
            return "Vision model answer could not be read: \(detail)"
        }
    }
}

@MainActor
final class StepFunVisionClient {
    /// The multimodal model. `step-3.7-flash` measured 1.2 s at `low` effort with
    /// JSON Mode; `step-5-preview` measured 12.4 s and is unusable in a live loop.
    ///
    /// `nonisolated` because it is read from the initialiser's default argument,
    /// which is a nonisolated context.
    nonisolated static let defaultModel = "step-3.7-flash"

    /// Reached over the Step Plan channel, where the coding subscription's
    /// credits apply. The realtime voice model deliberately uses the other route.
    private static let endpoint = URL(string: "https://api.stepfun.com/step_plan/v1/chat/completions")!

    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String = StepFunVisionClient.defaultModel) {
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Asks which numbered region matches the user's intent.
    ///
    /// The image sent is the screenshot with the candidate boxes drawn on it, so
    /// the numbers the model reads are the numbers this caller assigned. Without
    /// that overlay the model re-derives its own grouping and the mapping back to
    /// a candidate is guesswork.
    func chooseCandidate(
        annotatedScreenshotPNG: Data,
        candidates: [StepFunVisionCandidate],
        intent: String
    ) async throws -> StepFunVisionChoice {
        guard !candidates.isEmpty else {
            throw StepFunVisionError.unreadableAnswer("no candidates to choose between")
        }

        let numberedList = candidates
            .map { "\($0.identifier). \($0.label.isEmpty ? "unlabelled control" : $0.label) [\($0.kind)]" }
            .joined(separator: "\n")

        let instructions = """
            A screenshot of the user's screen has numbered boxes drawn on it, one per \
            interactive control. The user wants to: \(intent)

            The numbered controls are:
            \(numberedList)

            Reply with ONLY this JSON, no prose:
            {"chosen":"<number>","rationale":"<one short sentence>"}
            Use "none" for chosen when no listed control matches what the user asked for. \
            Never invent a number that is not in the list, and never give coordinates.
            """

        let (answer, elapsedMilliseconds, promptTokens, completionTokens) = try await ask(
            imagePNG: annotatedScreenshotPNG,
            instructions: instructions,
            reasoningEffort: "low"
        )

        guard let object = jsonObject(from: answer) else {
            throw StepFunVisionError.unreadableAnswer(answer.prefix(200).description)
        }

        let chosenRaw = (object["chosen"] as? String) ?? ""
        let rationale = (object["rationale"] as? String) ?? ""
        let chosenIdentifier = candidates.contains { $0.identifier == chosenRaw } ? chosenRaw : nil

        return StepFunVisionChoice(
            chosenIdentifier: chosenIdentifier,
            rationale: rationale,
            elapsedMilliseconds: elapsedMilliseconds,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }

    /// Describes what is on screen when local detection found nothing usable.
    ///
    /// Returns words only. This is deliberately not a coordinate source: a
    /// description lets the assistant tell the user what it can and cannot see and
    /// ask for something more specific, which is honest. A bounding box here would
    /// be a guess wearing the costume of a measurement.
    func describeScreen(screenshotPNG: Data) async throws -> (description: String, elapsedMilliseconds: Int) {
        let instructions = """
            Describe only the interactive controls visible in this screenshot, in one or \
            two short sentences, in Chinese. If there are none, say so plainly.
            """

        let (answer, elapsedMilliseconds, _, _) = try await ask(
            imagePNG: screenshotPNG,
            instructions: instructions,
            reasoningEffort: "low"
        )
        return (answer.trimmingCharacters(in: .whitespacesAndNewlines), elapsedMilliseconds)
    }

    // MARK: - Wire

    private func ask(
        imagePNG: Data,
        instructions: String,
        reasoningEffort: String
    ) async throws -> (answer: String, elapsedMilliseconds: Int, promptTokens: Int, completionTokens: Int) {
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(imagePNG.base64EncodedString())"]],
                    ["type": "text", "text": instructions],
                ],
            ]],
            // Generous on purpose: reasoning_content is billed against this, and a
            // small budget returns an empty answer instead of a short one.
            "max_tokens": 2000,
            "temperature": 0,
            "reasoning_effort": reasoningEffort,
            "response_format": ["type": "json_object"],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let startedAt = DispatchTime.now()
        let (data, response) = try await session.data(for: request)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StepFunVisionError.unreadableAnswer("no HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw StepFunVisionError.http(status: httpResponse.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(StepFunChatCompletionResponse.self, from: data)
        let answer = decoded.choices.first?.message.content ?? ""
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StepFunVisionError.emptyAnswer(finishReason: decoded.choices.first?.finishReason ?? "unknown")
        }
        return (
            answer,
            elapsedMilliseconds,
            decoded.usage?.promptTokens ?? 0,
            decoded.usage?.completionTokens ?? 0
        )
    }

    private func jsonObject(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startIndex = trimmed.firstIndex(of: "{"),
              let endIndex = trimmed.lastIndex(of: "}"),
              let data = String(trimmed[startIndex...endIndex]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

private struct StepFunChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
    let choices: [Choice]
    let usage: Usage?
}
