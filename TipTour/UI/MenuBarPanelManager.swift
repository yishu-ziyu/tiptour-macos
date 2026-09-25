//
//  MenuBarPanelManager.swift
//  TipTour
//
//  Owns the menu bar status item and delegates panel mechanics to
//  FloatingCompanionPanel.
//

import AppKit

extension Notification.Name {
    static let tipTourDismissPanel = Notification.Name("tipTourDismissPanel")
    /// Posted each time the panel is shown, so the panel can replay its reveal.
    static let tipTourPanelDidShow = Notification.Name("tipTourPanelDidShow")
    static let tipTourOpenSettings = Notification.Name("tipTourOpenSettings")
    static let tipTourOpenLogs = Notification.Name("tipTourOpenLogs")
    static let tipTourPanelPinStateChanged = Notification.Name("tipTourPanelPinStateChanged")
    static let tipTourUserInterfaceActionExecuted = Notification.Name("tipTourUserInterfaceActionExecuted")
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: FloatingCompanionPanel<CompanionPanelView>?
    private var settingsWindowManager: TipTourSettingsWindowManager?
    private var logsWindowManager: TipTourLogsWindowManager?
    private var dismissPanelObserver: NSObjectProtocol?
    private var openSettingsObserver: NSObjectProtocol?
    private var openLogsObserver: NSObjectProtocol?
    private var pinStateChangedObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = PanelStyle.width
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        settingsWindowManager = TipTourSettingsWindowManager(companionManager: companionManager)
        logsWindowManager = TipTourLogsWindowManager()
        createStatusItem()
        installPanelObservers()
    }

    deinit {
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = openSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = openLogsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = pinStateChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the same pointer silhouette used by the overlay cursor.
    private func makeMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let viewBoxSize: CGFloat = 24
        let scale = iconSize * 0.78 / viewBoxSize
        let originX = iconSize * 0.5 - viewBoxSize * scale * 0.5
        let originY = iconSize * 0.5 - viewBoxSize * scale * 0.5

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: originX + x * scale,
                y: originY + (viewBoxSize - y) * scale
            )
        }

        let path = NSBezierPath()
        path.move(to: point(4.037, 4.688))
        path.curve(
            to: point(4.688, 4.037),
            controlPoint1: point(3.90, 3.90),
            controlPoint2: point(3.90, 3.90)
        )
        path.line(to: point(20.688, 10.537))
        path.curve(
            to: point(20.625, 11.484),
            controlPoint1: point(21.42, 10.84),
            controlPoint2: point(21.42, 10.84)
        )
        path.line(to: point(14.501, 13.064))
        path.curve(
            to: point(13.063, 14.499),
            controlPoint1: point(13.43, 13.34),
            controlPoint2: point(13.43, 13.34)
        )
        path.line(to: point(11.484, 20.625))
        path.curve(
            to: point(10.537, 20.688),
            controlPoint1: point(11.17, 21.42),
            controlPoint2: point(11.17, 21.42)
        )
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if panel?.isPresented == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        panel?.showAnchoredToStatusItem()
        NotificationCenter.default.post(name: .tipTourPanelDidShow, object: nil)
        // The window shadow is computed from the panel's visible shape; recompute
        // it once the pill-to-panel reveal (95 + 480 ms) has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.panel?.invalidateShadow()
        }
    }

    private func hidePanel() {
        panel?.hide()
    }

    private func createPanel() {
        panel = FloatingCompanionPanel(
            width: panelWidth,
            initialHeight: panelHeight,
            statusBarButton: statusItem?.button,
            isPinnedProvider: { [weak companionManager] in
                companionManager?.isPanelPinned ?? false
            },
            shouldDeferOutsideClickDismissal: { [weak companionManager] in
                guard let companionManager else { return false }
                return !companionManager.allPermissionsGranted && !NSApp.isActive
            }
        ) {
            CompanionPanelView(companionManager: companionManager)
        }
        // The panel view draws a clipped material, so the window supplies the
        // drop shadow; it follows the visible shape once the reveal settles.
        panel?.hasShadow = true
    }

    private func installPanelObservers() {
        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .tipTourDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanel()
            }
        }

        openSettingsObserver = NotificationCenter.default.addObserver(
            forName: .tipTourOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.settingsWindowManager?.show()
            }
        }

        openLogsObserver = NotificationCenter.default.addObserver(
            forName: .tipTourOpenLogs,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.logsWindowManager?.show()
            }
        }

        pinStateChangedObserver = NotificationCenter.default.addObserver(
            forName: .tipTourPanelPinStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panel?.refreshOutsideClickMonitor()
            }
        }
    }
}
