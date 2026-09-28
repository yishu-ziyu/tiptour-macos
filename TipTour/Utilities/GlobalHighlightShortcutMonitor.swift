//
//  GlobalHighlightShortcutMonitor.swift
//  TipTour
//
//  Hold control + shift and move the mouse to draw a freeform focus
//  trail. The event tap is listen-only: it never blocks user input.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalHighlightShortcutMonitor: ObservableObject {
    enum HighlightTransition {
        case began(CGPoint)
        case moved(CGPoint)
        case ended
    }

    let highlightTransitionPublisher = PassthroughSubject<HighlightTransition, Never>()

    private let eventTap = ListenOnlyEventTap(
        eventTypes: [.flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged],
        logName: "Global highlight"
    )

    @Published private(set) var isHighlightShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        eventTap.start { [weak self] eventType, event in
            self?.handleGlobalEventTap(eventType: eventType, event: event)
        }
    }

    func stop() {
        if isHighlightShortcutCurrentlyPressed {
            highlightTransitionPublisher.send(.ended)
        }
        isHighlightShortcutCurrentlyPressed = false

        eventTap.stop()
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) {
        let isHighlightHeld = Self.isHighlightShortcutHeld(event.flags)
        let currentMouseLocation = NSEvent.mouseLocation
        let isMouseMovementEvent = eventType == .mouseMoved
            || eventType == .leftMouseDragged
            || eventType == .rightMouseDragged

        if isHighlightHeld && !isHighlightShortcutCurrentlyPressed {
            isHighlightShortcutCurrentlyPressed = true
            highlightTransitionPublisher.send(.began(currentMouseLocation))
        } else if !isHighlightHeld && isHighlightShortcutCurrentlyPressed {
            isHighlightShortcutCurrentlyPressed = false
            highlightTransitionPublisher.send(.ended)
        } else if isHighlightHeld && isMouseMovementEvent {
            highlightTransitionPublisher.send(.moved(currentMouseLocation))
        }
    }

    private static func isHighlightShortcutHeld(_ flags: CGEventFlags) -> Bool {
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
        return modifierFlags.contains(.control)
            && modifierFlags.contains(.shift)
            && !modifierFlags.contains(.option)
            && !modifierFlags.contains(.command)
    }
}
