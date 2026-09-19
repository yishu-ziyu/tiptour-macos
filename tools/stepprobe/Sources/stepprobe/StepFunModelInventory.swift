//
//  StepFunModelInventory.swift
//  stepprobe
//
//  Asks the account which models it can actually reach. Documentation and
//  account entitlement disagree in both directions (a documented model 404s
//  while an undocumented one answers), so this is a probe rather than a lookup.
//

import Foundation

struct StepFunModelInventory {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        self.session = URLSession(configuration: .default)
    }

    /// Probes the Step Plan chat endpoint with a trivial prompt.
    /// Returns `(model, reachable, detail)` for each candidate.
    func probeReachability(ofModels models: [String]) async -> [(model: String, reachable: Bool, detail: String)] {
        var results: [(model: String, reachable: Bool, detail: String)] = []
        for model in models {
            let detail: String
            let reachable: Bool
            do {
                let response = try await askTrivialQuestion(model: model)
                reachable = true
                detail = response
            } catch let error as ProbeError {
                reachable = false
                detail = error.errorDescription ?? "unknown"
            } catch {
                reachable = false
                detail = error.localizedDescription
            }
            results.append((model, reachable, detail))
        }
        return results
    }

    /// Images are the reason we care about these models at all, so reachability
    /// is probed with an image attached: a model can answer text and still
    /// reject image input.
    func probeImageSupport(ofModels models: [String], imagePath: String) async -> [(model: String, reachable: Bool, detail: String)] {
        var results: [(model: String, reachable: Bool, detail: String)] = []
        for model in models {
            let detail: String
            let reachable: Bool
            do {
                _ = try await askTrivialQuestion(model: model, imagePath: imagePath)
                reachable = true
                detail = "image input accepted"
            } catch let error as ProbeError {
                reachable = false
                detail = error.errorDescription ?? "unknown"
            } catch {
                reachable = false
                detail = error.localizedDescription
            }
            results.append((model, reachable, detail))
        }
        return results
    }

    private func askTrivialQuestion(model: String, imagePath: String? = nil) async throws -> String {
        var content: [[String: Any]] = []
        if let imagePath, let imageData = FileManager.default.contents(atPath: imagePath) {
            content.append(["type": "image_url",
                            "image_url": ["url": "data:image/png;base64,\(imageData.base64EncodedString())"]])
        }
        content.append(["type": "text", "text": "Reply with the single word ok."])

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "max_tokens": 64,
        ]

        var request = URLRequest(url: URL(string: "https://api.stepfun.com/step_plan/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProbeError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ProbeError.http(status: httpResponse.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return "ok"
    }
}
