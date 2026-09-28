#if DEBUG
import Foundation

/// Multi-turn probe for the 「声音稳定」 voice style: the same synthetic turns
/// the realtime consistency probe takes (24 kHz PCM16), each run through the
/// production turn logic and real services as if the user had let go of ⌃⌥ at
/// the end of the clip. Output has the realtime probe's shape, so
/// scripts/acceptance/voice_consistency_report.py measures both the same way.
/// No microphone, no speaker; names she is given are recorded, not saved.
///
///   Her --stable-voice-probe <output-dir> <turn1.pcm> <turn2.pcm> ...
@MainActor
enum StableVoiceProbe {
    static func run(companionManager: CompanionManager, outputDirectory: URL, turnAudioURLs: [URL]) async throws {
        guard let stepfunKey = KeychainStore.stepfunAPIKey, !stepfunKey.isEmpty else {
            throw NSError(domain: "StableVoiceProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "StepFun Keychain key unavailable"])
        }
        guard let miniMaxKey = KeychainStore.get(forKey: TipTourDefaults.MiniMaxConfiguration.keyName), !miniMaxKey.isEmpty else {
            throw NSError(domain: "StableVoiceProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "MiniMax Keychain key unavailable"])
        }
        let voiceID = TipTourDefaults.MiniMaxConfiguration.voiceID
        guard !voiceID.isEmpty else {
            throw NSError(domain: "StableVoiceProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "MiniMax voice ID not set"])
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var audio = Data()
        var arrivals: [[Int]] = []
        var released = Date()
        let runner = StableVoiceTurnRunner(
            services: CompanionManager.stableVoiceServices(stepfunAPIKey: stepfunKey, miniMaxAPIKey: miniMaxKey,
                                                           voiceID: voiceID, personaStore: companionManager.personaStore),
            playback: .init(
                enqueue: { chunk in
                    audio.append(chunk)
                    arrivals.append([Int(Date().timeIntervalSince(released) * 1000), chunk.count])
                },
                clear: {},
                isPlaying: { false }))
        var names: [String] = []
        runner.onNames = { name, address in
            if let name { names.append("companion_name=\(name)") }
            if let address { names.append("user_address=\(address)") }
        }
        var timing = StableVoiceTiming()
        runner.onTurnFinished = { timing = $0 }
        runner.companionContext = { companionManager.delegationSession?.voiceContext }

        var turnRecords: [[String: Any]] = []
        var failure = ""
        for (turnIndex, turnAudioURL) in turnAudioURLs.enumerated() {
            audio = Data()
            arrivals = []
            names = []
            timing = StableVoiceTiming()
            let input = try Data(contentsOf: turnAudioURL)
            // Hold for as long as the clip lasts, as a person speaking would,
            // so connections open while "talking" exactly as in real use.
            runner.beginListening()
            try await Task.sleep(for: .milliseconds(input.count * 1000 / 48_000))
            released = Date()
            runner.finishListening(audio: resampled24kTo16k(input))
            let deadline = Date().addingTimeInterval(60)
            while runner.phase != .idle, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let turnFileName = String(format: "turn-%02d.pcm", turnIndex + 1)
            try audio.write(to: outputDirectory.appendingPathComponent(turnFileName))
            turnRecords.append([
                "turn": turnIndex + 1, "input": turnAudioURL.lastPathComponent,
                "completed": timing.outcome == "spoken", "audio_file": turnFileName, "audio_bytes": audio.count,
                "heard": runner.heard ?? "", "transcript": runner.said ?? "", "names": names,
                "chunk_arrivals": arrivals, "timing": timing.fields, "failure": runner.failure ?? "",
            ])
            if let turnFailure = runner.failure { failure = turnFailure; break }
            try await Task.sleep(for: .milliseconds(800))
        }
        let summary: [String: Any] = [
            "route": "stable_voice_multi_turn", "synthetic_input": true,
            "microphone": "not_opened", "speaker": "not_played",
            "model": "\(StepAudioTranscriber.model) + \(DelegationModelClient.defaultModel) + \(TipTourDefaults.MiniMaxConfiguration.speechModel)",
            "voice": voiceID, "voice_matches_request": "not_reported", "error": failure, "turns": turnRecords,
        ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("summary.json"))
    }

    /// 24 kHz → 16 kHz PCM16 by linear interpolation: plenty for speech-to-text.
    static func resampled24kTo16k(_ input: Data) -> Data {
        let samples: [Int16] = input.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        guard samples.count > 1 else { return Data() }
        let outputCount = samples.count * 2 / 3
        var output = Data(capacity: outputCount * 2)
        for index in 0..<outputCount {
            let position = Double(index) * 1.5
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = position - Double(lower)
            let value = Double(samples[lower]) * (1 - fraction) + Double(samples[upper]) * fraction
            var sample = Int16(max(-32768, min(32767, value.rounded()))).littleEndian
            withUnsafeBytes(of: &sample) { output.append(contentsOf: $0) }
        }
        return output
    }
}
#endif
