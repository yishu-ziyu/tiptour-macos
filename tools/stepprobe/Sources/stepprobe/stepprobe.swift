//
//  stepprobe.swift
//  stepprobe
//
//  Investigation harness for the providers TipTour will use after the Gemini
//  path is removed. It answers questions with measurements instead of opinions:
//  which models the account can reach, whether their coordinates can be
//  trusted, and how Jev's confidence behaves on Chinese candidate lists.
//
//  Usage:
//    swift run stepprobe models [--image PATH]
//    swift run stepprobe vision --image PATH [--model M] [--effort low|medium|high]
//                              [--no-json] [--max-tokens N] [--prompt TEXT]
//                              [--truth name=x1,y1,x2,y2 ...]
//    swift run stepprobe jev    [--lang en|zh] [--candidates N] [--model M]
//

import Foundation

@main
struct StepProbe {
    static func main() async {
        EnvLoader.loadDotEnv()
        let arguments = Array(CommandLine.arguments.dropFirst())

        guard let command = arguments.first else {
            print(ProbeError.usage("""
              stepprobe — model investigation harness

              commands:
                models   probe which Step Plan models the account can reach,
                         optionally with an image attached
                vision   measure coordinate accuracy and latency for a screenshot
                jev      measure Jev latency, cost and confidence on English vs
                         Chinese candidate lists

              credentials are read from the repository root .env (see .env.example)
              """).errorDescription ?? "")
            return
        }

        let options = OptionParser.parse(Array(arguments.dropFirst()))

        do {
            switch command {
            case "models":
                try await runModelsInventory(options: options)
            case "vision":
                try await runVisionProbe(options: options)
            case "jev":
                try await runJevProbe(options: options)
            default:
                throw ProbeError.usage("Unknown command `\(command)`. Run `swift run stepprobe` for help.")
            }
        } catch let error as ProbeError {
            FileHandle.standardError.write("✗ \(error.errorDescription ?? "unknown error")\n".data(using: .utf8)!)
            Foundation.exit(1)
        } catch {
            FileHandle.standardError.write("✗ \(error.localizedDescription)\n".data(using: .utf8)!)
            Foundation.exit(1)
        }
    }

    // MARK: models

    private static func runModelsInventory(options: [String: [String]]) async throws {
        let apiKey = try EnvLoader.require("STEPFUN_API_KEY")
        let inventory = StepFunModelInventory(apiKey: apiKey)

        // Includes models that are documented but unavailable to this account,
        // and one that is available but undocumented, so the output shows both
        // directions of documentation drift.
        let candidates = [
            "step-3.7-flash",
            "step-5-preview",
            "step-3.5-flash",
            "step-3.5-flash-2603",
            "step-router-v1",
            "step-3.5-preview",
        ]

        print("== Step Plan model reachability ==")
        for result in await inventory.probeReachability(ofModels: candidates) {
            let status = result.reachable ? "✓" : "✗"
            print("  \(status) \(result.model.padding(toLength: 24, withPad: " ", startingAt: 0)) \(result.detail)")
        }

        if let imagePath = OptionParser.singleValue(options, "image") {
            print("\n== Image input support (the eye role depends on this) ==")
            for result in await inventory.probeImageSupport(ofModels: candidates, imagePath: imagePath) {
                let status = result.reachable ? "✓" : "✗"
                print("  \(status) \(result.model.padding(toLength: 24, withPad: " ", startingAt: 0)) \(result.detail)")
            }
        }
    }

    // MARK: vision

    private static func runVisionProbe(options: [String: [String]]) async throws {
        guard let imagePath = OptionParser.singleValue(options, "image") else {
            throw ProbeError.usage("vision requires --image PATH")
        }
        let apiKey = try EnvLoader.require("STEPFUN_API_KEY")

        // `--truth name=x1,y1,x2,y2`, repeatable, so several boxes can be scored
        // in a single run.
        var groundTruth: [String: [Double]] = [:]
        for specification in options["truth"] ?? [] {
            let parts = specification.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let numbers = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 4 else { continue }
            groundTruth[parts[0]] = numbers
        }

        let request = VisionProbeRequest(
            imagePath: imagePath,
            prompt: OptionParser.singleValue(options, "prompt") ?? defaultVisionPrompt(hasGroundTruth: !groundTruth.isEmpty),
            model: OptionParser.singleValue(options, "model") ?? "step-3.7-flash",
            reasoningEffort: OptionParser.singleValue(options, "effort") ?? "low",
            jsonMode: OptionParser.singleValue(options, "no-json") == nil,
            maxTokens: Int(OptionParser.singleValue(options, "max-tokens") ?? "") ?? 1500,
            groundTruth: groundTruth
        )

        let result = try await StepFunVisionProbe(apiKey: apiKey).run(request)

        print("""

          == vision probe: \(result.model) ==
            elapsed        \(result.elapsedMilliseconds) ms
            tokens         in \(result.inputTokens) / out \(result.outputTokens)
            finish_reason  \(result.finishReason)

        """)
        for (name, box) in result.parsedBoxes.sorted(by: { $0.key < $1.key }) {
            print("    box \(name): \(box.map { String(format: "%.0f", $0) }.joined(separator: ", "))")
        }
        if !result.coordinateErrors.isEmpty {
            print("\n    coordinate error against ground truth (centre distance, pixels):")
            for error in result.coordinateErrors {
                let errorText = error.errorPixels.isFinite
                    ? String(format: "%.0f px", error.errorPixels)
                    : "no answer"
                print("      \(error.name): got \(error.got.map { String(format: "%.0f", $0) }.joined(separator: ","))  truth \(error.truth.map { String(format: "%.0f", $0) }.joined(separator: ","))  → \(errorText)")
            }
        }
        print("\n    raw answer:\n\(result.answerText.indented(by: 6))")
    }

    /// Asks in the shape the product actually needs. Preferring a *number* over
    /// coordinates is deliberate: see findings §5 — pixel coordinates are not
    /// trustworthy, but picking among candidate regions is.
    private static func defaultVisionPrompt(hasGroundTruth: Bool) -> String {
        if hasGroundTruth {
            return """
              Report the pixel bounding box of each solid magenta square outlined in black, \
              using the image's own pixel coordinates, as JSON only: \
              {"boxes":{"A":[x1,y1,x2,y2],"B":[x1,y1,x2,y2],"C":[x1,y1,x2,y2]}}
              """
        }
        return """
          Describe the interactive controls visible in this screenshot as JSON only: \
          {"controls":[{"index":1,"label":"...","kind":"button|field|menu|link|other"}]}
          """
    }

    // MARK: jev

    private static func runJevProbe(options: [String: [String]]) async throws {
        let apiKey = try EnvLoader.require("TYPESAFE_API_KEY")
        let language = OptionParser.singleValue(options, "lang") ?? "zh"
        let candidateCount = Int(OptionParser.singleValue(options, "candidates") ?? "") ?? 6
        let model = OptionParser.singleValue(options, "model") ?? "jev-1.13.0"

        // The same menu rendered in English and Chinese, so a confidence gap
        // between the two runs is attributable to the language rather than the
        // content. Chinese labels mirror what a real macOS screen shows.
        let labels: [(String, String)] = language == "zh"
            ? [
                ("wenjian", "文件菜单，用于新建、打开和存储文档"),
                ("bianji", "编辑菜单，用于撤销、复制和粘贴"),
                ("xinchuang", "新建标签页按钮，打开一个新的浏览器标签页"),
                ("shoucang", "收藏按钮，把当前页面加入书签"),
                ("sousuo", "搜索输入框，输入关键词进行搜索"),
                ("shezhi", "设置按钮，打开偏好设置窗口"),
              ]
            : [
                ("file", "File menu, used to create, open and save documents"),
                ("edit", "Edit menu, used to undo, copy and paste"),
                ("newtab", "New Tab button, opens a new browser tab"),
                ("bookmark", "Bookmark button, adds the current page to favourites"),
                ("search", "Search input field, type keywords to search"),
                ("settings", "Settings button, opens the preferences window"),
            ]

        var criteria: [String: String] = [:]
        var candidates: [[String: Any]] = []
        for (identifier, description) in labels.prefix(candidateCount) {
            criteria[identifier] = description
            candidates.append(["id": identifier, "description": description])
        }
        criteria["none"] = "None of the listed controls matches the request."

        let questions: [String: [String: Any]] = [
            "target": [
                "type": "choice",
                "instructions": """
                  The user wants to open a new browser tab. Which listed control does that? \
                  Choose the control whose purpose matches the request. If none of them open a \
                  new tab, choose none.
                  """,
                "criteria": criteria,
            ],
            "is_unambiguous": [
                "type": "noul",
                "instructions": "Is there exactly one control in the list that opens a new browser tab?",
                "criteria": [
                    "true": "Exactly one control opens a new tab.",
                    "false": "No control, or more than one control, opens a new tab.",
                ],
            ],
        ]

        print("""

          == jev probe: \(model) (candidates in \(language == "zh" ? "Chinese" : "English")) ==

        """)

        let result = try await JevProbe(apiKey: apiKey).run(
            JevProbeRequest(
                state: ["userRequest": "帮我打开一个新标签页", "controls": candidates],
                questions: questions,
                model: model,
                timeoutSeconds: 5
            )
        )

        print("    elapsed   \(result.elapsedMilliseconds) ms")
        print("    tokens    in \(result.inputTokens) / out \(result.outputTokens)")
        print("    answers   \(prettyJSON(result.answers))")
        print("""

            A concentrated probability distribution on the expected option means the \
            language is safe for this workload; a flat one means confidence routing \
            (or a fallback to the vision model) is required.

        """)
    }

    private static func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text.indented(by: 14)
    }
}

// MARK: - Small helpers

struct OptionParser {
    /// `--key value` pairs. A flag may be repeated; values accumulate in the
    /// order given, which is what `--truth name=x1,y1,x2,y2` relies on.
    /// Values are never interpreted as flags.
    static func parse(_ arguments: [String]) -> [String: [String]] {
        var options: [String: [String]] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                index = arguments.index(after: index)
                continue
            }
            let key = String(argument.dropFirst(2))
            let nextIndex = arguments.index(after: index)
            if nextIndex < arguments.endIndex, !arguments[nextIndex].hasPrefix("--") {
                options[key, default: []].append(arguments[nextIndex])
                index = arguments.index(after: nextIndex)
            } else {
                options[key, default: []].append("")
                index = nextIndex
            }
        }
        return options
    }

    /// Single-valued read for flags that are not repeatable.
    static func singleValue(_ options: [String: [String]], _ key: String) -> String? {
        guard let values = options[key], let first = values.first, !first.isEmpty else { return nil }
        return first
    }
}

extension String {
    func indented(by spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}
