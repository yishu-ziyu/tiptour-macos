//
//  ListenOnlyEventTap.swift
//  TipTour
//
//  The CGEvent tap shared by the global shortcut monitors. It only listens:
//  every event passes through unchanged, so a shortcut never blocks input.
//

import CoreGraphics
import Foundation

final class ListenOnlyEventTap {
    private let eventTypes: [CGEventType]
    private let logName: String
    private var handleEvent: ((CGEventType, CGEvent) -> Void)?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    /// `logName` prefixes the warnings printed when macOS refuses the tap.
    init(eventTypes: [CGEventType], logName: String) {
        self.eventTypes = eventTypes
        self.logName = logName
    }

    deinit {
        stop()
    }

    func start(handleEvent: @escaping (CGEventType, CGEvent) -> Void) {
        // If the event tap is already running, don't restart it. The permission
        // poller calls start() every few seconds, and a restart would reset a
        // shortcut that is being held right now.
        guard eventTap == nil else { return }
        self.handleEvent = handleEvent

        let eventMask = eventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let listenOnlyEventTap = Unmanaged<ListenOnlyEventTap>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return listenOnlyEventTap.handle(eventType: eventType, event: event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ \(logName): couldn't create CGEvent tap")
            return
        }

        guard let eventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            print("⚠️ \(logName): couldn't create event tap run loop source")
            return
        }

        self.eventTap = eventTap
        self.eventTapRunLoopSource = eventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    /// Runs on the main run loop, so handlers may update main-thread state.
    private func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        handleEvent?(eventType, event)
        return Unmanaged.passUnretained(event)
    }
}
