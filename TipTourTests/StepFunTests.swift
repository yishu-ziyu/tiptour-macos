//
//  StepFunTests.swift
//  TipTourTests
//
//  Tests for the voice path's decision rules. These are deliberately about the
//  part that can be exercised without a network, a microphone, or a screen: what
//  the voice model is allowed to ask for, and what must be refused.
//
//  Run with `scripts/test-stepfun.sh`, which compiles these sources into an
//  isolated package. That matters: nothing here builds or launches TipTour.app,
//  so running it cannot reset the app's Accessibility / Screen Recording grants.
//

import Foundation
import Testing

@testable import TipTour

// MARK: - Fixtures

private func makeEntries() -> [StepFunScreenControlEntry] {
    [
        StepFunScreenControlEntry(index: 1, label: "文件", kind: "control"),
        StepFunScreenControlEntry(index: 2, label: "新建标签页", kind: "control"),
        StepFunScreenControlEntry(index: 3, label: "搜索输入框", kind: "text"),
    ]
}

private func makeDescription(capturedAt: Date = Date()) -> StepFunScreenDescription {
    StepFunScreenDescription(entries: makeEntries(), activeAppName: "Safari", capturedAt: capturedAt)
}

// MARK: - A valid request becomes an action

@Test func validIndexResolvesToTheNamedControl() {
    let resolution = resolveStepFunAction(description: makeDescription(), requestedIndex: 2)

    guard case .proceed(let entry) = resolution else {
        Issue.record("expected proceed, got \(resolution)")
        return
    }
    #expect(entry.label == "新建标签页")
    #expect(entry.kind == "control")
}

@Test func descriptionRendersEveryControlWithItsNumber() {
    let rendered = makeDescription().renderedForVoiceModel()

    #expect(rendered.contains("1. 文件"))
    #expect(rendered.contains("2. 新建标签页"))
    #expect(rendered.contains("3. 搜索输入框"))
    #expect(rendered.contains("Active app: Safari"))
}

@Test func emptyDescriptionSaysSoRatherThanRenderingAnEmptyList() {
    let empty = StepFunScreenDescription(entries: [], activeAppName: nil)

    #expect(empty.renderedForVoiceModel() == "No interactive controls were found on screen.")
}

// MARK: - A stale description never acts

@Test func missingDescriptionIsRefused() {
    #expect(resolveStepFunAction(description: nil, requestedIndex: 1) == .staleDescription)
}

@Test func expiredDescriptionIsRefused() {
    // Far enough in the past to be outside the validity window, using the
    // injectable capture instant rather than sleeping.
    let stale = makeDescription(capturedAt: Date().addingTimeInterval(-StepFunScreenDescription.validitySeconds - 1))

    #expect(resolveStepFunAction(description: stale, requestedIndex: 2) == .staleDescription)
}

@Test func freshDescriptionIsStillUsable() {
    let fresh = makeDescription(capturedAt: Date().addingTimeInterval(-1))

    guard case .proceed = resolveStepFunAction(description: fresh, requestedIndex: 2) else {
        Issue.record("expected a fresh description to be usable")
        return
    }
}

// MARK: - A number that names nothing is refused

@Test func indexBeyondTheListIsRefusedAndListsWhatIsAvailable() {
    let resolution = resolveStepFunAction(description: makeDescription(), requestedIndex: 9)

    guard case .unknownIndex(let available) = resolution else {
        Issue.record("expected unknownIndex, got \(resolution)")
        return
    }
    #expect(available == [1, 2, 3])
}

@Test func zeroAndNegativeIndicesAreRefused() {
    // A model asked for a numbered list has no reason to emit these; if it does,
    // the request is malformed and must not become a click.
    for index in [0, -1, -99] {
        if case .proceed = resolveStepFunAction(description: makeDescription(), requestedIndex: index) {
            Issue.record("index \(index) must not resolve to a control")
        }
    }
}

// MARK: - An ambiguous name never becomes a click

@Test func duplicatedLabelIsRefused() {
    let ambiguous = StepFunScreenDescription(
        entries: [
            StepFunScreenControlEntry(index: 1, label: "更多", kind: "control"),
            StepFunScreenControlEntry(index: 2, label: "更多", kind: "control"),
            StepFunScreenControlEntry(index: 3, label: "保存", kind: "control"),
        ],
        activeAppName: "Safari"
    )

    guard case .ambiguousLabel(let label, let occurrences) = resolveStepFunAction(description: ambiguous, requestedIndex: 2) else {
        Issue.record("expected ambiguousLabel, got the wrong case")
        return
    }
    #expect(label == "更多")
    #expect(occurrences == 2)
}

@Test func unambiguouslyNamedControlAmongDuplicatesStillResolves() {
    // Refusing to describe repeated labels would lose coverage; only acting on
    // one is dangerous, so the unique entry must still work.
    let mixed = StepFunScreenDescription(
        entries: [
            StepFunScreenControlEntry(index: 1, label: "更多", kind: "control"),
            StepFunScreenControlEntry(index: 2, label: "更多", kind: "control"),
            StepFunScreenControlEntry(index: 3, label: "保存", kind: "control"),
        ],
        activeAppName: "Safari"
    )

    guard case .proceed(let entry) = resolveStepFunAction(description: mixed, requestedIndex: 3) else {
        Issue.record("the unique label should still resolve")
        return
    }
    #expect(entry.label == "保存")
}

@Test func threeCopiesOfTheSameLabelAreAlsoRefused() {
    let tripled = StepFunScreenDescription(
        entries: [
            StepFunScreenControlEntry(index: 1, label: "关闭", kind: "control"),
            StepFunScreenControlEntry(index: 2, label: "关闭", kind: "control"),
            StepFunScreenControlEntry(index: 3, label: "关闭", kind: "control"),
        ],
        activeAppName: nil
    )

    guard case .ambiguousLabel(_, let occurrences) = resolveStepFunAction(description: tripled, requestedIndex: 1) else {
        Issue.record("expected ambiguousLabel")
        return
    }
    #expect(occurrences == 3)
}

// MARK: - The tool declarations the model sees

@Test func toolDeclarationsExposeExactlyTheTwoSupportedTools() {
    let names = StepFunRealtimeToolDeclarations.all.compactMap { declaration -> String? in
        let function = declaration["function"] as? [String: Any]
        return function?["name"] as? String
    }

    #expect(names.sorted() == ["act_on_screen", "describe_screen"])
}

@Test func actOnScreenRequiresNothingButAnIndex() {
    let actOnScreen = StepFunRealtimeToolDeclarations.all.first { declaration in
        (declaration["function"] as? [String: Any])?["name"] as? String == "act_on_screen"
    }
    let parameters = (actOnScreen?["function"] as? [String: Any])?["parameters"] as? [String: Any]
    let required = parameters?["required"] as? [String]

    // `action` must stay optional: the click kind is JEV's decision, and a
    // misheard "double click" must not be able to force one.
    #expect(required == ["index"])
}

@Test func modelIsNeverOfferedACoordinateParameter() {
    // The load-bearing constraint. Vision models do not report usable pixel
    // coordinates, so no tool may accept one — otherwise a hallucinated pair
    // becomes a confident click in the wrong place.
    let serialised = StepFunRealtimeToolDeclarations.all
        .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        .compactMap { String(data: $0, encoding: .utf8) }
        .joined()

    for forbidden in ["x1", "y1", "x2", "y2", "coordinate", "bbox", "box", "point", "pixel"] {
        #expect(!serialised.lowercased().contains(forbidden.lowercased()),
                "tool declarations must not mention \(forbidden)")
    }
}
