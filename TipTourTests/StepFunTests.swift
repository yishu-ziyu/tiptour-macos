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

@Test func expiredDescriptionCannotBeUsed() {
    let stale = makeDescription(capturedAt: Date().addingTimeInterval(-StepFunScreenDescription.validitySeconds - 1))
    #expect(stale.isExpired)
    #expect(!makeDescription().isExpired)
}

@Test func invalidIndexTypesAreRejectedBeforeTargetResolution() {
    for json in [#"{"goal":"点击","index":true}"#, #"{"goal":"点击","index":1.5}"#] {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StepFunActionArguments.self, from: Data(json.utf8))
        }
    }
}

// MARK: - The tool declarations the model sees

@Test func toolDeclarationsExposeExactlyTheTwoSupportedTools() {
    let names = StepFunRealtimeToolDeclarations.all.compactMap { declaration -> String? in
        let function = declaration["function"] as? [String: Any]
        return function?["name"] as? String
    }

    #expect(names.sorted() == ["act_on_screen", "describe_screen"])
}

@Test func actOnScreenRequiresACompleteGoal() {
    let actOnScreen = StepFunRealtimeToolDeclarations.all.first { declaration in
        (declaration["function"] as? [String: Any])?["name"] as? String == "act_on_screen"
    }
    let parameters = (actOnScreen?["function"] as? [String: Any])?["parameters"] as? [String: Any]
    let required = parameters?["required"] as? [String]

    // Legacy single-click requests remain valid; explicit workflows declare
    // their action kinds inside steps instead of requiring a top-level action.
    #expect(required == ["goal"])
}

@Test func modelIsNeverOfferedACoordinateParameter() {
    // This tool contract uses observed identities, not free-form locations.
    // It makes no general claim about a visual model's capabilities.
    let serialised = StepFunRealtimeToolDeclarations.all
        .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        .compactMap { String(data: $0, encoding: .utf8) }
        .joined()

    for forbidden in ["x1", "y1", "x2", "y2", "coordinate", "bbox", "box", "point", "pixel"] {
        #expect(!serialised.lowercased().contains(forbidden.lowercased()),
                "tool declarations must not mention \(forbidden)")
    }
}

@Test func toolContractSeparatesRightSideFromRightClick() {
    let serialised = StepFunRealtimeToolDeclarations.all
        .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        .compactMap { String(data: $0, encoding: .utf8) }
        .joined()

    #expect(serialised.contains("右边"))
    #expect(serialised.contains("右侧"))
    #expect(serialised.contains("Never turn 右边 into right_click"))
    #expect(serialised.contains("右键、右击"))
}

@Test func observationNumberRequiresTheExactObservationIdentity() {
    let description = makeDescription()
    #expect(description.entry(index: 2, observationID: description.observationID)?.label == "新建标签页")
    #expect(description.entry(index: 2, observationID: "another-frame") == nil)
    #expect(description.entry(index: 2, observationID: nil) == nil)
    #expect(description.entry(index: 500, observationID: description.observationID) == nil)
}

@Test func namesBeyondTheOldThirtyControlCutoffAreStillPresented() {
    let entries = (1...80).map { StepFunScreenControlEntry(index: $0, label: "控件\($0)", kind: "ax") }
    let description = StepFunScreenDescription(entries: entries, activeAppName: "fixture")
    #expect(description.renderedForVoiceModel().contains("80. 控件80"))
}

@Test func malformedOrConflictingActionParametersNeverReachTheRunner() throws {
    for json in [
        #"{"goal":"点击 os","target_labe":"os"}"#,
        #"{"goal":"点击 os","steps":[{"action":"click","target_labe":"os"}]}"#,
        #"{"goal":"点击 os","action":"invented"}"#,
        #"{"goal":"点击 os","index":2}"#,
        #"{"goal":"点击 os","action":"click","text":"不应被忽略"}"#,
        #"{"goal":"两步","action":"click","steps":[{"action":"click"}]}"#,
        #"{"goal":"打开应用","action":"open_app"}"#,
        #"{"goal":"输入","action":"type","text":"hello"}"#
    ] {
        #expect(throws: (any Error).self) {
            let arguments = try StepFunActionArguments.decode(Data(json.utf8))
            _ = try arguments.validatedSteps()
        }
    }
}

@Test func openApplicationAndExplicitWorkflowDecodeWithoutInventedScreenTargets() throws {
    let application = try StepFunActionArguments.decode(Data(#"{"goal":"打开计算器","intent":"new","action":"open_app","application":"Calculator"}"#.utf8))
    let applicationSteps = try application.validatedSteps()
    #expect(applicationSteps.count == 1)
    #expect(applicationSteps[0].action == .openApp)
    #expect(applicationSteps[0].targetLabel == nil)
    let workflow = try StepFunActionArguments.decode(Data(#"{"goal":"填写搜索框","steps":[{"action":"click","target_label":"搜索框"},{"action":"type","target_label":"搜索框","text":"Jarvis"}]}"#.utf8))
    let workflowSteps = try workflow.validatedSteps()
    #expect(workflowSteps.count == 2)
    #expect(workflowSteps[1].text == "Jarvis")
}

@Test func goalWithoutActionOrPointerConstraintIsRejectedInsteadOfClicking() {
    // A bare goal is not a click. When the model forgets both the action and
    // every target constraint (most often a missing open_app), executing
    // would mean clicking whatever the decision layer happens to rank first.
    for json in [
        #"{"goal":"打开豆包"}"#,
        #"{"goal":"把页面往下滚"}"#,
    ] {
        #expect(throws: (any Error).self) {
            let arguments = try StepFunActionArguments.decode(Data(json.utf8))
            _ = try arguments.validatedSteps()
        }
    }
}

@Test func omittedTopLevelPointerActionRequiresAnExplicitPointerConstraint() throws {
    for json in [
        #"{"goal":"打开那个项目","target_label":"那个项目"}"#,
        #"{"goal":"点击左侧的按钮","region":"left"}"#,
        #"{"goal":"点击文件夹下面的项目","anchor_label":"文件夹","relation":"below"}"#,
        #"{"goal":"点击列表第三项","index":3,"observation_id":"obs-1"}"#,
    ] {
        let arguments = try StepFunActionArguments.decode(Data(json.utf8))
        let steps = try arguments.validatedSteps()
        #expect(steps.count == 1)
        #expect(steps[0].action == .click)
        #expect(steps[0].allowsActionDecision)
    }
}

@Test func explicitPointerActionStaysLocked() throws {
    let arguments = try StepFunActionArguments.decode(Data(
        #"{"goal":"右键那个项目","action":"right_click"}"#.utf8
    ))
    let steps = try arguments.validatedSteps()
    #expect(steps[0].action == .rightClick)
    #expect(!steps[0].allowsActionDecision)
}

@Test func rightSideLiteralCannotBecomeRightClick() throws {
    let arguments = try StepFunActionArguments.decode(Data(
        #"{"goal":"请点击右边的设置按钮","action":"right_click"}"#.utf8
    ))
    let steps = try arguments.validatedSteps()
    #expect(steps[0].action == .click)
    #expect(steps[0].region == .right)
    #expect(!steps[0].allowsActionDecision)
}

@Test func explicitRightClickOnRightSideRemainsRightClick() throws {
    let arguments = try StepFunActionArguments.decode(Data(
        #"{"goal":"请右键点击右边的设置按钮","action":"right_click"}"#.utf8
    ))
    let steps = try arguments.validatedSteps()
    #expect(steps[0].action == .rightClick)
    #expect(steps[0].region == .right)
}
