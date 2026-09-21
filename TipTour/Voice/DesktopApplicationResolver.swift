import AppKit
import CoreServices
import CoreGraphics
import Foundation

struct DesktopApplicationCandidate: Equatable {
    let bundleIdentifier: String
    let url: URL
    let names: Set<String>

    nonisolated func contains(bundleURL otherURL: URL?) -> Bool {
        guard let otherURL else { return false }
        let rootPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let otherPath = otherURL.standardizedFileURL.resolvingSymlinksInPath().path
        return otherPath == rootPath || otherPath.hasPrefix(rootPath + "/Contents/")
    }
}

struct DesktopApplicationPresence: Equatable {
    let runningProcessIdentifiers: Set<pid_t>
    let visibleWindowProcessIdentifiers: Set<pid_t>
    let isForeground: Bool

    var hasVisibleWindow: Bool { !visibleWindowProcessIdentifiers.isEmpty }
    var isUserVisible: Bool { isForeground && hasVisibleWindow }
}

enum DesktopApplicationResolution: Equatable {
    case resolved(DesktopApplicationCandidate)
    case ambiguous([DesktopApplicationCandidate])
    case notFound
}

/// Resolves a human app name once, before execution, to a stable bundle ID.
/// The downstream launcher receives that identity instead of reinterpreting
/// localized prose independently at every layer.
@MainActor
enum DesktopApplicationResolver {
    private static let cacheLifetime: TimeInterval = 30
    private static var cachedCatalog: (capturedAt: Date, candidates: [DesktopApplicationCandidate])?

    /// Aliases are intentionally small and exact. Installed/localized metadata
    /// is preferred; these only cover common brand names macOS does not localize.
    private static let aliases: [String: String] = [
        "谷歌浏览器": "com.google.Chrome",
        "chrome浏览器": "com.google.Chrome",
        "safari浏览器": "com.apple.Safari",
        "苹果浏览器": "com.apple.Safari",
        "火狐浏览器": "org.mozilla.firefox",
        "firefox浏览器": "org.mozilla.firefox",
        "edge浏览器": "com.microsoft.edgemac"
    ]

    static func resolve(_ rawName: String) -> DesktopApplicationResolution {
        let query = normalized(rawName)
        guard !query.isEmpty else { return .notFound }

        let catalog = installedApplications()
        return match(query: query, candidates: catalog, aliases: aliases)
    }

    static func invalidateCache() {
        cachedCatalog = nil
    }

    static func presence(of candidate: DesktopApplicationCandidate) -> DesktopApplicationPresence {
        let relatedApplications = NSWorkspace.shared.runningApplications.filter {
            candidate.contains(bundleURL: $0.bundleURL) && !$0.isTerminated
        }
        let processIdentifiers = Set(relatedApplications.map(\.processIdentifier))
        let visibleWindowProcessIdentifiers = visibleTopLevelWindowProcessIdentifiers(
            belongingTo: processIdentifiers
        )
        let foregroundApplication = NSWorkspace.shared.frontmostApplication
        return DesktopApplicationPresence(
            runningProcessIdentifiers: processIdentifiers,
            visibleWindowProcessIdentifiers: visibleWindowProcessIdentifiers,
            isForeground: candidate.contains(bundleURL: foregroundApplication?.bundleURL)
        )
    }

    static func processIdentifiers(belongingTo applicationURL: URL) -> Set<pid_t> {
        let root = DesktopApplicationCandidate(bundleIdentifier: "", url: applicationURL, names: [])
        return Set(NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated, root.contains(bundleURL: application.bundleURL) else { return nil }
            return application.processIdentifier
        })
    }

    private static func visibleTopLevelWindowProcessIdentifiers(
        belongingTo processIdentifiers: Set<pid_t>
    ) -> Set<pid_t> {
        guard !processIdentifiers.isEmpty,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else { return [] }

        var visibleProcessIdentifiers = Set<pid_t>()
        for window in windows {
            let processIdentifier = pid_t((window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1)
            guard processIdentifiers.contains(processIdentifier),
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (boundsDictionary["Width"] as? NSNumber)?.doubleValue,
                  let height = (boundsDictionary["Height"] as? NSNumber)?.doubleValue,
                  width >= 80, height >= 60 else { continue }
            visibleProcessIdentifiers.insert(processIdentifier)
        }
        return visibleProcessIdentifiers
    }

    nonisolated static func match(
        query rawQuery: String,
        candidates: [DesktopApplicationCandidate],
        aliases: [String: String] = [:]
    ) -> DesktopApplicationResolution {
        let queryKeys = Set(lookupKeys(for: rawQuery))
        guard !queryKeys.isEmpty else { return .notFound }

        for queryKey in queryKeys {
            if let aliasedBundleIdentifier = aliases[queryKey],
               let candidate = candidates.first(where: { normalized($0.bundleIdentifier) == normalized(aliasedBundleIdentifier) }) {
                return .resolved(candidate)
            }
        }

        var matchesByBundleIdentifier: [String: DesktopApplicationCandidate] = [:]
        for candidate in candidates {
            let candidateKeys = candidate.names.flatMap(lookupKeys(for:))
                + lookupKeys(for: candidate.bundleIdentifier)
            if !queryKeys.isDisjoint(with: candidateKeys) {
                matchesByBundleIdentifier[candidate.bundleIdentifier] = candidate
            }
        }
        let matches = matchesByBundleIdentifier.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        if matches.count == 1 { return .resolved(matches[0]) }
        if matches.count > 1 { return .ambiguous(matches) }
        return .notFound
    }

    nonisolated static func normalized(_ text: String) -> String {
        var normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isWhitespace && !"“”‘’\"'".contains($0) }
        if normalized.hasSuffix(".app") { normalized.removeLast(4) }
        return normalized
    }

    private nonisolated static func lookupKeys(for name: String) -> [String] {
        let full = normalized(name)
        guard !full.isEmpty else { return [] }
        var keys = [full]
        for suffix in ["应用", "软件", "app"] where full.hasSuffix(suffix) && full.count > suffix.count {
            keys.append(String(full.dropLast(suffix.count)))
        }
        return Array(Set(keys))
    }

    private static func installedApplications() -> [DesktopApplicationCandidate] {
        if let cachedCatalog, Date().timeIntervalSince(cachedCatalog.capturedAt) < cacheLifetime {
            return cachedCatalog.candidates
        }

        var urlsByPath: [String: URL] = [:]
        for application in NSWorkspace.shared.runningApplications {
            if let url = application.bundleURL, isTopLevelApplicationBundle(url) {
                urlsByPath[url.path] = url
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            "\(home)/Applications",
            "\(home)/Applications/Chrome Apps.localized"
        ]
        for root in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in children where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                urlsByPath[url.path] = url
            }
        }

        var runningLocalizedNames: [String: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = application.bundleIdentifier,
                  let localizedName = application.localizedName,
                  runningLocalizedNames[bundleIdentifier] == nil else { continue }
            runningLocalizedNames[bundleIdentifier] = localizedName
        }

        var candidatesByIdentifier: [String: DesktopApplicationCandidate] = [:]
        for url in urlsByPath.values {
            guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else { continue }
            var names = Set<String>()
            names.insert(url.deletingPathExtension().lastPathComponent)
            if let displayName = bundle.infoDictionary?["CFBundleDisplayName"] as? String { names.insert(displayName) }
            if let bundleName = bundle.infoDictionary?["CFBundleName"] as? String { names.insert(bundleName) }
            if let runningName = runningLocalizedNames[bundleIdentifier] { names.insert(runningName) }
            if let spotlightName = spotlightDisplayName(for: url) { names.insert(spotlightName) }
            if let existing = candidatesByIdentifier[bundleIdentifier] {
                candidatesByIdentifier[bundleIdentifier] = DesktopApplicationCandidate(
                    bundleIdentifier: bundleIdentifier,
                    url: preferredApplicationURL(existing.url, url),
                    names: existing.names.union(names)
                )
            } else {
                candidatesByIdentifier[bundleIdentifier] = DesktopApplicationCandidate(
                    bundleIdentifier: bundleIdentifier,
                    url: url,
                    names: names
                )
            }
        }

        let catalog = candidatesByIdentifier.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        cachedCatalog = (Date(), catalog)
        return catalog
    }

    private static func spotlightDisplayName(for url: URL) -> String? {
        guard let item = MDItemCreate(nil, url.path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemDisplayName) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isTopLevelApplicationBundle(_ url: URL) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return false }
        var ancestor = url.deletingLastPathComponent()
        while ancestor.path != "/" && !ancestor.path.isEmpty {
            if ancestor.pathExtension.caseInsensitiveCompare("app") == .orderedSame { return false }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        return true
    }

    private static func preferredApplicationURL(_ first: URL, _ second: URL) -> URL {
        func score(_ url: URL) -> Int {
            let path = url.path
            if path.hasPrefix("/Applications/") { return 4 }
            if path.hasPrefix("/System/Applications/") { return 3 }
            if path.contains("/Applications/") { return 2 }
            return 1
        }
        return score(second) > score(first) ? second : first
    }
}
