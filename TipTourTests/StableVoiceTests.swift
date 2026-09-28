import Foundation
import Testing

@testable import TipTour

/// Answers every request with one canned HTTP response and keeps the request.
private final class StubHTTP: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var lastRequestBody: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastRequestBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(status: Int, body: String) -> URLSession {
        Self.status = status
        Self.body = body
        Self.lastRequestBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return URLSession(configuration: configuration)
    }
}

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

@Suite("声音稳定 voice style", .serialized)
struct StableVoiceTests {

    // MARK: Speech to text

    @Test func anUtteranceComesBackAsTheFinalText() async throws {
        let stream = """
            data: {"type":"transcript.text.delta","delta":"帮我看看"}

            data: {"type":"transcript.text.delta","delta":"那个改动"}

            data: {"type":"transcript.text.done","text":"帮我看看那个改动合了没有。"}

            """
        let transcriber = StepAudioTranscriber(apiKey: "k", session: StubHTTP.session(status: 200, body: stream))
        let audio = Data([1, 2, 3, 4])
        let text = try await transcriber.transcribe(pcm16: audio)
        #expect(text == "帮我看看那个改动合了没有。")
        let sent = try #require(StubHTTP.lastRequestBody?["audio"] as? [String: Any])
        #expect(sent["data"] as? String == audio.base64EncodedString())
        let format = try #require((sent["input"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["rate"] as? Int == 16_000)
    }

    @Test func withoutAFinalEventTheDeltasAreTheText() throws {
        let text = try StepAudioTranscriber.text(fromEventStream: """
            data: {"type":"transcript.text.delta","delta":"你好"}
            data: {"type":"transcript.text.delta","delta":"呀"}
            """)
        #expect(text == "你好呀")
    }

    @Test func aProviderErrorIsReportedInItsOwnWords() async {
        let transcriber = StepAudioTranscriber(apiKey: "k", session: StubHTTP.session(
            status: 200, body: #"data: {"type":"error","message":"audio too short"}"#))
        do {
            _ = try await transcriber.transcribe(pcm16: Data([0, 0]))
            Issue.record("an error event must not become text")
        } catch let error as StepAudioTranscriberError {
            #expect(error.userMessage == "阶跃没能转成文字：audio too short")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func aRefusedKeyIsAnHTTPErrorNotSilence() async {
        let transcriber = StepAudioTranscriber(apiKey: "k", session: StubHTTP.session(status: 401, body: "{}"))
        await #expect(throws: StepAudioTranscriberError.http(status: 401, body: "{}")) {
            _ = try await transcriber.transcribe(pcm16: Data([0, 0]))
        }
    }

    // MARK: Speech

    @Test func speechPlaysEveryChunkInOrderAndNotTheRepeatAtTheEnd() async throws {
        let body = """
            data: {"data":{"audio":"\(hex([1, 2]))","status":1},"base_resp":{"status_code":0,"status_msg":""}}

            data: {"data":{"audio":"\(hex([3, 4, 5, 6]))","status":1},"base_resp":{"status_code":0,"status_msg":""}}

            data: {"data":{"audio":"\(hex([1, 2, 3, 4, 5, 6]))","status":2},"extra_info":{},"base_resp":{"status_code":0,"status_msg":"success"}}

            """
        let client = MiniMaxSpeechClient(apiKey: "k", voiceID: "my-voice", session: StubHTTP.session(status: 200, body: body))
        let heard = Heard()
        try await client.speak("你好") { await heard.add($0) }
        #expect(await heard.bytes == [1, 2, 3, 4, 5, 6])
        let voice = try #require(StubHTTP.lastRequestBody?["voice_setting"] as? [String: Any])
        #expect(voice["voice_id"] as? String == "my-voice")
        let audio = try #require(StubHTTP.lastRequestBody?["audio_setting"] as? [String: Any])
        #expect(audio["format"] as? String == "pcm")
        #expect(audio["sample_rate"] as? Int == 24_000)
    }

    @Test func theChosenSpeedIsTheSpeedSheSpeaksAt() async throws {
        let body = #"data: {"data":{"audio":"0102","status":1},"base_resp":{"status_code":0,"status_msg":""}}"#
        let client = MiniMaxSpeechClient(apiKey: "k", voiceID: "v", session: StubHTTP.session(status: 200, body: body))
        try await client.speak("你好", speed: 1.3) { _ in }
        #expect((StubHTTP.lastRequestBody?["voice_setting"] as? [String: Any])?["speed"] as? Double == 1.3)
        let tooFast = MiniMaxSpeechClient(apiKey: "k", voiceID: "v", session: StubHTTP.session(status: 200, body: body))
        try await tooFast.speak("你好", speed: 5) { _ in }
        #expect((StubHTTP.lastRequestBody?["voice_setting"] as? [String: Any])?["speed"] as? Double == 2)
    }

    @Test func aMiniMaxRefusalIsReportedWithItsMessage() async {
        let client = MiniMaxSpeechClient(apiKey: "k", voiceID: "v", session: StubHTTP.session(
            status: 200, body: #"{"base_resp":{"status_code":2054,"status_msg":"voice id not exist"}}"#))
        do {
            try await client.speak("你好") { _ in }
            Issue.record("a refusal must not pass as speech")
        } catch let error as MiniMaxSpeechError {
            #expect(error.userMessage == "MiniMax 没能念出来：voice id not exist（2054）")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func aResponseWithNoAudioIsAnError() async {
        let client = MiniMaxSpeechClient(apiKey: "k", voiceID: "v", session: StubHTTP.session(status: 200, body: "\n"))
        await #expect(throws: MiniMaxSpeechError.noAudio) { try await client.speak("你好") { _ in } }
    }

    @Test func brokenHexIsNotPlayed() {
        #expect(MiniMaxSpeechClient.bytes(fromHex: "0g") == nil)
        #expect(MiniMaxSpeechClient.bytes(fromHex: "abc") == nil)
        #expect(MiniMaxSpeechClient.bytes(fromHex: "0aFF") == Data([10, 255]))
    }

    // MARK: Her reply

    @Test func sheAnswersAsTheSamePersonWithWhatIsInCtrlK() async throws {
        let prompts = Prompts()
        let conversation = StableVoiceConversation(
            complete: { messages in await prompts.add(messages); return #"{"say":"还没合，在等你决定。"}"# },
            identity: { "你的名字是「小满」。" })
        let reply = try await conversation.reply(to: "那个改动合了没有", companionContext: "等用户决定的改动（os）：改了 2 个文件")
        #expect(reply == StableVoiceReply(say: "还没合，在等你决定。"))
        let sent = await prompts.all.last ?? []
        let everything = sent.map(\.content).joined(separator: "\n")
        #expect(everything.contains("你的名字是「小满」。"))
        #expect(everything.contains("等用户决定的改动（os）：改了 2 个文件"))
        #expect(sent.last == StableVoiceMessage(role: .user, content: "那个改动合了没有"))
    }

    @Test func sheRemembersTheConversationButOnlyTheLatestTurns() async throws {
        let prompts = Prompts()
        let conversation = StableVoiceConversation(
            complete: { messages in await prompts.add(messages); return #"{"say":"嗯。"}"# },
            identity: { "" })
        for index in 1...8 { _ = try await conversation.reply(to: "第\(index)句", companionContext: nil) }
        let last = await prompts.all.last ?? []
        let remembered = last.filter { $0.role == .user }.map(\.content)
        #expect(remembered == ["第2句", "第3句", "第4句", "第5句", "第6句", "第7句", "第8句"])
    }

    @Test func aTurnThatFailedLeavesNoHalfExchangeBehind() async throws {
        let prompts = Prompts()
        let failing = Flag()
        let conversation = StableVoiceConversation(
            complete: { messages in
                await prompts.add(messages)
                if await failing.isOn { return "我不会写 JSON" }
                return #"{"say":"好。"}"#
            },
            identity: { "" })
        await failing.set(true)
        await #expect(throws: StableVoiceConversationError.self) { _ = try await conversation.reply(to: "丢掉的那句", companionContext: nil) }
        await failing.set(false)
        _ = try await conversation.reply(to: "下一句", companionContext: nil)
        let contents = (await prompts.all.last ?? []).map(\.content)
        #expect(!contents.contains("丢掉的那句"))
    }

    @Test func namesComeBackOnlyWhenGiven() throws {
        let named = try StableVoiceConversation.parse("```json\n{\"say\":\"好，以后我叫小满。\",\"companion_name\":\"小满\",\"user_address\":\"\"}\n```")
        #expect(named == StableVoiceReply(say: "好，以后我叫小满。", companionName: "小满", userAddress: nil))
        #expect(throws: StableVoiceConversationError.self) { try StableVoiceConversation.parse(#"{"say":"  "}"#) }
    }

    // MARK: Whole turns

    @MainActor @Test func aTurnGoesFromWhatSheHeardToWhatSheSaid() async throws {
        let world = FakeWorld(transcript: "以后叫你小满", reply: StableVoiceReply(say: "好，我叫小满了。", companionName: "小满"))
        let runner = world.runner()
        runner.beginListening()
        #expect(runner.phase == .listening)
        runner.finishListening(audio: FakeWorld.speech)
        await world.waitUntilIdle(runner)
        #expect(runner.heard == "以后叫你小满")
        #expect(runner.said == "好，我叫小满了。")
        #expect(runner.failure == nil)
        #expect(world.events == ["saved 小满", "audio 4"])
        let timing = try #require(world.timings.last)
        #expect(timing.outcome == "spoken")
        #expect(timing.transcribedAfter != nil && timing.repliedAfter != nil && timing.firstAudioAfter != nil)
    }

    @MainActor @Test func aTapIsNotSentAsSpeech() async {
        let world = FakeWorld(transcript: "不该听到", reply: StableVoiceReply(say: "不该说"))
        let runner = world.runner()
        runner.beginListening()
        runner.finishListening(audio: Data(count: 100))
        #expect(runner.phase == .idle)
        #expect(runner.failure == "太短了：按住 ⌃⌥ 说完再松手。")
        #expect(runner.said == nil)
    }

    @MainActor @Test func holdingTheShortcutWhileSheSpeaksStopsHer() async throws {
        let world = FakeWorld(transcript: "讲个长故事", reply: StableVoiceReply(say: "很久很久以前……"), holdSpeech: true)
        let runner = world.runner()
        runner.beginListening()
        runner.finishListening(audio: FakeWorld.speech)
        while runner.phase != .speaking || world.events.isEmpty { await Task.yield() }
        runner.beginListening()
        #expect(runner.phase == .listening)
        #expect(world.queued.isEmpty)
        world.releaseSpeech()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(world.queued.isEmpty, "audio that arrives after the interruption is not played")
        #expect(world.timings.last?.outcome == "interrupted")
    }

    @MainActor @Test func thePreviewSpeaksWithoutListening() async {
        let world = FakeWorld(transcript: "不该用到", reply: StableVoiceReply(say: "不该说"))
        let runner = world.runner()
        runner.say("这是现在的语速")
        #expect(runner.phase == .speaking)
        await world.waitUntilIdle(runner)
        #expect(world.events == ["audio 4"])
        #expect(runner.heard == nil)
        #expect(world.timings.last?.outcome == "previewed")
    }

    @MainActor @Test func pressingTheShortcutStopsThePreview() async throws {
        let world = FakeWorld(transcript: "", reply: StableVoiceReply(say: ""), holdSpeech: true)
        let runner = world.runner()
        runner.say("这是现在的语速")
        while world.events.isEmpty { await Task.yield() }
        runner.beginListening()
        world.releaseSpeech()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(runner.phase == .listening)
        #expect(world.queued.isEmpty)
    }

    @MainActor @Test func nothingHeardIsSaidPlainly() async {
        let world = FakeWorld(transcript: "", reply: StableVoiceReply(say: "不该说"))
        let runner = world.runner()
        runner.beginListening()
        runner.finishListening(audio: FakeWorld.speech)
        await world.waitUntilIdle(runner)
        #expect(runner.failure == "没听清，再说一次。")
        #expect(runner.said == nil)
    }

    @MainActor @Test func aFailedServiceIsShownAndSheSaysNothing() async {
        let world = FakeWorld(transcript: "你好", reply: StableVoiceReply(say: "不该说"),
                              speechError: MiniMaxSpeechError.provider(code: 1004, message: "authorized failed"))
        let runner = world.runner()
        runner.beginListening()
        runner.finishListening(audio: FakeWorld.speech)
        await world.waitUntilIdle(runner)
        #expect(runner.failure == "MiniMax 没能念出来：authorized failed（1004）")
        #expect(world.queued.isEmpty)
        #expect(world.timings.last?.outcome == "failed")
    }
}

private actor Heard {
    var bytes: [UInt8] = []
    func add(_ data: Data) { bytes += data }
}

private actor Prompts {
    var all: [[StableVoiceMessage]] = []
    func add(_ messages: [StableVoiceMessage]) { all.append(messages) }
}

private actor Flag {
    var isOn = false
    func set(_ value: Bool) { isOn = value }
}

/// A microphone-free world: canned services, a speaker that plays instantly,
/// and a record of what the user would see and hear.
@MainActor
private final class FakeWorld {
    static let speech = Data(count: StableVoiceTurnRunner.minimumUtteranceBytes * 2)

    var events: [String] = []
    var queued: [Data] = []
    var timings: [StableVoiceTiming] = []
    private let transcript: String
    private let reply: StableVoiceReply
    private let holdSpeech: Bool
    private let speechError: Error?
    private var speechGate: CheckedContinuation<Void, Never>?

    init(transcript: String, reply: StableVoiceReply, holdSpeech: Bool = false, speechError: Error? = nil) {
        self.transcript = transcript
        self.reply = reply
        self.holdSpeech = holdSpeech
        self.speechError = speechError
    }

    func runner() -> StableVoiceTurnRunner {
        let transcript = self.transcript, reply = self.reply, holdSpeech = self.holdSpeech, speechError = self.speechError
        let runner = StableVoiceTurnRunner(
            services: .init(
                transcribe: { _ in transcript },
                reply: { _, _ in reply },
                speak: { [weak self] _, onAudio in
                    if let speechError { throw speechError }
                    await onAudio(Data([1, 2, 3, 4]))
                    if holdSpeech {
                        await self?.waitForRelease()
                        await onAudio(Data([5, 6]))
                    }
                }),
            playback: .init(
                enqueue: { [weak self] chunk in self?.queued.append(chunk); self?.events.append("audio \(chunk.count)") },
                clear: { [weak self] in self?.queued.removeAll() },
                isPlaying: { false }))
        runner.onNames = { [weak self] name, _ in if let name { self?.events.append("saved \(name)") } }
        runner.onTurnFinished = { [weak self] in self?.timings.append($0) }
        return runner
    }

    func waitForRelease() async {
        await withCheckedContinuation { speechGate = $0 }
    }

    func releaseSpeech() {
        speechGate?.resume()
        speechGate = nil
    }

    func waitUntilIdle(_ runner: StableVoiceTurnRunner) async {
        for _ in 0..<500 where runner.phase != .idle { try? await Task.sleep(nanoseconds: 2_000_000) }
    }
}
