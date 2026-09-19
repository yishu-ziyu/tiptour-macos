//
//  StepFunVisionProbe.swift
//  stepprobe
//
//  Measures whether a StepFun multimodal model can be trusted to turn a
//  screenshot into clickable coordinates, and how long that takes.
//
//  Why this exists: see docs/model-research-findings.md §5. Pixel coordinates
//  returned by the vision models did not behave consistently across input
//  resolutions, so this probe reports both the raw answer and the error
//  against ground truth supplied by the caller.
//

import Foundation

struct VisionProbeRequest {
    var imagePath: String
    var prompt: String
    var model: String
    /// low / medium / high. Only multimodal models accept this.
    var reasoningEffort: String
    /// Asking for JSON Mode avoids markdown fences and a competing schema.
    var jsonMode: Bool
    /// Must be large: reasoning_content is billed against max_tokens and an
    /// answer can otherwise come back empty with finish_reason == "length".
    var maxTokens: Int
    /// Ground truth boxes as "name=x1,y1,x2,y2" for error reporting.
    var groundTruth: [String: [Double]]
}

struct VisionProbeResult {
    var model: String
    var elapsedMilliseconds: Int
    var inputTokens: Int
    var outputTokens: Int
    var finishReason: String
    var answerText: String
    var parsedBoxes: [String: [Double]]
    /// Present only when ground truth was supplied and the answer parsed.
    var coordinateErrors: [(name: String, got: [Double], truth: [Double], errorPixels: Double)]
}

struct StepFunVisionProbe {
    private let apiKey: String
    private let session: URLSession

    /// The Step Plan channel. The open-platform channel at /v1 does not offer
    /// the same model set, and bills a different account.
    private let endpoint = URL(string: "https://api.stepfun.com/step_plan/v1/chat/completions")!

    init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func run(_ request: VisionProbeRequest) async throws -> VisionProbeResult {
        let imageData = try Data(contentsOf: URL(fileURLWithPath: request.imagePath))
        let base64Image = imageData.base64EncodedString()

        var body: [String: Any] = [
            "model": request.model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(base64Image)"]],
                    ["type": "text", "text": request.prompt],
                ],
            ]],
            "max_tokens": request.maxTokens,
            "temperature": 0,
            "reasoning_effort": request.reasoningEffort,
        ]
        if request.jsonMode {
            body["response_format"] = ["type": "json_object"]
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let startedAt = DispatchTime.now()
        let (data, response) = try await session.data(for: urlRequest)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProbeError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ProbeError.http(status: httpResponse.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(StepFunChatResponse.self, from: data)
        let choice = decoded.choices.first
        let answerText = choice?.message.content ?? ""
        let finishReason = choice?.finishReason ?? "unknown"

        // Emptiness is the failure mode worth shouting about: the model can burn
        // its whole budget on reasoning and emit nothing.
        if answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("""
              ⚠️  \(request.model): empty answer with finish_reason=\(finishReason). \
              Raise max_tokens — reasoning_content consumes the budget.
              """)
        }

        let parsedBoxes = parseBoxes(from: answerText)
        let coordinateErrors = measureCoordinateErrors(parsedBoxes: parsedBoxes, groundTruth: request.groundTruth)

        return VisionProbeResult(
            model: decoded.model,
            elapsedMilliseconds: elapsedMilliseconds,
            inputTokens: decoded.usage?.promptTokens ?? 0,
            outputTokens: decoded.usage?.completionTokens ?? 0,
            finishReason: finishReason,
            answerText: answerText,
            parsedBoxes: parsedBoxes,
            coordinateErrors: coordinateErrors
        )
    }

    /// Accepts `{"boxes":{"A":[x1,y1,x2,y2]}}` and the bare
    /// `{"A":[x1,y1,x2,y2]}` shape so both answer styles are measurable.
    private func parseBoxes(from text: String) -> [String: [Double]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startIndex = trimmed.firstIndex(of: "{"),
              let endIndex = trimmed.lastIndex(of: "}") else { return [:] }
        let jsonSubstring = String(trimmed[startIndex...endIndex])
        guard let jsonData = jsonSubstring.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return [:] }

        let boxesSource = (object["boxes"] as? [String: Any]) ?? object
        var boxes: [String: [Double]] = [:]
        for (name, value) in boxesSource {
            guard let numbers = value as? [Double], numbers.count == 4 else { continue }
            boxes[name] = numbers
        }
        return boxes
    }

    /// Reports centre-point error in pixels, which is what actually decides
    /// whether a click lands on the intended control.
    private func measureCoordinateErrors(
        parsedBoxes: [String: [Double]],
        groundTruth: [String: [Double]]
    ) -> [(name: String, got: [Double], truth: [Double], errorPixels: Double)] {
        guard !groundTruth.isEmpty else { return [] }
        var errors: [(name: String, got: [Double], truth: [Double], errorPixels: Double)] = []
        for (name, truthBox) in groundTruth.sorted(by: { $0.key < $1.key }) {
            guard let gotBox = parsedBoxes[name] else {
                errors.append((name, [], truthBox, .infinity))
                continue
            }
            let gotCentreX = (gotBox[0] + gotBox[2]) / 2
            let gotCentreY = (gotBox[1] + gotBox[3]) / 2
            let truthCentreX = (truthBox[0] + truthBox[2]) / 2
            let truthCentreY = (truthBox[1] + truthBox[3]) / 2
            let errorPixels = hypot(gotCentreX - truthCentreX, gotCentreY - truthCentreY)
            errors.append((name, gotBox, truthBox, errorPixels))
        }
        return errors
    }
}

// MARK: - Response shapes

private struct StepFunChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
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
    let model: String
    let choices: [Choice]
    let usage: Usage?
}
