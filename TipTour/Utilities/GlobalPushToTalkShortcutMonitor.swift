//
//  GlobalPushToTalkShortcutMonitor.swift
//  TipTour
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<PushToTalkShortcut.ShortcutTransition, Never>()

    private let eventTap = ListenOnlyEventTap(
        eventTypes: [.flagsChanged, .keyDown, .keyUp],
        logName: "Global push-to-talk"
    )
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
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
        isShortcutCurrentlyPressed = false

        eventTap.stop()
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) {
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = PushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }
    }
}
