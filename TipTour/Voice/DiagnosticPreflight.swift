#if DEBUG
import AppKit
import ApplicationServices
import Foundation

/// DEBUG-only, read-only acceptance preflight. Runs inside the signed app so
/// the acceptance runner can prove the *process identity and real
/// preconditions* of the binary it is about to drive — and BLOCK before any
/// provider call, Driver call, microphone use, or Keychain secret read.
///
/// Nothing here mutates the machine: no desktop action, no permission prompt
/// (AXIsProcessTrusted is a read-only check; the screen-recording state is
/// recorded as unverifiable because this SDK has no read-only public API for
/// it), no microphone, no keychain item is opened. A failing fact is
/// recorded, never fatal, so a partially unreadable host still yields a
/// complete report.
@MainActor
enum DiagnosticPreflight {

    /// Collects the read-only facts, writes pretty JSON with sorted keys to
    /// `outputURL`, and prints a one-line summary. The probe caller terminates
    /// the app after this returns.
    static func run(outputURL: URL) async {
        let bundle = Bundle.main
        let binaryPath = bundle.executablePath ?? ""
        let accessibilityTrusted = AXIsProcessTrusted()
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostBundleIdentifier = frontmostApplication?.bundleIdentifier ?? ""
        // This SDK exposes no public read-only screen-recording preflight
        // (CGPreflightScreenRecordingAccess is absent; CGRequestScreenCaptureAccess
        // prompts, which an unattended preflight must never do). Record the gap
        // instead of guessing: the runner treats it as an unknown, not a grant.
        let screenRecordingAccess = "not_checked_no_public_readonly_api"

        var payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle_identifier": bundle.bundleIdentifier ?? "",
            "bundle_executable": bundle.infoDictionary?["CFBundleExecutable"] as? String ?? "",
            "bundle_version": bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "binary_path": binaryPath,
            "accessibility_trusted": accessibilityTrusted,
            "frontmost_bundle_id": frontmostBundleIdentifier,
            "frontmost_localized_name": frontmostApplication?.localizedName ?? "",
            "screen_recording": screenRecordingAccess,
            "codesign": await codesignDetails(binaryPath: binaryPath)
        ]

        // Only the checks the runner must gate on are listed here; anything
        // missing from this process identity ends up in blocked_reasons.
        var blockedReasons: [String] = []
        if !accessibilityTrusted {
            blockedReasons.append("accessibility_not_trusted")
        }
        if bundle.bundleIdentifier?.isEmpty != false {
            blockedReasons.append("bundle_identifier_missing")
        }
        if binaryPath.isEmpty {
            blockedReasons.append("binary_path_missing")
        }
        if frontmostBundleIdentifier.isEmpty {
            blockedReasons.append("frontmost_application_unknown")
        }
        payload["required_checks"] = ["accessibility": accessibilityTrusted]
        payload["blocked_reasons"] = blockedReasons

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL, options: .atomic)
            print("[DiagnosticPreflight] accessibility=\(accessibilityTrusted) frontmost=\(frontmostBundleIdentifier.isEmpty ? "unknown" : frontmostBundleIdentifier)")
        } catch {
            // A preflight that cannot write its own report is itself a failure
            // the runner must see, so it is printed rather than swallowed.
            print("[DiagnosticPreflight] Failed to write \(outputURL.path): \(error.localizedDescription)")
        }
    }

    /// Reads `codesign -dv --verbose=2` for the running binary off the main
    /// actor, bounded to 10 seconds. Read-only: this only inspects the
    /// signature that is already on disk, never re-signs or verifies with a
    /// network fetch.
    private static func codesignDetails(binaryPath: String) async -> [String: Any] {
        guard !binaryPath.isEmpty else {
            return ["team_identifier": "", "error": "binary_path_missing"]
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["-dv", "--verbose=2", binaryPath]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ["team_identifier": "", "error": error.localizedDescription])
                    return
                }
                let exited = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    exited.signal()
                }
                let timedOut = exited.wait(timeout: .now() + .seconds(10)) == .timedOut
                if timedOut {
                    process.terminate()
                }
                let raw = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                var details: [String: Any] = [
                    "team_identifier": teamIdentifier(from: raw),
                    "exit_code": Int(process.terminationStatus),
                    "timed_out": timedOut
                ]
                details["output"] = String(raw.prefix(4000))
                continuation.resume(returning: details)
            }
        }
    }

    /// Pulls `TeamIdentifier=...` out of the verbose codesign report.
    /// Nonisolated: it is pure text work and runs off the main actor.
    nonisolated private static func teamIdentifier(from codesignOutput: String) -> String {
        for line in codesignOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TeamIdentifier=") {
                return String(trimmed.dropFirst("TeamIdentifier=".count))
            }
        }
        return ""
    }
}
#endif
