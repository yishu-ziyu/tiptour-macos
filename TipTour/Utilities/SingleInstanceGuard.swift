import AppKit
import Darwin

/// Keeps exactly one interactive Her running.
///
/// Two interactive instances both register Ctrl+Option, both open a realtime
/// session and both speak; each one's echo canceller only removes its own
/// output, so each hears the other as the user (measured 2026-09-23: a 09:16
/// build kept running beside the Xcode build, and every utterance produced two
/// turns and two overlapping voices). The newly launched instance wins, which
/// is what a rebuild from Xcode means.
///
/// DEBUG probe runs are left alone: the acceptance runner deliberately starts
/// them with `open -n` next to the user's Her, and they never register hotkeys.
@MainActor
enum SingleInstanceGuard {
    private static let politeQuitTimeout: TimeInterval = 3

    /// Returns false when another interactive instance survived even a forced
    /// quit (measured: a process held by the Xcode debugger ignores both); the
    /// caller must then exit instead of becoming the second voice.
    static func retireOtherInteractiveInstances() async -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let otherInteractiveInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { runningApplication in
                runningApplication.processIdentifier != currentProcessIdentifier
                    && !runningApplication.isTerminated
                    && !isProbeLaunch(arguments: launchArguments(of: runningApplication.processIdentifier))
            }
        guard !otherInteractiveInstances.isEmpty else { return true }

        for otherInstance in otherInteractiveInstances {
            print("🎯 Her: another instance is running (pid \(otherInstance.processIdentifier)); asking it to quit")
            otherInstance.terminate()
        }
        let deadline = Date().addingTimeInterval(politeQuitTimeout)
        while Date() < deadline, otherInteractiveInstances.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for otherInstance in otherInteractiveInstances where !otherInstance.isTerminated {
            print("🎯 Her: pid \(otherInstance.processIdentifier) did not quit within \(Int(politeQuitTimeout))s; forcing it")
            otherInstance.forceTerminate()
        }
        let forcedQuitDeadline = Date().addingTimeInterval(1)
        while Date() < forcedQuitDeadline, otherInteractiveInstances.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return otherInteractiveInstances.allSatisfy(\.isTerminated)
    }

    /// Every DEBUG probe entry point is a `--…-probe` flag or `--preflight`
    /// (see VoiceRouteProbe.handleLaunch).
    private static func isProbeLaunch(arguments: [String]) -> Bool {
        arguments.contains { argument in argument.hasSuffix("-probe") || argument == "--preflight" }
    }

    /// argv of another process via `KERN_PROCARGS2`. Unreadable means "treat it
    /// as interactive": a duplicate voice session is the failure being prevented.
    private static func launchArguments(of processIdentifier: pid_t) -> [String] {
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var bufferSize = 0
        guard sysctl(&managementInformationBase, 3, nil, &bufferSize, nil, 0) == 0, bufferSize > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        guard sysctl(&managementInformationBase, 3, &buffer, &bufferSize, nil, 0) == 0,
              bufferSize > MemoryLayout<Int32>.size else { return [] }

        // Layout: Int32 argc, executable path, NUL padding, then argc NUL-terminated arguments.
        let argumentCount = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var cursor = MemoryLayout<Int32>.size
        while cursor < bufferSize, buffer[cursor] != 0 { cursor += 1 }
        while cursor < bufferSize, buffer[cursor] == 0 { cursor += 1 }

        var arguments: [String] = []
        while arguments.count < Int(argumentCount), cursor < bufferSize {
            let argumentStart = cursor
            while cursor < bufferSize, buffer[cursor] != 0 { cursor += 1 }
            arguments.append(String(decoding: buffer[argumentStart..<cursor], as: UTF8.self))
            cursor += 1
        }
        return arguments
    }
}
