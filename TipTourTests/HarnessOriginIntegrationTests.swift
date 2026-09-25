import Foundation
import XCTest
@testable import TipTour

@MainActor
final class HarnessOriginIntegrationTests: XCTestCase {
    func testLocalHealthWorksAndForeignBrowserOriginIsRejected() async throws {
        let engine = TipTourEngine(
            isAutopilotEnabledProvider: { false },
            isScreenshotStreamingEnabledProvider: { false },
            isAccurateGroundingEnabledProvider: { false },
            isCuaActionDriverEnabledProvider: { false },
            detectionElementCountProvider: { 0 },
            refreshLocalPerception: { _ in },
            normalizeWorkflowSteps: { steps, _ in steps },
            startWorkflowPlan: { _ in }
        )
        let port = UInt16.random(in: 30_000...50_000)
        let server = TipTourHarnessServer(tipTourEngine: engine, port: port)
        server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var localResponse: HTTPURLResponse?
        for _ in 0..<20 {
            if let (_, response) = try? await URLSession.shared.data(from: url) {
                localResponse = response as? HTTPURLResponse
                if localResponse?.statusCode == 200 { break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(localResponse?.statusCode, 200)

        var foreignRequest = URLRequest(url: url)
        foreignRequest.setValue("https://untrusted.example", forHTTPHeaderField: "Origin")
        let (deniedBody, deniedResponse) = try await URLSession.shared.data(for: foreignRequest)
        XCTAssertEqual((deniedResponse as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertTrue(String(decoding: deniedBody, as: UTF8.self).contains("invalid_request_origin"))

        var foreignHostRequest = URLRequest(url: url)
        foreignHostRequest.setValue("untrusted.example:\(port)", forHTTPHeaderField: "Host")
        let (_, foreignHostResponse) = try await URLSession.shared.data(for: foreignHostRequest)
        XCTAssertEqual((foreignHostResponse as? HTTPURLResponse)?.statusCode, 403)

        var oversizedRequest = URLRequest(url: url)
        oversizedRequest.httpMethod = "POST"
        oversizedRequest.httpBody = Data(repeating: 65, count: 1_048_577)
        let (oversizedBody, oversizedResponse) = try await URLSession.shared.data(for: oversizedRequest)
        XCTAssertEqual((oversizedResponse as? HTTPURLResponse)?.statusCode, 413)
        XCTAssertTrue(String(decoding: oversizedBody, as: UTF8.self).contains("request_too_large"))
    }
}
