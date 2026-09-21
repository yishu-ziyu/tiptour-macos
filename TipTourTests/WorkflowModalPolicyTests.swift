import XCTest
@testable import TipTour

final class WorkflowModalPolicyTests: XCTestCase {
    func testOtherModelessDialogDoesNotBlockCurrentWindow() {
        XCTAssertFalse(WorkflowModalPolicy.blocksCurrentWindow(subrole: "AXDialog", isModal: nil, isFocused: false))
        XCTAssertFalse(WorkflowModalPolicy.blocksCurrentWindow(subrole: "AXDialog", isModal: false, isFocused: true))
    }

    func testModalAndFocusedDialogsStillBlock() {
        XCTAssertTrue(WorkflowModalPolicy.blocksCurrentWindow(subrole: "AXDialog", isModal: true, isFocused: false))
        XCTAssertTrue(WorkflowModalPolicy.blocksCurrentWindow(subrole: "AXSystemDialog", isModal: nil, isFocused: true))
        XCTAssertFalse(WorkflowModalPolicy.blocksCurrentWindow(subrole: "AXStandardWindow", isModal: nil, isFocused: true))
    }

    func testOpenApplicationDoesNotPauseOnIntermediateActivation() {
        XCTAssertFalse(WorkflowApplicationSwitchPolicy.shouldPause(
            isOpenApplicationStep: true,
            matchesPlanTarget: false
        ))
        XCTAssertFalse(WorkflowApplicationSwitchPolicy.shouldPause(
            isOpenApplicationStep: true,
            matchesPlanTarget: true
        ))
    }

    func testOtherActionsStillPauseForUnrelatedApplications() {
        XCTAssertTrue(WorkflowApplicationSwitchPolicy.shouldPause(
            isOpenApplicationStep: false,
            matchesPlanTarget: false
        ))
        XCTAssertFalse(WorkflowApplicationSwitchPolicy.shouldPause(
            isOpenApplicationStep: false,
            matchesPlanTarget: true
        ))
    }
}
