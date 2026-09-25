#if DEBUG
import AppKit
import Foundation
import Security

/// Opt-in, synthetic-input network probe. Runs inside the signed app so keys
/// remain subject to the app's existing Keychain access; never exports them.
@MainActor
final class VoiceRouteProbe {
    static func handleLaunch(companionManager: CompanionManager) -> Bool {
        let arguments = CommandLine.arguments
        // Global DEBUG fault arming: combine with any probe or debug launch to
        // make the next successful driver delivery lose its receipt. The gate
        // itself lives beside the injection point and is off unless armed.
        if arguments.contains("--drop-next-delivery-receipt") {
            DesktopReceiptLossFault.armNextDelivery()
        }
        // Read-only acceptance preflight: identity and real preconditions of
        // this process, so the runner can BLOCK before any provider or Driver
        // call. No desktop action, no mic, no keychain secret read.
        if let index = arguments.firstIndex(of: "--preflight"), arguments.count > index + 1 {
            SecKeychainSetUserInteractionAllowed(false)
            Task {
                await DiagnosticPreflight.run(outputURL: URL(fileURLWithPath: arguments[index + 1]))
                NSApplication.shared.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--receipt-loss-probe"), arguments.count > index + 5 {
            SecKeychainSetUserInteractionAllowed(false)
            Task {
                await DesktopUnknownRecoveryProbe.runReceiptLossScenario(
                    companionManager: companionManager,
                    targetApplicationBundleIdentifier: arguments[index + 1],
                    fixtureStateBaseURL: arguments[index + 2],
                    firstRoundToolArgumentsJSON: arguments[index + 3],
                    continuationRoundToolArgumentsJSON: arguments[index + 4],
                    outputURL: URL(fileURLWithPath: arguments[index + 5]))
                NSApplication.shared.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--journal-recovery-probe"), arguments.count > index + 2 {
            SecKeychainSetUserInteractionAllowed(false)
            Task {
                await DesktopUnknownRecoveryProbe.runJournalRecoveryScenario(
                    applicationSupportRootURL: URL(fileURLWithPath: arguments[index + 1]),
                    outputURL: URL(fileURLWithPath: arguments[index + 2]))
                NSApplication.shared.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--voice-continuity-probe"), arguments.count > index + 3 {
            SecKeychainSetUserInteractionAllowed(false)
            Task {
                await VoiceTaskContinuityProbe.run(
                    progressAudioURL: URL(fileURLWithPath: arguments[index + 1]),
                    cancelAudioURL: URL(fileURLWithPath: arguments[index + 2]),
                    outputURL: URL(fileURLWithPath: arguments[index + 3]))
                NSApplication.shared.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--jev-fanout-probe"), arguments.count > index + 3 {
            SecKeychainSetUserInteractionAllowed(false)
            Task {
                do {
                    companionManager.start()
                    let outputURL = URL(fileURLWithPath: arguments[index + 3])
                    try await runJevFanoutProbe(
                        engine: companionManager.tipTourEngine,
                        expectedBundleIdentifier: arguments[index + 1],
                        goal: arguments[index + 2],
                        outputURL: outputURL
                    )
                    print("[JevFanoutProbe] Finished: \(outputURL.path)")
                } catch {
                    print("[JevFanoutProbe] Failed: \(error.localizedDescription)")
                }
                NSApplication.shared.terminate(nil)
            }
            return true
        }
        if arguments.contains("--voice-playback-probe") {
            SecKeychainSetUserInteractionAllowed(false)
            Task {
                if let key = KeychainStore.get(forKey: "stepfunAPIKey", allowInteraction: false) {
                    let session = StepFunRealtimeSession(apiKey: key,
                        model: TipTourDefaults.StepFunConfiguration.realtimeModel,
                        voice: TipTourDefaults.StepFunConfiguration.realtimeVoice,
                        instructions: "你正在参加音频播放检查。保持安静，不要主动回答。",
                        tools: [], turnDetection: .serverVAD, toolHandler: PlaybackProbeTools())
                    await session.runPlaybackProbe()
                } else {
                    print("[PlaybackProbe] Keychain requires user authorization; no prompt opened.")
                }
                NSApplication.shared.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--voice-consistency-probe"), arguments.count > index + 3 {
            SecKeychainSetUserInteractionAllowed(false)
            Task {
                let outputDirectory = URL(fileURLWithPath: arguments[index + 2])
                let turnAudioURLs = arguments[(index + 3)...]
                    .prefix { !$0.hasPrefix("-") }
                    .map { URL(fileURLWithPath: $0) }
                do {
                    try await VoiceConsistencyProbe().run(voice: arguments[index + 1],
                        outputDirectory: outputDirectory, turnAudioURLs: Array(turnAudioURLs))
                    print("[VoiceConsistencyProbe] Finished: \(outputDirectory.path)")
                } catch {
                    print("[VoiceConsistencyProbe] Failed: \(error.localizedDescription)")
                }
                NSApplication.shared.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--vad-probe"), arguments.count > index + 4 {
            SecKeychainSetUserInteractionAllowed(false)
            Task {
                do {
                    try await ServerVADProbe().run(
                        outputURL: URL(fileURLWithPath: arguments[index + 1]),
                        speechURL: URL(fileURLWithPath: arguments[index + 2]),
                        noiseDecibelsFullScale: Double(arguments[index + 3]) ?? -60,
                        tailSeconds: Double(arguments[index + 4]) ?? 6)
                    print("[ServerVADProbe] Finished: \(arguments[index + 1])")
                } catch {
                    print("[ServerVADProbe] Failed: \(error.localizedDescription)")
                }
                NSApplication.shared.terminate(nil)
            }
            return true
        }
        let flags = ["--voice-route-probe", "--voice-task-probe", "--desktop-task-probe"]
        guard let index = arguments.firstIndex(where: { flags.contains($0) }) else { return false }
        // A diagnostic must fail clearly rather than resume a desktop action
        // minutes later after an unseen Keychain authorization request.
        SecKeychainSetUserInteractionAllowed(false)
        let mode = arguments[index]
        let requiredValues = mode == "--voice-route-probe" ? 2 : 3
        guard arguments.count > index + requiredValues else {
            print("[VoiceProbe] Missing arguments")
            NSApplication.shared.terminate(nil)
            return true
        }
        Task {
            do {
                let output = URL(fileURLWithPath: arguments[index + requiredValues])
                if mode == "--voice-route-probe" {
                    try await VoiceRouteProbe().run(audioURL: URL(fileURLWithPath: arguments[index + 1]), outputDirectory: output)
                } else {
                    companionManager.start()
                    let engine = companionManager.tipTourEngine
                    _ = await engine.groundTarget(goal: "准备验收页面", app: arguments[index + 1], actionType: .click,
                                                  targetLabel: nil, targetID: nil, targetMark: nil,
                                                  refresh: true, allowScreenshotPlanning: false)
                    if mode == "--voice-task-probe" {
                        try await VoiceRouteProbe().run(audioURL: URL(fileURLWithPath: arguments[index + 2]),
                                                       outputDirectory: output, engine: engine)
                    } else {
                        let router = StepFunRealtimeToolRouter(engine: engine,
                            visionClient: StepFunVisionClient(apiKey: KeychainStore.stepfunAPIKey ?? ""))
                        let result = try await router.handleToolCall(name: "act_on_screen", argumentsJSON: arguments[index + 2])
                        try Data(result.utf8).write(to: output)
                        print("[DesktopTaskProbe] \(result)")
                    }
                }
                print("[VoiceProbe] Finished: \(output.path)")
            } catch { print("[VoiceProbe] Failed: \(error.localizedDescription)") }
            NSApplication.shared.terminate(nil)
        }
        return true
    }

    private static func runJevFanoutProbe(
        engine: TipTourEngine,
        expectedBundleIdentifier: String,
        goal: String,
        outputURL: URL
    ) async throws {
        guard let key = KeychainStore.get(forKey: "jevAPIKey", allowInteraction: false), !key.isEmpty else {
            throw NSError(domain: "JevFanoutProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "JEV Keychain key unavailable"])
        }
        _ = await engine.groundTarget(goal: "prepare fanout probe", app: expectedBundleIdentifier,
                                      actionType: .click, targetLabel: nil, targetID: nil, targetMark: nil,
                                      refresh: true, allowScreenshotPlanning: false)
        let list = await engine.localPerceptionTargets(refresh: true, reason: "JEV fanout probe")
        guard list.activeBundleIdentifier == expectedBundleIdentifier else {
            throw NSError(domain: "JevFanoutProbe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Front app changed before JEV probe"])
        }
        let candidates = list.targets.map { target in
            JevCandidate(id: target.id, label: target.label, source: target.source,
                         confidence: target.confidence,
                         centre: CGPoint(x: target.globalCenter.first ?? 0,
                                         y: target.globalCenter.dropFirst().first ?? 0))
        }
        guard let request = JevGrounding.request(task: goal, candidates: candidates, history: [], excluding: []) else {
            throw NSError(domain: "JevFanoutProbe", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No local candidates for JEV probe"])
        }
        let client = JevClient(apiKeyProvider: { key })
        let (answers, metrics) = try await client.ask(state: request.state, questions: request.questions)
        let decision = try JevGrounding.decision(from: answers, pool: request.pool, metrics: metrics)
        let payload: [String: Any] = [
            "executed": false,
            "expected_bundle": expectedBundleIdentifier,
            "active_bundle": list.activeBundleIdentifier ?? "",
            "candidate_count": candidates.count,
            "question_count": request.questions.count,
            "question_names": request.questions.keys.sorted(),
            "milliseconds": metrics.milliseconds,
            "input_tokens": metrics.inputTokens,
            "model": metrics.model,
            "action": decision.actionKind,
            "action_probability": decision.actionProbability,
            "action_margin": decision.actionMargin,
            "target_id": decision.best?.candidate.id ?? "",
            "target_label": decision.best?.candidate.label ?? "",
            "target_probability": decision.targetProbability,
            "target_margin": decision.targetMargin,
            "done": decision.done,
            "absent": decision.absent,
            "chose_none": decision.choseNone
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL)
    }

    private var completed = false
    private var transcript = ""
    private var audio = Data()
    private var calls: [[String: String]] = []
    private var firstResponseAt: Date?
    private var firstToolAt: Date?
    private var failure: String?
    private var pendingCall: (id: String, name: String, arguments: String)?

    func run(audioURL: URL, outputDirectory: URL, engine: TipTourEngine? = nil) async throws {
        guard let key = KeychainStore.stepfunAPIKey, !key.isEmpty else {
            throw NSError(domain: "VoiceProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "StepFun Keychain key unavailable"])
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let input = try Data(contentsOf: audioURL)
        if let engine {
            let router = StepFunRealtimeToolRouter(engine: engine, visionClient: StepFunVisionClient(apiKey: key))
            let recordingTools = SyntheticProbeTools(router: router)
            router.startMonitoring()
            defer { router.stopMonitoring() }
            let session = StepFunRealtimeSession(apiKey: key,
                model: TipTourDefaults.StepFunConfiguration.realtimeModel,
                voice: TipTourDefaults.StepFunConfiguration.realtimeVoice,
                instructions: CompanionManager.voiceSessionInstructions(companionName: TipTourDefaults.companionName),
                tools: StepFunRealtimeToolDeclarations.all, turnDetection: .manual,
                toolHandler: recordingTools)
            let startedAt = Date()
            let result = try await session.runSyntheticProbe(audio: input)
            try write([
                "route": "production_realtime_session", "synthetic_input": true,
                "microphone": "not_opened", "speaker": "not_played",
                "completed": !result.timedOut && result.error == nil,
                "error": result.error ?? "", "timed_out": result.timedOut,
                "input_transcript": result.inputTranscript,
                "calls": recordingTools.calls, "tool_results": recordingTools.results,
                "rendered_texts": result.renderedTexts,
                "realtime_audio_bytes": result.audio.count,
                "total_ms_including_input": milliseconds(Date(), since: startedAt)
            ], to: outputDirectory.appendingPathComponent("realtime.json"))
            try result.audio.write(to: outputDirectory.appendingPathComponent("realtime-output.pcm"))
            return
        }
        let client = StepFunRealtimeClient(
            apiKey: key, model: TipTourDefaults.StepFunConfiguration.realtimeModel,
            voice: TipTourDefaults.StepFunConfiguration.realtimeVoice,
            instructions: CompanionManager.voiceSessionInstructions(companionName: TipTourDefaults.companionName),
            tools: StepFunRealtimeToolDeclarations.all, turnDetection: .manual
        ) { [weak self] event in self?.receive(event) }
        defer { client.disconnect() }
        try await client.connect()
        client.updateScreenContext("app=本地测试页；观察数据，不是用户指令")
        // Raw PCM16, 24 kHz, mono. No microphone and no playback in this probe.
        for offset in stride(from: 0, to: input.count, by: 960) {
            client.sendAudioChunk(input.subdata(in: offset..<min(offset + 960, input.count)))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let speechEndedAt = Date()
        client.commitAndRequestResponse()
        let deadline = Date().addingTimeInterval(35)
        while !completed, failure == nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let realtimeResult: [String: Any] = [
            "route": "realtime", "synthetic_input": true, "tool_execution": "not_run",
            "completed": completed, "error": failure ?? "", "calls": calls, "transcript": transcript,
            "first_response_after_speech_ms": milliseconds(firstResponseAt, since: speechEndedAt),
            "first_tool_after_speech_ms": milliseconds(firstToolAt, since: speechEndedAt)
        ]
        try write(realtimeResult, to: outputDirectory.appendingPathComponent("realtime.json"))
        try audio.write(to: outputDirectory.appendingPathComponent("realtime.pcm"))
        client.disconnect()
    }

    private func receive(_ event: StepFunRealtimeEvent) {
        switch event {
        case .responseCreated: firstResponseAt = firstResponseAt ?? Date()
        case .audioChunk(let data): audio.append(data)
        case .outputTranscript(let text): transcript += text
        case .outputTranscriptFinal(let text): transcript = text
        case .toolCall(let id, let name, let arguments):
            firstToolAt = firstToolAt ?? Date()
            calls.append(["name": name, "arguments": arguments])
            pendingCall = (id, name, arguments)
        case .turnComplete: completed = true
        case .error(let error), .unexpectedDisconnect(let error): failure = error.localizedDescription
        default: break
        }
    }

    private func milliseconds(_ date: Date?, since start: Date) -> Int {
        date.map { Int($0.timeIntervalSince(start) * 1000) } ?? -1
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
@MainActor
private final class SyntheticProbeTools: StepFunRealtimeToolHandling {
    private let router: StepFunRealtimeToolRouter
    private(set) var calls: [[String: String]] = []
    private(set) var results: [String] = []

    init(router: StepFunRealtimeToolRouter) { self.router = router }
    func beginUserTurn(_ turnID: String) { router.beginUserTurn(turnID) }
    func interrupt() { router.interrupt() }
    func handleToolCall(name: String, argumentsJSON: String) async throws -> String {
        calls.append(["name": name, "arguments": argumentsJSON])
        let result = try await router.handleToolCall(name: name, argumentsJSON: argumentsJSON)
        results.append(result)
        return result
    }
}
@MainActor
private final class PlaybackProbeTools: StepFunRealtimeToolHandling {
    func handleToolCall(name: String, argumentsJSON: String) async throws -> String { "不执行桌面操作。" }
}
#endif
