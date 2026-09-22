//
//  FollowupRaceProbe.swift
//  stepprobe
//
//  Measures the exact race the desktop voice path has to survive: a tool result
//  is reported and a follow-up `response.create` is in flight when the user
//  starts talking over it. The app needs to discard that follow-up without
//  discarding the user's next response, which is only possible if the server
//  echoes something the client can correlate — a request token — or if a
//  cancelled response never produces `response.created` at all.
//
//  It answers three questions with observation, not assumption:
//    1. Does `response.created` echo client-supplied `response.metadata`?
//    2. Does `response.created` echo a client-supplied `event_id`?
//    3. When `response.cancel` arrives right after `response.create`, does the
//       server still emit `response.created` for the cancelled response, and
//       what does its `response.done` report?
//

import Foundation

struct FollowupRaceProbe {
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func run() async throws {
        let url = URL(string: "wss://api.stepfun.com/v1/realtime?model=\(model)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let task = URLSession(configuration: .default).webSocketTask(with: request)
        task.resume()

        let collector = EventRecorder()
        let receiveTask = Task.detached { await collector.receiveLoop(from: task) }

        try await send(task, ["type": "session.update", "session": [
            // Text only: the questions are about response bookkeeping, not audio.
            "modalities": ["text"],
            "instructions": "Answer in one short sentence.",
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "turn_detection": NSNull(),
        ]])
        try await collector.waitForEvent(ofType: "session.updated", timeoutSeconds: 15)
        print("  session configured (text-only, \(model))")

        func userTurn(_ text: String) async throws {
            try await send(task, [
                "type": "conversation.item.create",
                "item": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": text]]],
            ])
        }

        // Round 1 — does response.metadata survive into response.created?
        // Every baseline is captured BEFORE the send that should produce the
        // event: a fast server's `response.created` can arrive before any wait
        // starts, and a baseline taken afterwards would count it as an old
        // event and time out on a response that already exists.
        print("\n== round 1: response.create with response.metadata token ==")
        try await userTurn("probe round one")
        let roundOneCreatedBaseline = await collector.count(ofType: "response.created")
        let roundOneDoneBaseline = await collector.count(ofType: "response.done")
        try await send(task, [
            "type": "response.create",
            "response": ["modalities": ["text"], "metadata": ["probe_token": "META-TOKEN-1"]],
        ])
        let roundOneCreated = try await collector.waitForEvent(
            ofType: "response.created", afterCount: roundOneCreatedBaseline, timeoutSeconds: 30)
        _ = try await collector.waitForEvent(
            ofType: "response.done", afterCount: roundOneDoneBaseline, timeoutSeconds: 30)
        let metadataEchoed = roundOneCreated.contains("META-TOKEN-1")

        // Round 2 — does a top-level client event_id survive? A client-sent
        // event_id may make the server drop the event entirely; either outcome
        // is evidence, so this round never aborts the probe.
        print("\n== round 2: response.create with client event_id ==")
        try await userTurn("probe round two")
        let roundTwoCreatedBaseline = await collector.count(ofType: "response.created")
        let roundTwoDoneBaseline = await collector.count(ofType: "response.done")
        try await send(task, [
            "type": "response.create",
            "event_id": "CLIENT-EVENT-2",
            "response": ["modalities": ["text"]],
        ])
        let roundTwoCreated = try? await collector.waitForEvent(
            ofType: "response.created", afterCount: roundTwoCreatedBaseline, timeoutSeconds: 12)
        let eventIDEchoed = roundTwoCreated?.contains("CLIENT-EVENT-2") == true
        print("  response.create carrying a client event_id produced a response: \(roundTwoCreated != nil)")
        _ = try? await collector.waitForEvent(
            ofType: "response.done", afterCount: roundTwoDoneBaseline, timeoutSeconds: 12)

        // Round 3 — the race: create then cancel before the response can start.
        print("\n== round 3: response.create immediately cancelled (the barge-in race) ==")
        try await userTurn("probe round three")
        let createdBaseline = await collector.count(ofType: "response.created")
        try await send(task, [
            "type": "response.create",
            "response": ["modalities": ["text"], "metadata": ["probe_token": "META-TOKEN-3"]],
        ])
        try await send(task, ["type": "response.cancel"])
        print("  sent response.create (META-TOKEN-3) followed immediately by response.cancel")
        try await Task.sleep(nanoseconds: 8_000_000_000)
        let roundThreeCreated = await collector.events(ofType: "response.created")
        let cancelledFollowupCreated = roundThreeCreated.count > createdBaseline
        let cancelledDoneStatuses = await collector.events(ofType: "response.done")
            .filter { $0.contains("\"status\":\"incomplete\"") || $0.contains("\"status\": \"incomplete\"")
                || $0.contains("\"status\":\"cancelled\"") || $0.contains("\"status\": \"cancelled\"") }
            .count

        // Round 4 — the user's own next response after the cancellation.
        print("\n== round 4: the user's next response after cancellation ==")
        try await userTurn("probe round four")
        let roundFourCreatedBaseline = await collector.count(ofType: "response.created")
        let roundFourDoneBaseline = await collector.count(ofType: "response.done")
        try await send(task, ["type": "response.create", "response": ["modalities": ["text"]]])
        let roundFourCreated = try? await collector.waitForEvent(
            ofType: "response.created", afterCount: roundFourCreatedBaseline, timeoutSeconds: 20)
        let usersNextResponseAccepted = roundFourCreated != nil
        _ = try? await collector.waitForEvent(
            ofType: "response.done", afterCount: roundFourDoneBaseline, timeoutSeconds: 20)
        print("  the user's next response was created normally: \(usersNextResponseAccepted)")

        task.cancel(with: .goingAway, reason: nil)
        receiveTask.cancel()

        print("""

          ====================  VERDICT  ====================
          response.created echoes response.metadata: \(metadataEchoed ? "YES" : "NO")
          response.created echoes client event_id:   \(eventIDEchoed ? "YES" : "NO")
          cancelled follow-up still emitted created: \(cancelledFollowupCreated ? "YES" : "NO")
          cancelled follow-up done status incomplete/cancelled: \(cancelledDoneStatuses) event(s)
          user's next response accepted after cancel: \(usersNextResponseAccepted ? "YES" : "NO")
          ===================================================
          """)
        if !metadataEchoed && !eventIDEchoed {
            print("""
              No client correlation token survives into response.created, so a
              pending follow-up cannot be told apart from the user's next
              response by id. The app must not rely on "the next created is the
              old receipt".

              """)
        }
    }

    private func send(_ task: URLSessionWebSocketTask, _ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProbeError.malformedResponse("cannot encode client event")
        }
        try await task.send(.string(text))
    }
}

/// Records raw server frames verbatim. Raw text is kept for `response.created`
/// so the echo question is answered by the payload itself, not a summary.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var allEvents: [String] = []

    func receiveLoop(from task: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                return
            }
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = object["type"] as? String else { continue }
            lock.withLock { allEvents.append(text) }
            let printed = text.count > 400 ? String(text.prefix(400)) + "…" : text
            print("    [event] \(printed)")
        }
    }

    func events(ofType eventType: String) -> [String] {
        lock.withLock { allEvents }.filter { $0.contains("\"type\":\"\(eventType)\"") }
    }

    func waitForEvent(ofType eventType: String, timeoutSeconds: Double) async throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let event = await latestEvent(ofType: eventType, seenAfterBaseline: 0) { return event }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ProbeError.malformedResponse("timed out after \(Int(timeoutSeconds))s waiting for `\(eventType)`")
    }

    /// Waits for the NEXT event of a type, where the baseline count was
    /// captured by the caller BEFORE the request that should produce it was
    /// sent. Taking the baseline inside the waiter is a race: a fast server's
    /// event can already have arrived, would be counted as old, and the wait
    /// would time out on a response that exists.
    func waitForEvent(ofType eventType: String, afterCount baseline: Int, timeoutSeconds: Double) async throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let events = events(ofType: eventType)
            if events.count > baseline { return events[events.count - 1] }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ProbeError.malformedResponse("timed out after \(Int(timeoutSeconds))s waiting for a new `\(eventType)`")
    }

    func count(ofType eventType: String) async -> Int {
        events(ofType: eventType).count
    }

    private func latestEvent(ofType eventType: String, seenAfterBaseline: Int) async -> String? {
        let events = events(ofType: eventType)
        return events.count > seenAfterBaseline ? events[events.count - 1] : nil
    }
}
