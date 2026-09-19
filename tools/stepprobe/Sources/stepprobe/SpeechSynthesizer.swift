//
//  SpeechSynthesizer.swift
//  stepprobe
//
//  Produces real speech as 24 kHz mono PCM16 without touching the microphone.
//
//  Why `say`: the Realtime API's interesting behaviour — server VAD, barge-in,
//  function calling triggered by speech — only appears with actual speech, and
//  requesting microphone access would drag the probe into TCC territory for no
//  reason. `say` renders locally, so the probe stays a pure network client.
//

import Foundation

struct SynthesizedSpeech {
    /// Raw signed 16-bit little-endian, mono, at `sampleRate`.
    let pcm16Data: Data
    let sampleRate: Double
    let durationSeconds: Double
}

struct SpeechSynthesizer {
    /// The StepFun realtime endpoint's documented sample rate. Not stated in the
    /// prose documentation — it comes from the official demo's `sampleRate = 24000`.
    static let realtimeSampleRate: Double = 24_000

    private let temporaryDirectory: URL

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    func synthesize(_ text: String, voice: String? = nil, trailingSilenceMilliseconds: Int = 800) throws -> SynthesizedSpeech {
        let aiffURL = temporaryDirectory.appendingPathComponent("stepprobe-speech.aiff")
        let rawURL = temporaryDirectory.appendingPathComponent("stepprobe-speech.raw")
        try? FileManager.default.removeItem(at: aiffURL)
        try? FileManager.default.removeItem(at: rawURL)

        var sayArguments = ["-o", aiffURL.path]
        if let voice { sayArguments += ["-v", voice] }
        sayArguments.append(text)
        try run(launchPath: "/usr/bin/say", arguments: sayArguments)

        // 24 kHz, mono, signed 16-bit little-endian, no container.
        try run(
            launchPath: "/usr/bin/afconvert",
            arguments: [
                "-f", "WAVE", "--data", "LEI16@24000", "-d", "LEI16",
                "-c", "1", "-r", "24000",
                aiffURL.path, rawURL.path,
            ]
        )

        let pcm16Data = try Data(contentsOf: rawURL)
        // Server VAD decides a turn is over by watching for sustained silence.
        // Locally rendered speech ends abruptly, which leaves the server waiting
        // for an end that never comes — no `speech_stopped`, no commit, no
        // response. Append silence so the turn can close.
        let silenceFrames = Int(Self.realtimeSampleRate * Double(trailingSilenceMilliseconds) / 1000)
        let silenceData = Data(count: silenceFrames * 2)
        let pcm16WithSilence = pcm16Data + silenceData

        let frameCount = Double(pcm16WithSilence.count) / 2
        return SynthesizedSpeech(
            pcm16Data: pcm16WithSilence,
            sampleRate: Self.realtimeSampleRate,
            durationSeconds: frameCount / Self.realtimeSampleRate
        )
    }

    /// Splits into ~20 ms chunks. The StepFun guidance is explicit: append in
    /// small, frequent pieces, or server VAD lags behind real time.
    func chunkForStreaming(_ pcm16Data: Data, chunkMilliseconds: Int = 20) -> [Data] {
        let bytesPerFrame = 2
        let framesPerChunk = Int(Self.realtimeSampleRate * Double(chunkMilliseconds) / 1000)
        let bytesPerChunk = max(bytesPerFrame, framesPerChunk * bytesPerFrame)
        var chunks: [Data] = []
        var offset = 0
        while offset < pcm16Data.count {
            let end = min(offset + bytesPerChunk, pcm16Data.count)
            chunks.append(pcm16Data.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }

    private func run(launchPath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ProbeError.malformedResponse("\(launchPath) failed (\(process.terminationStatus)): \(message)")
        }
    }
}
