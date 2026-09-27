import AppKit
import SwiftUI

private final class TextCommandKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onEscape: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        // Escape must still work when the input is disabled or has lost focus.
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}

struct ConversationPanelDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ nsView: DragView, context: Context) {}
}

@MainActor
final class TextCommandPanelManager {
    private weak var companionManager: CompanionManager?
    private var panel: NSPanel?
    private var mouseTrackingTimer: Timer?
    private var currentPanelOrigin: CGPoint?
    private var conversationPanelFrame: NSRect?

    // Grows when the Jev loop has results to draw under the input. Every
    // consumer reads this property, and positionPanel re-asserts the frame at
    // 60Hz, so changing it here is enough to resize the live window.
    static let baseHeight: CGFloat = 64
    static let defaultWidth: CGFloat = 340
    private var panelSize = NSSize(width: TextCommandPanelManager.defaultWidth, height: TextCommandPanelManager.baseHeight)
    private var isTrackingFrozen = false
    private var isConversationLayout = false
    private let screenEdgeInset: CGFloat = 12
    private let cursorClearance: CGFloat = 44
    private let horizontalOffsetFromCursor: CGFloat = 56
    private let verticalOffsetFromCursor: CGFloat = 32
    private let trackingInterval: TimeInterval = 1.0 / 60.0
    private let smoothingFactor: CGFloat = 0.24
    private let fadeDuration: TimeInterval = 0.12

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func show() {
        guard let companionManager else { return }

        if panel == nil {
            createPanel(companionManager: companionManager)
        }

        panel?.alphaValue = 0
        if isConversationLayout, let conversationPanelFrame {
            restoreConversationFrame(conversationPanelFrame)
        } else {
            currentPanelOrigin = nil
            positionPanel(at: NSEvent.mouseLocation, animated: false)
        }
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        fadePanel(to: 1)
        if !isConversationLayout { startMouseTracking() }
    }

    func hide() {
        if isConversationLayout { conversationPanelFrame = panel?.frame }
        panel?.orderOut(nil)
        stopMouseTracking()
    }

    private func createPanel(companionManager: CompanionManager) {
        // No outer .frame here: the view sizes itself (TextCommandPanelView's
        // own .frame reads panelHeight) so it can grow when the Jev loop has
        // results to show. The window frame is driven by setResultsHeight.
        let textCommandView = TextCommandPanelView(companionManager: companionManager)

        let hostingView = NSHostingView(rootView: textCommandView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.sizingOptions = []

        let commandPanel = TextCommandKeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        commandPanel.onEscape = { [weak companionManager] in
            companionManager?.dismissTextCommandPanel()
        }
        commandPanel.isFloatingPanel = true
        commandPanel.level = .floating
        commandPanel.isOpaque = false
        commandPanel.backgroundColor = .clear
        commandPanel.hasShadow = isConversationLayout
        commandPanel.hidesOnDeactivate = false
        commandPanel.isExcludedFromWindowsMenu = true
        commandPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        commandPanel.isMovable = true
        commandPanel.isMovableByWindowBackground = false
        commandPanel.titleVisibility = .hidden
        commandPanel.titlebarAppearsTransparent = true
        commandPanel.contentView = hostingView

        panel = commandPanel
    }

    private func startMouseTracking() {
        stopMouseTracking()
        guard !isConversationLayout else { return }
        let trackingTimer = Timer(timeInterval: trackingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseTrackingTick()
            }
        }
        mouseTrackingTimer = trackingTimer
        RunLoop.main.add(trackingTimer, forMode: .common)
    }

    private func stopMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
        currentPanelOrigin = nil
    }

    /// While the loop is driving the pointer, the panel must stop chasing it —
    /// otherwise it flies across the screen mid-run and lands inside the very
    /// screenshot the next detection pass reads.
    func setTrackingFrozen(_ frozen: Bool) {
        isTrackingFrozen = frozen
        if frozen {
            mouseTrackingTimer?.invalidate()
            mouseTrackingTimer = nil
        } else if panel?.isVisible == true {
            startMouseTracking()
        }
    }

    /// Resize the live panel to fit `extraHeight` of results under the input.
    func setResultsHeight(_ extraHeight: CGFloat) {
        // In the conversation layout JEV reports through the activity line
        // under the input; its results height must not shrink the panel.
        guard !isConversationLayout else { return }
        resizePanel(to: NSSize(width: TextCommandPanelManager.defaultWidth,
                               height: TextCommandPanelManager.baseHeight + max(0, extraHeight)))
    }

    /// The Ctrl+K conversation with Her is wider and taller than the JEV input.
    func setConversationSize(_ size: NSSize) {
        isConversationLayout = true
        stopMouseTracking()
        panel?.hasShadow = true
        let currentFrame = panel?.isVisible == true ? panel?.frame : conversationPanelFrame
        let screen = currentFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        } ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            resizePanel(to: NSSize(
                width: min(size.width, max(1, visibleFrame.width - screenEdgeInset * 2)),
                height: min(size.height, max(1, visibleFrame.height - screenEdgeInset * 2))
            ))
        } else {
            resizePanel(to: size)
        }
    }

    func useJevLayout() {
        if isConversationLayout { conversationPanelFrame = panel?.frame }
        isConversationLayout = false
        panel?.hasShadow = false
        setResultsHeight(0)
    }

    private func resizePanel(to size: NSSize) {
        guard abs(panelSize.height - size.height) > 0.5 || abs(panelSize.width - size.width) > 0.5 else { return }
        panelSize = size
        if let panel {
            // The hosting view is generic over the wrapped root view type, so
            // resize it as a plain NSView rather than casting.
            panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)
            if isConversationLayout {
                restoreConversationFrame(panel.isVisible ? panel.frame : conversationPanelFrame ?? panel.frame)
            } else if isTrackingFrozen {
                let visibleFrame = panel.screen?.visibleFrame ?? panel.frame
                let origin = CGPoint(
                    x: min(max(panel.frame.minX, visibleFrame.minX), visibleFrame.maxX - panelSize.width),
                    y: max(visibleFrame.minY, panel.frame.maxY - panelSize.height)
                )
                currentPanelOrigin = origin
                panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
            } else {
                positionPanel(at: NSEvent.mouseLocation, animated: false)
            }
        }
    }

    private func handleMouseTrackingTick() {
        guard let panel, panel.isVisible, !isTrackingFrozen, !isConversationLayout else { return }
        positionPanel(at: NSEvent.mouseLocation, animated: true)
    }

    private func restoreConversationFrame(_ previousFrame: NSRect) {
        guard let panel else { return }
        let previousCenter = CGPoint(x: previousFrame.midX, y: previousFrame.midY)
        let visibleFrame = NSScreen.screens.first { $0.frame.contains(previousCenter) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? previousFrame
        let origin = CGPoint(
            x: min(max(previousFrame.minX, visibleFrame.minX + screenEdgeInset), visibleFrame.maxX - panelSize.width - screenEdgeInset),
            y: min(max(previousFrame.maxY - panelSize.height, visibleFrame.minY + screenEdgeInset), visibleFrame.maxY - panelSize.height - screenEdgeInset)
        )
        let frame = NSRect(origin: origin, size: panelSize)
        panel.setFrame(frame, display: true)
        conversationPanelFrame = frame
    }

    private func positionPanel(at mouseLocation: CGPoint, animated: Bool) {
        guard let panel else { return }
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main
        guard let screenFrame = isConversationLayout ? targetScreen?.visibleFrame : targetScreen?.frame else { return }

        let targetOrigin = targetPanelOrigin(
            mouseLocation: mouseLocation,
            panelSize: panelSize,
            screenFrame: screenFrame
        )
        let nextOrigin = smoothedOrigin(
            currentOrigin: currentPanelOrigin,
            targetOrigin: targetOrigin,
            animated: animated
        )
        currentPanelOrigin = nextOrigin

        let currentFrame = panel.frame
        let positionChanged = abs(currentFrame.minX - nextOrigin.x) > 0.35
            || abs(currentFrame.minY - nextOrigin.y) > 0.35
        guard positionChanged || currentFrame.size != panelSize else { return }

        panel.setFrame(
            NSRect(x: nextOrigin.x, y: nextOrigin.y, width: panelSize.width, height: panelSize.height),
            display: true,
            animate: false
        )
    }

    private func targetPanelOrigin(
        mouseLocation: CGPoint,
        panelSize: NSSize,
        screenFrame: CGRect
    ) -> CGPoint {
        let candidateOrigins = [
            CGPoint(
                x: mouseLocation.x + horizontalOffsetFromCursor,
                y: mouseLocation.y - panelSize.height - verticalOffsetFromCursor
            ),
            CGPoint(
                x: mouseLocation.x + horizontalOffsetFromCursor,
                y: mouseLocation.y + verticalOffsetFromCursor
            ),
            CGPoint(
                x: mouseLocation.x - panelSize.width - horizontalOffsetFromCursor,
                y: mouseLocation.y - panelSize.height - verticalOffsetFromCursor
            ),
            CGPoint(
                x: mouseLocation.x - panelSize.width - horizontalOffsetFromCursor,
                y: mouseLocation.y + verticalOffsetFromCursor
            )
        ]

        let cursorSafetyRect = CGRect(
            x: mouseLocation.x - cursorClearance,
            y: mouseLocation.y - cursorClearance,
            width: cursorClearance * 2,
            height: cursorClearance * 2
        )

        let clampedOrigin: (CGPoint) -> CGPoint = { origin in
            CGPoint(
                x: min(max(origin.x, screenFrame.minX + self.screenEdgeInset),
                       screenFrame.maxX - panelSize.width - self.screenEdgeInset),
                y: min(max(origin.y, screenFrame.minY + self.screenEdgeInset),
                       screenFrame.maxY - panelSize.height - self.screenEdgeInset)
            )
        }
        let placementCandidates = isConversationLayout ? candidateOrigins.map(clampedOrigin) : candidateOrigins
        let preferredOrigin = placementCandidates.first { candidateOrigin in
            let panelRect = CGRect(origin: candidateOrigin, size: panelSize)
            return screenFrame.contains(panelRect) && !panelRect.intersects(cursorSafetyRect)
        } ?? placementCandidates[0]

        return clampedOrigin(preferredOrigin)
    }

    private func smoothedOrigin(
        currentOrigin: CGPoint?,
        targetOrigin: CGPoint,
        animated: Bool
    ) -> CGPoint {
        guard animated, let currentOrigin else { return targetOrigin }

        let deltaX = targetOrigin.x - currentOrigin.x
        let deltaY = targetOrigin.y - currentOrigin.y
        if abs(deltaX) < 0.5, abs(deltaY) < 0.5 {
            return targetOrigin
        }

        return CGPoint(
            x: currentOrigin.x + deltaX * smoothingFactor,
            y: currentOrigin.y + deltaY * smoothingFactor
        )
    }

    private func fadePanel(to alphaValue: CGFloat) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = alphaValue
        }
    }
}
