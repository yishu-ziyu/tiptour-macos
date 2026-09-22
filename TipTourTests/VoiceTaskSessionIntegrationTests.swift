import XCTest
@testable import TipTour

@MainActor
final class VoiceTaskSessionIntegrationTests: XCTestCase {
    private final class Handler: StepFunRealtimeToolHandling {
        let preservesTaskLifetime = true
        var pauses = 0
        var disconnections = 0
        var turnID: String?
        var onPause: (() -> Void)?
        func handleToolCall(name: String, argumentsJSON: String) async throws -> String { "{}" }
        func prepareForUserSpeech() { pauses += 1; onPause?() }
        func interrupt() { disconnections += 1 }
        func beginUserTurn(_ turnID: String) { self.turnID = turnID }
    }

    func testSpeechWhileResponseIsIdlePausesTaskWithoutCancellingIt() async {
        let handler = Handler()
        let session = StepFunRealtimeSession(apiKey: "fixture-not-a-key", model: "fixture", voice: "fixture",
            instructions: "fixture", tools: [], turnDetection: .manual, toolHandler: handler)
        // Feed the real session boundary, without connecting or starting audio.
        session.state.isSessionActive = true
        session.state.isModelSpeaking = true
        handler.onPause = { XCTAssertFalse(session.state.isModelSpeaking, "Playback state must stop before task processing") }
        session.handle(.userStartedSpeaking)
        XCTAssertEqual(handler.pauses, 1)
        XCTAssertEqual(handler.disconnections, 0)
        XCTAssertNotNil(handler.turnID)
        await session.stop()
        XCTAssertEqual(handler.disconnections, 1)
        session.handle(.userStartedSpeaking)
        XCTAssertEqual(handler.pauses, 1, "Stopped sessions ignore late events")
        handler.onPause = nil
    }
}
