#if DEBUG
import Foundation

/// Multi-turn voice-consistency probe: several synthetic user turns inside ONE
/// realtime session, each reply's audio saved separately so speaker drift
/// between responses can be measured (scripts/acceptance/voice_consistency_report.py)
/// instead of argued about by ear.
///
/// Same model and persona instructions as production, no tools: the
/// 2026-09-23 13:36 drift happened on two plain conversational turns, so tool
/// turns are deliberately out of the picture. No microphone, no speaker, no desktop.
///
///   Her --voice-consistency-probe <voice> <output-dir> <turn1.pcm> <turn2.pcm> ...
@MainActor
final class VoiceConsistencyProbe {
    private var currentTurnAudio = Data()
    /// [milliseconds since the turn was committed, chunk bytes] for every audio
    /// chunk, so playback continuity can be judged from arrival timing alone.
    private var currentTurnChunkArrivals: [[Int]] = []
    private var currentTurnCommittedAt = Date()
    private var currentTurnTranscript = ""
    private var isCurrentTurnComplete = false
    private var failure: String?
    private var voiceMatchesRequest: Bool?

    func run(voice: String, outputDirectory: URL, turnAudioURLs: [URL]) async throws {
        guard let key = KeychainStore.stepfunAPIKey, !key.isEmpty else {
            throw NSError(domain: "VoiceConsistencyProbe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "StepFun Keychain key unavailable"])
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        // `-probePersonaFile <path>` swaps only the persona block, so persona
        // wording can be compared on the same inputs without rebuilding.
        let personaInstructions = UserDefaults.standard.string(forKey: "probePersonaFile")
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            ?? CompanionManager.companionPersonaInstructions(companionName: TipTourDefaults.companionName)
        // `-probeInstructionsFile <path>` replaces persona AND tool contract,
        // for comparing how the whole instruction text shapes delivery.
        let sessionInstructions = UserDefaults.standard.string(forKey: "probeInstructionsFile")
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            ?? personaInstructions + CompanionManager.stepfunVoiceInstructions
        let client = StepFunRealtimeClient(
            apiKey: key, model: TipTourDefaults.StepFunConfiguration.realtimeModel, voice: voice,
            instructions: sessionInstructions,
            tools: [], turnDetection: .manual
        ) { [weak self] event in self?.receive(event) }
        defer { client.disconnect() }
        try await client.connect()

        var turnRecords: [[String: Any]] = []
        for (turnIndex, turnAudioURL) in turnAudioURLs.enumerated() {
            currentTurnAudio = Data()
            currentTurnChunkArrivals = []
            currentTurnTranscript = ""
            isCurrentTurnComplete = false
            let input = try Data(contentsOf: turnAudioURL)
            for offset in stride(from: 0, to: input.count, by: 960) {
                client.sendAudioChunk(input.subdata(in: offset..<min(offset + 960, input.count)))
                try await Task.sleep(for: .milliseconds(20))
            }
            currentTurnCommittedAt = Date()
            client.commitAndRequestResponse()
            let deadline = Date().addingTimeInterval(40)
            while !isCurrentTurnComplete, failure == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let turnFileName = String(format: "turn-%02d.pcm", turnIndex + 1)
            try currentTurnAudio.write(to: outputDirectory.appendingPathComponent(turnFileName))
            turnRecords.append([
                "turn": turnIndex + 1, "input": turnAudioURL.lastPathComponent,
                "completed": isCurrentTurnComplete, "audio_file": turnFileName,
                "audio_bytes": currentTurnAudio.count, "transcript": currentTurnTranscript,
                "chunk_arrivals": currentTurnChunkArrivals
            ])
            if failure != nil { break }
            // Leave the same short pause a person would before the next line.
            try await Task.sleep(for: .milliseconds(800))
        }

        let summary: [String: Any] = [
            "route": "realtime_client_multi_turn", "synthetic_input": true,
            "microphone": "not_opened", "speaker": "not_played", "tools": "none",
            "model": TipTourDefaults.StepFunConfiguration.realtimeModel, "voice": voice,
            "persona_source": UserDefaults.standard.string(forKey: "probePersonaFile") ?? "production",
            "instructions_source": UserDefaults.standard.string(forKey: "probeInstructionsFile") ?? "production",
            "voice_matches_request": voiceMatchesRequest.map { String($0) } ?? "not_reported",
            "error": failure ?? "", "turns": turnRecords
        ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("summary.json"))
    }

    private func receive(_ event: StepFunRealtimeEvent) {
        switch event {
        case .sessionConfigured(let matchesRequest, _): voiceMatchesRequest = matchesRequest
        case .audioChunk(let data):
            currentTurnAudio.append(data)
            currentTurnChunkArrivals.append([Int(Date().timeIntervalSince(currentTurnCommittedAt) * 1000), data.count])
        case .outputTranscript(let text): currentTurnTranscript += text
        case .outputTranscriptFinal(let text): currentTurnTranscript = text
        case .turnComplete: isCurrentTurnComplete = true
        case .error(let error), .unexpectedDisconnect(let error): failure = error.localizedDescription
        default: break
        }
    }
}

/// Server-VAD timing probe: 2 s of noise, one speech clip, then noise again,
/// all streamed in real time with production server-VAD settings. Records when
/// the server reports speech start/stop relative to the real speech, and any
/// start triggered by noise alone. The energy threshold comes from
/// `-stepfunVADEnergyThreshold <n>`, so each candidate is one run.
///
///   Her --vad-probe <output.json> <speech.pcm> <noise_dbfs> <tail_seconds>
@MainActor
final class ServerVADProbe {
    private var speechStartedOffsets: [Int] = []
    private var speechStoppedOffsets: [Int] = []
    private var streamStartedAt = Date()
    private var failure: String?

    func run(outputURL: URL, speechURL: URL, noiseDecibelsFullScale: Double, tailSeconds: Double) async throws {
        guard let key = KeychainStore.stepfunAPIKey, !key.isEmpty else {
            throw NSError(domain: "ServerVADProbe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "StepFun Keychain key unavailable"])
        }
        let leadingNoiseSeconds = 2.0
        let speech = try Data(contentsOf: speechURL)
        let speechSeconds = Double(speech.count) / 2 / StepFunRealtimeClient.audioSampleRate
        let noiseAmplitude = 32768 * pow(10, noiseDecibelsFullScale / 20) * 3.0.squareRoot()
        func noise(seconds: Double) -> Data {
            // Uniform white noise scaled to the requested RMS.
            var samples = [Int16](repeating: 0, count: Int(seconds * StepFunRealtimeClient.audioSampleRate))
            for index in samples.indices {
                samples[index] = Int16(clamping: Int((Double.random(in: -1...1) * noiseAmplitude).rounded()))
            }
            return samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        // Speech rides on the same noise floor, as it does in a real room.
        var speechOnNoise = [Int16](repeating: 0, count: speech.count / 2)
        let speechNoise = noise(seconds: speechSeconds)
        speech.withUnsafeBytes { speechBytes in
            speechNoise.withUnsafeBytes { noiseBytes in
                for index in speechOnNoise.indices {
                    let speechSample = Int(speechBytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                    let noiseSample = index * 2 + 1 < noiseBytes.count
                        ? Int(noiseBytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)) : 0
                    speechOnNoise[index] = Int16(clamping: speechSample + noiseSample)
                }
            }
        }
        let stream = noise(seconds: leadingNoiseSeconds)
            + speechOnNoise.withUnsafeBufferPointer { Data(buffer: $0) }
            + noise(seconds: tailSeconds)

        let client = StepFunRealtimeClient(
            apiKey: key, model: TipTourDefaults.StepFunConfiguration.realtimeModel,
            voice: TipTourDefaults.StepFunConfiguration.realtimeVoice,
            instructions: "你正在参加语音检测测试。每次只回答「好」。", tools: [], turnDetection: .serverVAD,
            serverVADEnergyThreshold: TipTourDefaults.StepFunConfiguration.serverVADEnergyThreshold
        ) { [weak self] event in self?.receive(event) }
        defer { client.disconnect() }
        try await client.connect()
        streamStartedAt = Date()
        let chunkBytes = 960
        var sentBytes = 0
        while sentBytes < stream.count {
            client.sendAudioChunk(stream.subdata(in: sentBytes..<min(sentBytes + chunkBytes, stream.count)))
            sentBytes += chunkBytes
            // Pace against the wall clock so the stream never runs ahead of real time.
            let targetElapsed = Double(sentBytes) / 2 / StepFunRealtimeClient.audioSampleRate
            let sleepSeconds = targetElapsed - Date().timeIntervalSince(streamStartedAt)
            if sleepSeconds > 0 { try await Task.sleep(for: .seconds(sleepSeconds)) }
        }
        try await Task.sleep(for: .seconds(2))

        let speechStartMilliseconds = Int(leadingNoiseSeconds * 1000)
        let speechEndMilliseconds = Int((leadingNoiseSeconds + speechSeconds) * 1000)
        let firstStopNearSpeechEnd = speechStoppedOffsets.first { $0 >= speechEndMilliseconds - 500 }
        let result: [String: Any] = [
            "vad_energy_threshold": TipTourDefaults.StepFunConfiguration.serverVADEnergyThreshold,
            "noise_dbfs": noiseDecibelsFullScale, "speech_seconds": speechSeconds, "tail_seconds": tailSeconds,
            "speech_start_ms": speechStartMilliseconds, "speech_end_ms": speechEndMilliseconds,
            "server_speech_started_ms": speechStartedOffsets, "server_speech_stopped_ms": speechStoppedOffsets,
            "starts_before_speech": speechStartedOffsets.filter { $0 < speechStartMilliseconds - 200 }.count,
            // -1: the server never reported the end of this speech.
            "first_stop_after_speech_end_ms": firstStopNearSpeechEnd.map { $0 - speechEndMilliseconds } ?? -1,
            "error": failure ?? ""
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL)
    }

    private func receive(_ event: StepFunRealtimeEvent) {
        let offsetMilliseconds = Int(Date().timeIntervalSince(streamStartedAt) * 1000)
        switch event {
        case .userStartedSpeaking: speechStartedOffsets.append(offsetMilliseconds)
        case .userStoppedSpeaking: speechStoppedOffsets.append(offsetMilliseconds)
        case .error(let error), .unexpectedDisconnect(let error): failure = error.localizedDescription
        default: break
        }
    }
}
#endif
