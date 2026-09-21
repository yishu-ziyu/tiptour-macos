import AppKit
import XCTest
@testable import TipTour

final class LocalPerceptionTargetCacheTests: XCTestCase {
    func testOneControlDetectedByOCRAndYOLOAppearsOnce() {
        let cache = LocalPerceptionTargetCache.shared
        defer { cache.clear() }
        cache.update(elements: [
            target("检查官网部署状态（3）", source: "ocr", box: [40, 100, 200, 116]),
            target("检查官网部署状态（3）", source: "yolo", box: [30, 84, 220, 132])
        ], imageSize: CGSize(width: 900, height: 600), displayFrame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let targets = cache.currentTargets()
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.source, "ocr")
    }

    func testDifferentRowsAndDifferentLabelsRemainSeparate() {
        let cache = LocalPerceptionTargetCache.shared
        defer { cache.clear() }
        cache.update(elements: [
            target("更多", source: "ocr", box: [40, 100, 100, 116]),
            target("更多", source: "yolo", box: [30, 134, 120, 162]),
            target("打开", source: "yolo", box: [30, 94, 120, 122])
        ], imageSize: CGSize(width: 900, height: 600), displayFrame: CGRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertEqual(cache.currentTargets().count, 3)
    }

    func testLargeContainingRegionIsNotCollapsedIntoText() {
        let cache = LocalPerceptionTargetCache.shared
        defer { cache.clear() }
        cache.update(elements: [
            target("设置", source: "ocr", box: [40, 100, 100, 116]),
            target("设置", source: "yolo", box: [0, 0, 400, 500])
        ], imageSize: CGSize(width: 900, height: 600), displayFrame: CGRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertEqual(cache.currentTargets().count, 2)
    }

    private func target(_ label: String, source: String, box: [Int]) -> [String: Any] {
        ["label": label, "source": source, "bbox": box, "conf": 1.0]
    }

    func testAXAndOCRShareOneTargetWhileSeparateRowsSurvive() {
        let cache = LocalPerceptionTargetCache.shared
        defer { cache.clear() }
        cache.update(elements: [
            target("os", source: "ax", box: [30, 90, 120, 125]),
            target("os", source: "ocr", box: [40, 100, 100, 116]),
            target("os", source: "ax", box: [30, 180, 120, 215])
        ], imageSize: CGSize(width: 900, height: 600), displayFrame: CGRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertEqual(cache.currentTargets().count, 2)
        XCTAssertTrue(cache.currentTargets().allSatisfy { $0.source == "ax" })
    }

    func testObservationImageAndTimestampAreInvalidatedTogetherWithTargets() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let cache = LocalPerceptionTargetCache.shared
        defer { cache.clear() }
        let capturedAt = Date()
        cache.update(elements: [target("os", source: "ax", box: [1, 1, 15, 15])], imageSize: CGSize(width: 20, height: 20),
            displayFrame: CGRect(x: 0, y: 0, width: 20, height: 20), capturedImage: image, capturedAt: capturedAt)
        let first = try XCTUnwrap(cache.frameEvidence())
        XCTAssertEqual(first.capturedAt, capturedAt)
        XCTAssertEqual(first.image.width, 20)
        cache.clear()
        XCTAssertNil(cache.frameEvidence())
        XCTAssertTrue(cache.currentTargets().isEmpty)
    }

    func testBackgroundOCRCannotCompeteWithForegroundAXControl() {
        let cache = LocalPerceptionTargetCache.shared
        defer { cache.clear() }
        cache.update(elements: [
            target("检查官网部署状态（3）", source: "ax", box: [1252, 351, 1536, 416]),
            target("检查官网部署状态 （3）", source: "ocr", box: [44, 342, 193, 357]),
            target("缩放选项", source: "ocr", box: [941, 710, 1073, 750])
        ], imageSize: CGSize(width: 1728, height: 1112), displayFrame: CGRect(x: 0, y: 0, width: 1728, height: 1112),
            visualTargetWindowFrame: CGRect(x: 850, y: 100, width: 850, height: 950))
        let targets = cache.currentTargets()
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(targets.filter { $0.label.contains("检查官网") }.count, 1)
        XCTAssertTrue(targets.contains { $0.label == "缩放选项" })
    }

    func testMissingWindowRejectsVisualTargetsButKeepsAppScopedMenuBarAX() {
        let cache = LocalPerceptionTargetCache.shared
        defer { cache.clear() }
        cache.update(elements: [
            target("文件", source: "ax", box: [40, 10, 80, 30]),
            target("其他窗口", source: "ocr", box: [40, 100, 200, 130])
        ], imageSize: CGSize(width: 900, height: 600), displayFrame: CGRect(x: 0, y: 0, width: 900, height: 600),
            visualTargetWindowFrame: .null)
        XCTAssertEqual(cache.currentTargets().map(\.label), ["文件"])
    }

    func testUnlabelledYoloBoxCannotBorrowTheNextButtonsText() {
        let cache = LocalPerceptionTargetCache.shared
        defer { cache.clear() }
        cache.update(elements: [
            target("", source: "yolo", box: [936, 584, 1127, 654]),
            target("缩放选项", source: "ocr", box: [949, 729, 1063, 744])
        ], imageSize: CGSize(width: 1728, height: 1112), displayFrame: CGRect(x: 0, y: 0, width: 1728, height: 1112))
        XCTAssertEqual(cache.currentTargets().filter { $0.label == "缩放选项" }.count, 1)
        XCTAssertEqual(cache.currentTargets().first?.source, "ocr")
    }

    func testConflictingYoloLabelCannotRenameTheSameAXControl() {
        let cache = LocalPerceptionTargetCache.shared
        defer { cache.clear() }
        cache.update(elements: [
            target("打开显示设置", source: "ax", box: [941, 587, 1118, 652]),
            target("缩放选项", source: "yolo", box: [936, 584, 1127, 654]),
            target("缩放选项", source: "ax", box: [941, 705, 1073, 770])
        ], imageSize: CGSize(width: 1728, height: 1112), displayFrame: CGRect(x: 0, y: 0, width: 1728, height: 1112))
        XCTAssertEqual(cache.currentTargets().count, 2)
        XCTAssertEqual(cache.currentTargets().filter { $0.label == "缩放选项" }.count, 1)
        XCTAssertTrue(cache.currentTargets().allSatisfy { $0.source == "ax" })
    }
}
