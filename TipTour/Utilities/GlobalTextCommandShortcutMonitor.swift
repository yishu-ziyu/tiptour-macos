import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalTextCommandShortcutMonitor: ObservableObject {
    let shortcutPressedPublisher = PassthroughSubject<Void, Never>()

    private let eventTap = ListenOnlyEventTap(
        eventTypes: [.keyDown, .keyUp, .flagsChanged],
        logName: "Global text command"
    )
    private var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        eventTap.start { [weak self] eventType, event in
            self?.handleGlobalEventTap(eventType: eventType, event: event)
        }
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        eventTap.stop()
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let isControlK = keyCode == 40
            && modifierFlags.contains(.control)
            && !modifierFlags.contains(.option)
            && !modifierFlags.contains(.command)
            && !modifierFlags.contains(.shift)

        switch eventType {
        case .keyDown where isControlK && !isShortcutCurrentlyPressed:
            isShortcutCurrentlyPressed = true
            shortcutPressedPublisher.send(())
        case .keyUp, .flagsChanged:
            if !isControlK {
                isShortcutCurrentlyPressed = false
            }
        default:
            break
        }
    }
}
