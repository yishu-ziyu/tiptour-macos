//
//  DiscoveryNotices.swift
//  TipTour
//
//  Roadmap 3.4 (trial): posts the new things `scripts/daily-discovery.py`
//  picked for today. The script runs once a day from a LaunchAgent and writes
//  `<date>.json` into this folder; Her only reads it, posts each pick once, and
//  records 「这类别推」 in `silenced.json`, which the script reads next time.
//

import Foundation

struct DiscoveryPick: Decodable, Equatable {
    let title: String
    let url: String
    let date: String
    let source: String
    let direction: String
    let whyYou: String

    enum CodingKeys: String, CodingKey {
        case title, url, date, source, direction
        case whyYou = "why_you"
    }
}

@MainActor
final class DiscoveryNotices {
    nonisolated static let defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Her/discovery", isDirectory: true)

    private let folder: URL
    private let post: @MainActor (DiscoveryPick) -> Void
    private var timer: Timer?

    init(folder: URL = DiscoveryNotices.defaultFolder, post: @escaping @MainActor (DiscoveryPick) -> Void) {
        self.folder = folder
        self.post = post
    }

    /// Checks now and every ten minutes, so a run that finishes while Her is
    /// open is announced soon after, and one from before a launch at launch.
    func startChecking() {
        postNewPicks()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.postNewPicks() }
        }
    }

    /// Posts today's picks that were never posted and whose kind is not silenced.
    func postNewPicks(today: Date = Date()) {
        let day = Self.dayFormatter.string(from: today)
        guard let run = read(RunFile.self, "\(day).json") else { return }
        var posted = Set(read([String].self, "posted.json") ?? [])
        let silenced = Set(read([String].self, "silenced.json") ?? [])
        for pick in run.chosen where !posted.contains(pick.url) && !silenced.contains(pick.direction) {
            post(pick)
            posted.insert(pick.url)
        }
        write(posted.sorted(), "posted.json")
    }

    /// 「这类别推」: the script leaves this direction out from the next run on.
    func silence(direction: String) {
        var silenced = read([String].self, "silenced.json") ?? []
        guard !silenced.contains(direction) else { return }
        silenced.append(direction)
        write(silenced, "silenced.json")
    }

    private struct RunFile: Decodable {
        let chosen: [DiscoveryPick]
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func read<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, _ name: String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            print("DiscoveryNotices: could not write \(name): \(error.localizedDescription)")
        }
    }
}
