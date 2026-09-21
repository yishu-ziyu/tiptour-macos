//
//  DesktopObservedWindowIdentity.swift
//  TipTour
//
//  The identity of the single window a screen observation or screenshot
//  belongs to.
//
//  A remote vision call is slow. While it runs, the app under observation can
//  switch to another window, pop a dialog, or refresh its content — all
//  without changing its bundle identifier or its process. An answer computed
//  from window A must never be spoken as the current state of window B, so an
//  observation is only valid while the exact window it captured is still the
//  frontmost, unmoved, unchanged-content window of the same app.
//

import CoreGraphics
import Foundation

struct DesktopObservedWindowIdentity: Equatable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let windowID: Int
    let frame: CGRect
    let capturedAt: Date
    let contentVersion: Int
    /// dHash of the captured window image. The same window can show different
    /// content — a page navigation, a dialog, an auto-refresh — without any
    /// window event, so identity alone is not enough to trust a slow answer.
    let contentFingerprint: UInt64

    /// ScreenCaptureKit and CGWindowList frames agree to within rounding;
    /// anything larger means the window genuinely moved or resized.
    private static let frameEqualityTolerance: CGFloat = 2

    /// True only while the observed window still is the frontmost window of
    /// the same application, unmoved, with unchanged content, and fresh enough
    /// to answer for. A missing current frame means the window is gone.
    func isStillCurrent(
        frontmostBundleIdentifier: String?,
        frontmostWindowID: Int?,
        currentWindowFrame: CGRect?,
        observedProcessStillExists: Bool,
        currentContentVersion: Int,
        at now: Date = Date(),
        maximumAge: TimeInterval
    ) -> Bool {
        guard frontmostBundleIdentifier == bundleIdentifier,
              observedProcessStillExists,
              frontmostWindowID == windowID,
              currentContentVersion == contentVersion,
              now.timeIntervalSince(capturedAt) <= maximumAge,
              let currentWindowFrame else { return false }
        return abs(currentWindowFrame.origin.x - frame.origin.x) <= Self.frameEqualityTolerance
            && abs(currentWindowFrame.origin.y - frame.origin.y) <= Self.frameEqualityTolerance
            && abs(currentWindowFrame.width - frame.width) <= Self.frameEqualityTolerance
            && abs(currentWindowFrame.height - frame.height) <= Self.frameEqualityTolerance
    }

    /// True while a fresh capture of the same window still shows the content
    /// the observation was computed from.
    func contentStillMatches(_ currentFingerprint: UInt64) -> Bool {
        !DesktopWindowContentFingerprint.differs(contentFingerprint, currentFingerprint)
    }
}

/// Difference hash of one window capture.
///
/// The image is reduced to 9×8 grayscale and each row contributes eight
/// adjacent-pixel comparisons, giving 64 bits. The construction tolerates
/// recompression and global brightness shifts while catching real content
/// changes, which is exactly the discrimination a slow vision call needs.
enum DesktopWindowContentFingerprint {
    /// Bits allowed to differ before the content counts as changed. JPEG noise
    /// and cursor repaints move a handful of comparisons; a navigated page or
    /// a new dialog moves dozens.
    static let maximumDifferentBits = 6

    static func hash(of image: CGImage) -> UInt64 {
        let width = 9
        let height = 8
        let bytesPerRow = width
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = context.data else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var fingerprint: UInt64 = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                let nextPixelIsBrighter = pixels[row * width + column] < pixels[row * width + column + 1]
                fingerprint = (fingerprint << 1) | (nextPixelIsBrighter ? 1 : 0)
            }
        }
        return fingerprint
    }

    static func differs(_ first: UInt64, _ second: UInt64) -> Bool {
        (first ^ second).nonzeroBitCount > maximumDifferentBits
    }
}
