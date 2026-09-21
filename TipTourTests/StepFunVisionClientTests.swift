import Foundation
import Testing

@testable import TipTour

private final class VisionResponseProtocol: URLProtocol {
    static var responseText = ""
    static var capturedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        let body: [String: Any] = ["choices": [["message": ["content": Self.responseText]]]]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite("StepFun screen vision", .serialized)
struct StepFunVisionClientTests {
    private func client() -> StepFunVisionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VisionResponseProtocol.self]
        return StepFunVisionClient(apiKey: "test-key", session: URLSession(configuration: configuration))
    }

    @Test func screenDescriptionUsesQuestionAndOriginalImageFormat() async throws {
        VisionResponseProtocol.responseText = #"{"description":"页面上有一只蓝色小鸟。"}"#
        let result = try await client().describeScreen(
            imageDataURL: "data:image/jpeg;base64,dGVzdA==", intent: "图里是什么动物？",
            previousObservations: "之前窗口：一只红色小猫。"
        )
        #expect(result.description == "页面上有一只蓝色小鸟。")
        let request = try #require(VisionResponseProtocol.capturedRequest)
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = stream.read(&bytes, maxLength: bytes.count)
        #expect(count > 0)
        let body = try #require(JSONSerialization.jsonObject(with: Data(bytes.prefix(max(count, 0)))) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let image = try #require(content.first?["image_url"] as? [String: String])
        #expect(image["url"] == "data:image/jpeg;base64,dGVzdA==")
        #expect((content.last?["text"] as? String)?.contains("图里是什么动物？") == true)
        #expect((content.last?["text"] as? String)?.contains("之前窗口：一只红色小猫。") == true)
    }

    @Test func malformedDescriptionIsNotSpokenAsScreenContent() async {
        VisionResponseProtocol.responseText = #"{"chosen":"1"}"#
        await #expect(throws: StepFunVisionError.self) {
            try await client().describeScreen(imageDataURL: "data:image/jpeg;base64,dGVzdA==", intent: "描述屏幕")
        }
    }

    @Test func plannerRejectsAnInventedTarget() async {
        VisionResponseProtocol.responseText = #"{"action":"click","target_id":"invented","reason":"选中"}"#
        let observation = DesktopTaskObservation(app: "fixture", targets: [
            DesktopTaskTarget(id: "real", label: "保存", source: "ocr", box: [0, 0, 100, 30], display: [0, 0, 1000, 800])
        ])
        await #expect(throws: StepFunVisionError.self) {
            try await client().planDesktopStep(goal: "保存", observation: observation, history: [])
        }
    }

    @Test func textPlannerKeepsSelectedIdentityWithoutAnImage() async throws {
        VisionResponseProtocol.responseText = #"{"action":"click","target_id":"real","reason":"目标明确"}"#
        let observation = DesktopTaskObservation(app: "fixture", targets: [
            DesktopTaskTarget(id: "real", label: "保存", source: "ocr", box: [0, 0, 100, 30], display: [0, 0, 1000, 800])
        ])
        let decision = try await client().planDesktopStep(goal: "保存", observation: observation, history: [])
        #expect(decision.targetID == "real")
        #expect(decision.completed == false)
    }
}
