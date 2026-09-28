//
//  GlobalRadialInputShortcutMonitor.swift
//  TipTour
//
//  Hold Control + Option + Command to open the cursor-centered input switcher.
//  Mouse movement while held updates the highlighted wedge; release selects it.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalRadialInputShortcutMonitor: ObservableObject {
    enum SwitcherTransition {
        case began(CGPoint)
        case moved(CGPoint)
        case ended(CGPoint)
    }

    let switcherTransitionPublisher = PassthroughSubject<SwitcherTransition, Never>()

    private let eventTap = ListenOnlyEventTap(
        eventTypes: [.flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged],
        logName: "Global radial input"
    )
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        eventTap.start { [weak self] eventType, event in
            self?.handleGlobalEventTap(eventType: eventType, event: event)
        }
    }

    func stop() {
        if isShortcutCurrentlyPressed {
            switcherTransitionPublisher.send(.ended(NSEvent.mouseLocation))
        }
        isShortcutCurrentlyPressed = false

        eventTap.stop()
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) {
        let modifierCombinationIsHeld = Self.isSwitcherModifierCombinationHeld(event.flags)
        let mouseLocation = NSEvent.mouseLocation
        let isMouseMovementEvent = eventType == .mouseMoved
            || eventType == .leftMouseDragged
            || eventType == .rightMouseDragged

        switch eventType {
        case .flagsChanged:
            if modifierCombinationIsHeld && !isShortcutCurrentlyPressed {
                isShortcutCurrentlyPressed = true
                switcherTransitionPublisher.send(.began(mouseLocation))
            } else if isShortcutCurrentlyPressed && !modifierCombinationIsHeld {
                endSwitcherIfNeeded(at: mouseLocation)
            }
        case _ where isShortcutCurrentlyPressed && isMouseMovementEvent:
            switcherTransitionPublisher.send(.moved(mouseLocation))
        default:
            break
        }
    }

    private func endSwitcherIfNeeded(at mouseLocation: CGPoint) {
        guard isShortcutCurrentlyPressed else { return }
        isShortcutCurrentlyPressed = false
        switcherTransitionPublisher.send(.ended(mouseLocation))
    }

    private static func isSwitcherModifierCombinationHeld(_ flags: CGEventFlags) -> Bool {
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
        return modifierFlags.contains(.control)
            && modifierFlags.contains(.option)
            && modifierFlags.contains(.command)
            && !modifierFlags.contains(.shift)
    }
}
