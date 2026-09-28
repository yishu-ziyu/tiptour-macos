import Foundation
import Testing
@testable import TipTour

/// The day file is written by scripts/daily-discovery.py; these cases use its
/// exact shape, including fields Her does not read.
@MainActor
@Suite("Daily new things (roadmap 3.4)")
struct DiscoveryNoticesTests {
    private func makeFolder(chosen: [[String: Any]], day: String = "2026-09-28") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("her-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run: [String: Any] = ["date": day, "model": "step-3.7-flash", "item_count": 94, "chosen": chosen, "others": []]
        try JSONSerialization.data(withJSONObject: run).write(to: folder.appendingPathComponent("\(day).json"))
        return folder
    }

    private func pick(_ title: String, direction: String) -> [String: Any] {
        ["id": "i1", "title": title, "url": "https://example.com/\(title)", "date": "2026-09-28", "source": "Hacker News",
         "detail": "120 分", "direction": direction, "why_you": "你这周在嫌语音慢，这个可以比一下。", "worth": 3]
    }

    private let day = ISO8601DateFormatter().date(from: "2026-09-28T10:00:00+08:00")!

    @Test func eachPickIsPostedOnceEvenAfterARestart() throws {
        let folder = try makeFolder(chosen: [pick("voice", direction: "语音"), pick("codex", direction: "编程工具")])
        var posted: [DiscoveryPick] = []
        DiscoveryNotices(folder: folder) { posted.append($0) }.postNewPicks(today: day)
        DiscoveryNotices(folder: folder) { posted.append($0) }.postNewPicks(today: day)

        #expect(posted.map(\.title) == ["voice", "codex"])
        #expect(posted.first?.whyYou == "你这周在嫌语音慢，这个可以比一下。")
    }

    @Test func aSilencedDirectionIsNotPostedAndTheScriptCanReadIt() throws {
        let folder = try makeFolder(chosen: [pick("voice", direction: "语音"), pick("codex", direction: "编程工具")])
        var posted: [String] = []
        let notices = DiscoveryNotices(folder: folder) { posted.append($0.title) }
        notices.silence(direction: "语音")
        notices.silence(direction: "语音")
        notices.postNewPicks(today: day)

        #expect(posted == ["codex"])
        let silenced = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("silenced.json")))
        #expect(silenced as? [String] == ["语音"], "The script reads a plain list of direction titles")
    }

    @Test func nothingIsPostedWithoutTodaysRun() throws {
        let folder = try makeFolder(chosen: [pick("voice", direction: "语音")], day: "2026-09-27")
        var posted: [String] = []
        DiscoveryNotices(folder: folder) { posted.append($0.title) }.postNewPicks(today: day)
        #expect(posted.isEmpty, "Yesterday's picks are not announced as today's")
    }
}
