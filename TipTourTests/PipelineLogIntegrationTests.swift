import XCTest
@testable import TipTour

@MainActor
final class PipelineLogIntegrationTests: XCTestCase {
    func testDefaultDiagnosticEventOmitsUserContentFromSerializedOutput() throws {
        let privateText = "fixture-private-note-and-url-token"
        let event = PipelineLogStore.diagnosticEvent(
            category: "action",
            name: "type_text",
            status: "failed",
            message: privateText,
            metadata: [
                "goal": privateText,
                "value_preview": privateText,
                "target_label": privateText,
                "trace_id": "trace-123",
                "action_type": "type",
                "step_count": "1",
                "accepted_steps": privateText
            ]
        )

        let serialized = event.jsonLine
        XCTAssertFalse(serialized.contains(privateText))
        XCTAssertNil(event.message)
        XCTAssertEqual(event.metadata["step_count"], "1")
        XCTAssertNotEqual(event.metadata["trace_id"], "trace-123")
        XCTAssertEqual(event.metadata.count, 2)
    }
}
