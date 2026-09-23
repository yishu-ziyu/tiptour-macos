import Foundation

/// The state the acceptance side reads back through `GET /state`.
/// It is *only* ever written from real UI callbacks (button actions, the text
/// field's own content changes, real window lifecycle) — never fabricated.
struct HostViewState: Equatable {
    var selected: String?
    var clicks: Int = 0
    var events: [String] = []
    var typedText: String = ""
    var menuOpen: Bool = false
    var secondWindowVisible: Bool = false
    var pageViews: Int = 0

    /// Mirrors the fixture's visible result line: 已选择：…，点击次数：…，步骤：…
    var summary: String {
        let selectedText = selected ?? "无"
        let stepsText = events.isEmpty ? "无" : events.joined(separator: " → ")
        return "已选择：\(selectedText)，点击次数：\(clicks)，步骤：\(stepsText)"
    }
}

/// Single source of truth for the controlled host's side effects.
///
/// Threading: every mutation runs under `lock`. The published `view` copy is
/// always written on the main actor (UI callbacks are already there; the state
/// service hops with `DispatchQueue.main.async`), so SwiftUI refresh is safe.
final class HostStore: ObservableObject {
    static let shared = HostStore()

    @Published private(set) var view = HostViewState()

    private let lock = NSLock()
    private var selected: String?
    private var clicks = 0
    private var events: [String] = []
    private var typedText = ""
    private var menuOpen = false
    private var secondWindowVisible = false
    private var pageViews = 0

    private init() {}

    // MARK: - Real UI callbacks

    /// A 「设置」 / 「缩放选项」 / 「检查官网部署状态」 / menu-command activation.
    func select(_ value: String) {
        publish(mutating { state in
            state.selected = value
            state.clicks += 1
            state.events.append(value)
        })
    }

    /// 「打开显示设置」 — reveals the hidden 「缩放选项」 section.
    func openDisplaySettings() {
        publish(mutating { state in
            state.menuOpen = true
            state.events.append("open-menu")
        })
    }

    /// Real content changes of the notes text field (`notes-field`).
    func updateTypedText(_ text: String) {
        publish(mutating { state in
            state.typedText = text
        })
    }

    /// Real open/close of the second window (button, in-window dismiss or the
    /// window's own close button).
    func secondWindowVisibilityChanged(_ visible: Bool) {
        publish(mutating { state in
            state.secondWindowVisible = visible
            state.events.append(visible ? "second-window-open" : "second-window-close")
        })
    }

    /// A main-window appearance — the native analogue of the fixture's
    /// `page_views`. Deliberately *not* reset by `reset()`.
    func recordPageView() {
        publish(mutating { state in
            state.pageViews += 1
        })
    }

    /// Resets the test-relevant fields only. `page_views` stays, matching
    /// fixture.py's documented diagnostic behaviour ("a reset resets test
    /// semantics only").
    func reset() {
        publish(mutating { state in
            state.selected = nil
            state.clicks = 0
            state.events = []
            state.typedText = ""
            state.menuOpen = false
            state.secondWindowVisible = false
        })
    }

    // MARK: - Machine readback

    /// Stable-key-order JSON for `GET /state` / `POST /reset`.
    var stateJSON: String {
        lock.lock()
        defer { lock.unlock() }
        return jsonStringLocked()
    }

    // MARK: - Internals

    private typealias State = HostViewState

    private func mutating(_ body: (inout State) -> Void) -> State {
        lock.lock()
        var next = State(
            selected: selected,
            clicks: clicks,
            events: events,
            typedText: typedText,
            menuOpen: menuOpen,
            secondWindowVisible: secondWindowVisible,
            pageViews: pageViews
        )
        body(&next)
        selected = next.selected
        clicks = next.clicks
        events = next.events
        typedText = next.typedText
        menuOpen = next.menuOpen
        secondWindowVisible = next.secondWindowVisible
        pageViews = next.pageViews
        lock.unlock()
        return next
    }

    private func publish(_ snapshot: State) {
        if Thread.isMainThread {
            view = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.view = snapshot
            }
        }
    }

    private func jsonStringLocked() -> String {
        var json = "{"
        json += "\"selected\":" + (selected.map(Self.jsonString) ?? "null") + ","
        json += "\"clicks\":\(clicks),"
        json += "\"events\":" + Self.jsonArray(events) + ","
        json += "\"typed_text\":" + Self.jsonString(typedText) + ","
        json += "\"menu_open\":\(menuOpen),"
        json += "\"second_window_visible\":\(secondWindowVisible),"
        json += "\"page_views\":\(pageViews)"
        json += "}"
        return json
    }

    private static func jsonArray(_ values: [String]) -> String {
        "[" + values.map(jsonString).joined(separator: ",") + "]"
    }

    private static func jsonString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        for character in value {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if let ascii = character.asciiValue, ascii < 0x20 {
                    escaped += String(format: "\\u%04x", ascii)
                } else {
                    escaped.append(character)
                }
            }
        }
        return "\"" + escaped + "\""
    }
}
