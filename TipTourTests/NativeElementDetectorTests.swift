import AppKit
import XCTest
@testable import TipTour

final class NativeElementDetectorTests: XCTestCase {
    @MainActor
    func testRecognizesChineseAndEnglishControlLabels() async throws {
        let labels = ["检查官网部署状态", "檢查網站部署狀態", "Open Settings"]
        let image = NSImage(size: NSSize(width: 900, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 300).fill()
        for (index, label) in labels.enumerated() {
            (label as NSString).draw(
                at: NSPoint(x: 40, y: 220 - index * 80),
                withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black]
            )
        }
        image.unlockFocus()
        let screenshot = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let detections = await NativeElementDetector.shared.detectElements(in: screenshot)
        let recognizedLabels = detections.filter { $0.source == "ocr" }.map(\.label)
        for label in labels {
            XCTAssertTrue(recognizedLabels.contains(label), "Missing \(label); recognized: \(recognizedLabels)")
        }
    }
}
