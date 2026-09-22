#if DEBUG
import AppKit
import CryptoKit
import Foundation
import Security

/// DEBUG-only delivery-receipt fault.
///
/// Acceptance must be able to prove what Her does when a real action already
/// reached the page but its delivery receipt never came back: the product has
/// to record `delivery=unknown`, stop, and never repeat the side effect. This
/// gate reproduces exactly that loss — it is armed for one delivery, throws
/// after the real driver has already delivered, and is compiled only into
/// DEBUG builds. Production never reaches the injection point, and nothing
/// here retries, re-dispatches or otherwise repairs the lost receipt.
@MainActor
enum DesktopReceiptLossFault {
    /// Deliveries still owed a dropped receipt. Zero in every production run;
    /// a probe arms exactly one before driving the real route.
    private static var armedDeliveryCount = 0

    static var isArmed: Bool { armedDeliveryCount > 0 }

    /// Arm the next successful delivery to lose its receipt. One injection per
    /// arming on purpose: a scenario that dropped every receipt could not prove
    /// that Her stops after exactly one unknown instead of grinding on.
    static func armNextDelivery() {
        armedDeliveryCount = 1
    }

    static func disarm() {
        armedDeliveryCount = 0
    }

    /// Called after the real driver delivered the action and before the
    /// success is reported upstream. Throwing here is precisely what a lost
    /// driver receipt looks like to the product: the input happened, but no
    /// confirmation came back, so delivery stays `unknown`.
    static func dropSuccessfulDeliveryReceiptIfArmed() throws {
        guard armedDeliveryCount > 0 else { return }
        armedDeliveryCount = 0
        throw DesktopReceiptLossFaultError.deliveryReceiptLost
    }
}

/// The error a dropped receipt surfaces as. Lives beside the DEBUG fault so
/// Release builds contain neither the throw site nor the type.
enum DesktopReceiptLossFaultError: LocalizedError {
    case deliveryReceiptLost

    var errorDescription: String? {
        switch self {
        case .deliveryReceiptLost:
            return "DEBUG fault: the driver delivered the action, but its success receipt was dropped before the product could record it."
        }
    }
}

/// The two real-path acceptance scenarios for delivery unknown and legacy
/// journal recovery. Both run inside the signed DEBUG app on the production
/// route; neither opens the microphone, plays audio, or drives any window
/// except the local fixture page.
@MainActor
enum DesktopUnknownRecoveryProbe {

    // MARK: - Scenario U: receipt loss after a real click

    /// Drives the production tool route twice through one task: a click on the
    /// right-side settings control whose successful driver receipt is dropped,
    /// then a plain continuation request in the same task. Everything the
    /// product observed — tool arguments, task/turn/attempt IDs, receipts,
    /// spoken summaries and the fixture's independent `/state` — is written to
    /// `outputURL` together with the work order's acceptance checks.
    static func runReceiptLossScenario(
        companionManager: CompanionManager,
        targetApplicationBundleIdentifier: String,
        fixtureStateBaseURL: String,
        firstRoundToolArgumentsJSON: String,
        continuationRoundToolArgumentsJSON: String,
        outputURL: URL
    ) async {
        var report: [String: Any] = [
            "scenario": "U_receipt_loss",
            "entrypoint": "signed_debug_app_launch_argument",
            "route": "StepFunRealtimeToolRouter.handleToolCall(act_on_screen) -> DesktopTaskCoordinator -> DesktopTaskExecutor -> TipTourEngine.runPointerAction -> WorkflowRunner.performAction -> ActionExecutor.click -> CuaActionDriver",
            "microphone_opened": false,
            "synthetic_audio": false,
            "provider_connection_attempted": false,
            "desktop_fixture_only": true,
            "target_application_bundle": targetApplicationBundleIdentifier,
            "fixture_state_base_url": fixtureStateBaseURL,
            "user_words": userWords(fromToolArgumentsJSON: firstRoundToolArgumentsJSON),
            "first_round_tool_arguments": firstRoundToolArgumentsJSON,
            "continuation_round_tool_arguments": continuationRoundToolArgumentsJSON
        ]
        do {
            companionManager.start()
            // Warm local perception exactly like the production desktop-task
            // route does before a task observes the screen.
            _ = await companionManager.tipTourEngine.groundTarget(
                goal: "准备验收页面",
                app: targetApplicationBundleIdentifier,
                actionType: .click,
                targetLabel: nil,
                targetID: nil,
                targetMark: nil,
                refresh: true,
                allowScreenshotPlanning: false
            )
            let router = StepFunRealtimeToolRouter(
                engine: companionManager.tipTourEngine,
                visionClient: StepFunVisionClient(apiKey: KeychainStore.stepfunAPIKey ?? "")
            )
            report["fixture_state_before"] = readFixtureState(fixtureStateBaseURL)

            // Arm the one-shot fault only after every preparation step so the
            // dropped receipt belongs to the task's click and to nothing else.
            DesktopReceiptLossFault.armNextDelivery()
            report["fault_armed_before_first_round"] = DesktopReceiptLossFault.isArmed
            let firstRoundToolOutput = try await router.handleToolCall(
                name: "act_on_screen",
                argumentsJSON: firstRoundToolArgumentsJSON
            )
            report["fault_consumed_by_first_round"] = !DesktopReceiptLossFault.isArmed
            report["fixture_state_after_first_round"] = readFixtureState(fixtureStateBaseURL)
            let firstRoundReceipt = try decodeReceipt(firstRoundToolOutput)
            report["first_round"] = receiptEvidence(firstRoundReceipt, toolOutput: firstRoundToolOutput)

            let continuationToolOutput = try await router.handleToolCall(
                name: "act_on_screen",
                argumentsJSON: continuationRoundToolArgumentsJSON
            )
            report["fixture_state_after_continuation"] = readFixtureState(fixtureStateBaseURL)
            let continuationReceipt = try decodeReceipt(continuationToolOutput)
            report["continuation_round"] = receiptEvidence(continuationReceipt, toolOutput: continuationToolOutput)

            // The default production route keeps no recovery journal; the
            // journal is exercised by scenario R instead of implying one here.
            report["journal"] = [
                "active": false,
                "note": "The default tool route runs without the retained task journal; scenario R exercises the real journal bytes."
            ]

            let checks = receiptLossChecks(
                firstRoundReceipt: firstRoundReceipt,
                continuationReceipt: continuationReceipt,
                fixtureStateBefore: report["fixture_state_before"] as? [String: Any] ?? [:],
                fixtureStateAfterFirstRound: report["fixture_state_after_first_round"] as? [String: Any] ?? [:],
                fixtureStateAfterContinuation: report["fixture_state_after_continuation"] as? [String: Any] ?? [:],
                faultWasArmed: report["fault_armed_before_first_round"] as? Bool ?? false,
                faultWasConsumed: report["fault_consumed_by_first_round"] as? Bool ?? false
            )
            report["checks"] = checks
            report["passed"] = checks.allSatisfy { $0["passed"] as? Bool == true }
        } catch {
            report["error"] = error.localizedDescription
            report["passed"] = false
        }
        writeReport(report, to: outputURL)
    }

    // MARK: - Scenario R: real v1 journal recovery

    /// Writes a genuine v1 recovery journal (the schema an older build left
    /// behind) into a temporary Application Support directory, then runs the
    /// real recovery flow: `configureJournal`, a plain resume, and an explicit
    /// user cancel. A second, unreadable journal proves the original bytes are
    /// preserved instead of overwritten. No engine, driver or desktop action is
    /// reachable from this probe — any dispatch is a failure, counted as one.
    static func runJournalRecoveryScenario(
        applicationSupportRootURL: URL,
        outputURL: URL
    ) async {
        var report: [String: Any] = [
            "scenario": "R_v1_journal_recovery",
            "entrypoint": "signed_debug_app_launch_argument",
            "route": "DesktopTaskJournal.load + DesktopTaskCoordinator.configureJournal + DesktopTaskCoordinator.submit + DesktopTaskCoordinator.cancelTask",
            "microphone_opened": false,
            "provider_connection_attempted": false,
            "desktop_actions_expected": 0,
            "application_support_root": applicationSupportRootURL.path
        ]
        let bundleDirectoryName = Bundle.main.bundleIdentifier ?? "tiptour-local"
        let legacyTaskID = UUID().uuidString
        let legacyTargetVersion = 1
        let legacyAttemptID = UUID().uuidString
        let recoveryDirectory = applicationSupportRootURL
            .appendingPathComponent(bundleDirectoryName)
            .appendingPathComponent("TaskRecovery")
        let journalFileURL = recoveryDirectory.appendingPathComponent("task.json")

        do {
            try FileManager.default.createDirectory(
                at: recoveryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let legacyBytes = try legacyVersionOneJournalBytes(
                taskID: legacyTaskID,
                targetVersion: legacyTargetVersion,
                attemptID: legacyAttemptID
            )
            try legacyBytes.write(to: journalFileURL)
            report["legacy_journal_file"] = [
                "path": journalFileURL.path,
                "bytes_utf8": String(decoding: legacyBytes, as: UTF8.self),
                "bytes_sha256": sha256Hex(legacyBytes),
                "schema_version": 1,
                "stored_status": "completed",
                "legacy_attempt_verified": false
            ]
        } catch {
            report["error_setup"] = error.localizedDescription
            report["passed"] = false
            writeReport(report, to: outputURL)
            return
        }

        var observationReads = 0
        var desktopActionDispatches = 0
        let coordinator = DesktopTaskCoordinator(
            observe: {
                observationReads += 1
                return DesktopTaskObservation(app: "fixture", targets: [], windowID: 1)
            },
            decide: { _, _, _, _ in
                // Recovery must never reach candidate selection; counting it
                // keeps the tripwire total for every decision-layer entry.
                desktopActionDispatches += 1
                throw DesktopTaskContractError.invalid("Recovery probe never asks for a decision.")
            },
            executeStep: { _, _, _, _ in
                desktopActionDispatches += 1
                return DesktopTaskActionResult(
                    delivery: .notSent,
                    outcomeEvidence: .notObserved,
                    detail: "Unexpected desktop dispatch during recovery."
                )
            }
        )
        coordinator.beginUserTurn("recovery-probe-turn")
        // The real recovery entry: the coordinator loads the legacy snapshot
        // itself and decides what the user must see.
        coordinator.configureJournal(DesktopTaskJournal(directory: recoveryDirectory))
        let recoveredReceipt = coordinator.lastReceipt
        report["recovery_receipt"] = receiptEvidence(recoveredReceipt)
        report["observation_reads_after_recovery"] = observationReads
        report["desktop_action_dispatches_after_recovery"] = desktopActionDispatches

        // A plain resume of the recovered task must be refused without any
        // action; only an explicit uncertain resolution or a cancel may move it.
        let refusedResumeReceipt = await coordinator.submit(DesktopTaskSubmission(
            goal: "继续之前的任务",
            intent: .resume,
            turnID: "recovery-probe-turn"
        ))
        report["plain_resume_receipt"] = receiptEvidence(refusedResumeReceipt)
        report["desktop_action_dispatches_after_plain_resume"] = desktopActionDispatches

        // The user explicitly cancels: the task terminates and the old journal
        // is closed out, never replayed.
        let cancelledReceipt = coordinator.cancelTask(
            taskID: legacyTaskID,
            targetVersion: legacyTargetVersion,
            turnID: "recovery-probe-turn"
        )
        report["explicit_cancel_receipt"] = receiptEvidence(cancelledReceipt)
        report["desktop_action_dispatches_after_explicit_cancel"] = desktopActionDispatches
        report["observation_reads_total"] = observationReads
        if let journalBytesAfterCancel = try? Data(contentsOf: journalFileURL) {
            report["journal_after_explicit_cancel"] = [
                "bytes_sha256": sha256Hex(journalBytesAfterCancel),
                "bytes_utf8": String(decoding: journalBytesAfterCancel, as: UTF8.self),
                "parsed_status": parsedJournalStatus(journalBytesAfterCancel),
                "parsed_schema_version": parsedJournalSchemaVersion(journalBytesAfterCancel),
                "parsed_attempt_ids": parsedJournalAttemptIDs(journalBytesAfterCancel)
            ]
        } else {
            report["journal_after_explicit_cancel"] = ["error": "journal file missing after cancel"]
        }

        // An unreadable journal must be preserved verbatim and block work.
        let unreadableRoot = applicationSupportRootURL
            .appendingPathComponent("unreadable-case-\(UUID().uuidString)")
        let unreadableDirectory = unreadableRoot
            .appendingPathComponent(bundleDirectoryName)
            .appendingPathComponent("TaskRecovery")
        let unreadableJournalFileURL = unreadableDirectory.appendingPathComponent("task.json")
        var unreadableObservationReads = 0
        var unreadableActionDispatches = 0
        do {
            try FileManager.default.createDirectory(
                at: unreadableDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Truncated JSON: real bytes an older build could never finish
            // writing, which the loader must refuse rather than replace.
            let unreadableBytes = Data("{\"schemaVersion\": 1, \"taskID\": \"unreadable-task\", \"status\": \"run".utf8)
            try unreadableBytes.write(to: unreadableJournalFileURL)
            let unreadableCoordinator = DesktopTaskCoordinator(
                observe: {
                    unreadableObservationReads += 1
                    return DesktopTaskObservation(app: "fixture", targets: [], windowID: 1)
                },
                decide: { _, _, _, _ in
                    unreadableActionDispatches += 1
                    throw DesktopTaskContractError.invalid("Unreadable journal probe never asks for a decision.")
                },
                executeStep: { _, _, _, _ in
                    unreadableActionDispatches += 1
                    return DesktopTaskActionResult(
                        delivery: .notSent,
                        outcomeEvidence: .notObserved,
                        detail: "Unexpected desktop dispatch with an unreadable journal."
                    )
                }
            )
            unreadableCoordinator.beginUserTurn("unreadable-probe-turn")
            unreadableCoordinator.configureJournal(DesktopTaskJournal(directory: unreadableDirectory))
            let unreadableReceipt = unreadableCoordinator.lastReceipt
            let unreadableSubmitReceipt = await unreadableCoordinator.submit(DesktopTaskSubmission(
                goal: "任何新任务",
                steps: [DesktopActionStep(targetLabel: "设置")],
                turnID: "unreadable-probe-turn"
            ))
            let unreadableBytesAfter = try Data(contentsOf: unreadableJournalFileURL)
            report["unreadable_journal_case"] = [
                "recovery_receipt": receiptEvidence(unreadableReceipt),
                "submit_receipt": receiptEvidence(unreadableSubmitReceipt),
                "observation_reads": unreadableObservationReads,
                "desktop_action_dispatches": unreadableActionDispatches,
                "bytes_before_sha256": sha256Hex(unreadableBytes),
                "bytes_after_sha256": sha256Hex(unreadableBytesAfter),
                "bytes_after_utf8": String(decoding: unreadableBytesAfter, as: UTF8.self)
            ]
        } catch {
            report["unreadable_journal_case"] = ["error": error.localizedDescription]
        }

        let checks = journalRecoveryChecks(
            report: report,
            legacyTaskID: legacyTaskID,
            legacyTargetVersion: legacyTargetVersion,
            legacyAttemptID: legacyAttemptID,
            desktopActionDispatches: desktopActionDispatches,
            observationReads: observationReads
        )
        report["checks"] = checks
        report["passed"] = checks.allSatisfy { $0["passed"] as? Bool == true }
        writeReport(report, to: outputURL)
    }

    // MARK: - Scenario U checks

    /// The work order's acceptance list for scenario U, evaluated against what
    /// the fixture's independent `/state` and the receipts actually show.
    private static func receiptLossChecks(
        firstRoundReceipt: DesktopTaskReceipt,
        continuationReceipt: DesktopTaskReceipt,
        fixtureStateBefore: [String: Any],
        fixtureStateAfterFirstRound: [String: Any],
        fixtureStateAfterContinuation: [String: Any],
        faultWasArmed: Bool,
        faultWasConsumed: Bool
    ) -> [[String: Any]] {
        let firstRoundAttempt = firstRoundReceipt.currentActions.last
        let firstRoundDelivery = firstRoundAttempt?.delivery ?? .notSent
        let fixtureSelectedAfterFirstRound = fixtureSelectedValue(fixtureStateAfterFirstRound)
        let fixtureClickCountAfterFirstRound = fixtureClickCount(fixtureStateAfterFirstRound)
        let fixtureSelectedAfterContinuation = fixtureSelectedValue(fixtureStateAfterContinuation)
        let fixtureClickCountAfterContinuation = fixtureClickCount(fixtureStateAfterContinuation)
        let fixtureEventLog = fixtureEventLog(fixtureStateAfterContinuation)
        // The fixture page names its controls; the right-side settings control
        // is the scenario's target and the left-side one must stay untouched.
        let expectedSelectedValue = "right-setting"
        let expectedClickCount = 1
        let firstRoundSpokenSummary = firstRoundReceipt.spokenSummary
        let finalSpokenSummary = continuationReceipt.spokenSummary
        let attemptIDsAcrossBothRounds = (firstRoundReceipt.currentActions + continuationReceipt.currentActions).map(\.id)

        return [
            check(
                "fixture_selected_the_right_setting_control",
                fixtureSelectedAfterFirstRound == expectedSelectedValue,
                "selected=\(fixtureSelectedAfterFirstRound)"
            ),
            check(
                "fixture_recorded_exactly_one_real_click",
                fixtureClickCountAfterFirstRound == expectedClickCount,
                "clicks=\(fixtureClickCountAfterFirstRound)"
            ),
            check(
                "first_receipt_delivery_is_unknown",
                firstRoundDelivery == .unknown,
                "delivery=\(firstRoundDelivery.rawValue)"
            ),
            check(
                "first_receipt_status_is_uncertain_effect",
                firstRoundReceipt.status == "uncertain_effect",
                "status=\(firstRoundReceipt.status)"
            ),
            check(
                "fault_injected_exactly_once_after_real_delivery",
                faultWasArmed && faultWasConsumed,
                "armed=\(faultWasArmed), consumed=\(faultWasConsumed)"
            ),
            check(
                "continuation_left_the_click_count_at_one",
                fixtureClickCountAfterContinuation == expectedClickCount,
                "clicks=\(fixtureClickCountAfterContinuation)"
            ),
            check(
                "continuation_kept_the_same_selection",
                fixtureSelectedAfterContinuation == expectedSelectedValue,
                "selected=\(fixtureSelectedAfterContinuation)"
            ),
            check(
                "left_setting_control_was_never_selected",
                !fixtureEventLog.contains("left-setting") && fixtureEventLog == [expectedSelectedValue],
                "events=\(fixtureEventLog)"
            ),
            check(
                "continuation_dispatched_no_new_action",
                continuationReceipt.currentActions.isEmpty,
                "current_actions=\(continuationReceipt.currentActions.count)"
            ),
            check(
                "continuation_status_is_uncertain_effect",
                continuationReceipt.status == "uncertain_effect",
                "status=\(continuationReceipt.status)"
            ),
            check(
                "the_same_attempt_was_never_resent",
                attemptIDsAcrossBothRounds.count == 1 && attemptIDsAcrossBothRounds.first == firstRoundAttempt?.id,
                "attempt_ids=\(attemptIDsAcrossBothRounds)"
            ),
            check(
                "first_speech_acknowledges_the_attempt_and_stops",
                firstRoundSpokenSummary.contains("尝试了操作")
                    && firstRoundSpokenSummary.contains("已停下")
                    && !firstRoundSpokenSummary.contains("没有执行")
                    && !firstRoundSpokenSummary.contains("完成"),
                "spoken=\(firstRoundSpokenSummary)"
            ),
            check(
                "final_speech_says_uncertain_and_stopped_without_claiming_completion",
                (finalSpokenSummary.contains("未确认") || finalSpokenSummary.contains("不确定"))
                    && finalSpokenSummary.contains("已停")
                    && !finalSpokenSummary.contains("完成"),
                "spoken=\(finalSpokenSummary)"
            ),
            check(
                "fixture_state_was_readable_before_the_scenario",
                fixtureSelectedValue(fixtureStateBefore) != "unreadable"
                    && fixtureClickCount(fixtureStateBefore) >= 0,
                "selected=\(fixtureSelectedValue(fixtureStateBefore)), clicks=\(fixtureClickCount(fixtureStateBefore))"
            )
        ]
    }

    // MARK: - Scenario R checks

    private static func journalRecoveryChecks(
        report: [String: Any],
        legacyTaskID: String,
        legacyTargetVersion: Int,
        legacyAttemptID: String,
        desktopActionDispatches: Int,
        observationReads: Int
    ) -> [[String: Any]] {
        let recoveryReceipt = report["recovery_receipt"] as? [String: Any] ?? [:]
        let plainResumeReceipt = report["plain_resume_receipt"] as? [String: Any] ?? [:]
        let cancelReceipt = report["explicit_cancel_receipt"] as? [String: Any] ?? [:]
        let journalAfterCancel = report["journal_after_explicit_cancel"] as? [String: Any] ?? [:]
        let unreadableCase = report["unreadable_journal_case"] as? [String: Any] ?? [:]
        let unreadableRecoveryReceipt = unreadableCase["recovery_receipt"] as? [String: Any] ?? [:]
        let unreadableSubmitReceipt = unreadableCase["submit_receipt"] as? [String: Any] ?? [:]
        let unreadableDispatches = unreadableCase["desktop_action_dispatches"] as? Int ?? -1
        let unreadableBytesBefore = unreadableCase["bytes_before_sha256"] as? String ?? ""
        let unreadableBytesAfter = unreadableCase["bytes_after_sha256"] as? String ?? ""
        let attemptIDsAfterCancel = journalAfterCancel["parsed_attempt_ids"] as? [String] ?? []

        return [
            check(
                "legacy_file_was_a_real_v1_journal",
                (report["legacy_journal_file"] as? [String: Any] ?? [:])["schema_version"] as? Int == 1
                    && (report["legacy_journal_file"] as? [String: Any] ?? [:])["legacy_attempt_verified"] as? Bool == false,
                "schema_version=1, verified=false"
            ),
            check(
                "completed_v1_snapshot_recovers_as_recovery_required",
                recoveryReceipt["status"] as? String == "recovery_required",
                "status=\(recoveryReceipt["status"] as? String ?? "missing")"
            ),
            check(
                "recovery_preserves_the_legacy_task_identity",
                recoveryReceipt["task_id"] as? String == legacyTaskID
                    && recoveryReceipt["target_version"] as? Int == legacyTargetVersion,
                "task_id=\(recoveryReceipt["task_id"] as? String ?? "missing"), target_version=\(recoveryReceipt["target_version"] as? Int ?? -1)"
            ),
            check(
                "recovery_ran_no_screen_observation",
                observationReads == 0,
                "observation_reads=\(observationReads)"
            ),
            check(
                "recovery_dispatched_no_desktop_action",
                desktopActionDispatches == 0,
                "desktop_action_dispatches=\(desktopActionDispatches)"
            ),
            check(
                "plain_resume_is_refused_without_any_action",
                plainResumeReceipt["status"] as? String == "recovery_required" && desktopActionDispatches == 0,
                "status=\(plainResumeReceipt["status"] as? String ?? "missing"), dispatches=\(desktopActionDispatches)"
            ),
            check(
                "explicit_user_cancel_terminates_the_task",
                cancelReceipt["status"] as? String == "cancelled" && desktopActionDispatches == 0,
                "status=\(cancelReceipt["status"] as? String ?? "missing"), dispatches=\(desktopActionDispatches)"
            ),
            check(
                "cancelled_journal_keeps_the_old_attempt_as_history_without_replay",
                journalAfterCancel["parsed_status"] as? String == "cancelled"
                    && attemptIDsAfterCancel.contains(legacyAttemptID)
                    && desktopActionDispatches == 0,
                "status=\(journalAfterCancel["parsed_status"] as? String ?? "missing"), attempts=\(attemptIDsAfterCancel), dispatches=\(desktopActionDispatches)"
            ),
            check(
                "unreadable_journal_is_preserved_verbatim",
                unreadableBytesBefore == unreadableBytesAfter && !unreadableBytesBefore.isEmpty
                    && unreadableDispatches == 0,
                "before=\(unreadableBytesBefore), after=\(unreadableBytesAfter), dispatches=\(unreadableDispatches)"
            ),
            check(
                "unreadable_journal_reports_storage_failure_and_blocks_work",
                unreadableRecoveryReceipt["status"] as? String == "storage_failed"
                    && unreadableSubmitReceipt["status"] as? String == "storage_failed"
                    && unreadableDispatches == 0,
                "recovery=\(unreadableRecoveryReceipt["status"] as? String ?? "missing"), submit=\(unreadableSubmitReceipt["status"] as? String ?? "missing")"
            )
        ]
    }

    // MARK: - Shared helpers

    private static func check(_ name: String, _ passed: Bool, _ observed: String) -> [String: Any] {
        ["name": name, "passed": passed, "observed": observed]
    }

    private static func receiptEvidence(_ receipt: DesktopTaskReceipt?, toolOutput: String? = nil) -> [String: Any] {
        guard let receipt else { return ["missing": true] }
        var evidence: [String: Any] = [
            "status": receipt.status,
            "task_id": receipt.taskID,
            "turn_id": receipt.turnID,
            "target_version": receipt.targetVersion,
            "goal": receipt.goal,
            "detail": receipt.detail,
            "app": receipt.app ?? "none",
            "actions": receipt.actions,
            "prior_actions": receipt.priorActions,
            "verified_action_history": receipt.verifiedActionHistory,
            "satisfied_action_history": receipt.satisfiedActionHistory,
            "completed_step_count": receipt.completedStepCount,
            "total_step_count": receipt.totalStepCount,
            "spoken_summary": receipt.spokenSummary,
            "current_actions": receipt.currentActions.map { record in
                [
                    "attempt_id": record.id,
                    "observation_id": record.observationID,
                    "app": record.app,
                    "target_id": record.targetID ?? "none",
                    "label": record.label,
                    "action": record.action.rawValue,
                    "completion_policy": record.completionPolicy.rawValue,
                    "delivery": record.delivery.rawValue,
                    "outcome_evidence": record.outcomeEvidence.rawValue,
                    "satisfied": record.satisfied,
                    "uncertain_effect": record.uncertainEffect,
                    "verified": record.verified,
                    "detail": record.detail
                ]
            }
        ]
        if let toolOutput {
            // The exact JSON the voice model received as the tool result.
            evidence["tool_output"] = toolOutput
        }
        return evidence
    }

    private static func decodeReceipt(_ toolOutput: String) throws -> DesktopTaskReceipt {
        try JSONDecoder().decode(DesktopTaskReceipt.self, from: Data(toolOutput.utf8))
    }

    private static func userWords(fromToolArgumentsJSON argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let goal = object["goal"] as? String, !goal.isEmpty else {
            return "unavailable"
        }
        return goal
    }

    /// Reads the fixture page's independent `/state`. A failed read is recorded
    /// as an error rather than silently becoming a passing scenario.
    ///
    /// curl rather than URLSession on purpose: this is a plain-HTTP localhost
    /// read from a DEBUG probe, and it must not depend on the app's App
    /// Transport Security posture to produce evidence.
    private static func readFixtureState(_ baseURL: String) -> [String: Any] {
        let normalizedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let stateURL = normalizedBaseURL + "/state"
        let curlProcess = Process()
        curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curlProcess.arguments = ["-s", "--max-time", "3", stateURL]
        let outputPipe = Pipe()
        curlProcess.standardOutput = outputPipe
        do {
            try curlProcess.run()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            curlProcess.waitUntilExit()
            guard curlProcess.terminationStatus == 0 else {
                return ["error": "fixture state read exited with status \(curlProcess.terminationStatus)"]
            }
            guard let object = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                return ["error": "fixture state was not a JSON object"]
            }
            return object
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private static func fixtureSelectedValue(_ state: [String: Any]) -> String {
        (state["selected"] as? String) ?? (state["error"] != nil ? "unreadable" : "none")
    }

    private static func fixtureClickCount(_ state: [String: Any]) -> Int {
        // A missing or unreadable count is -1 so no check can pass by accident.
        (state["clicks"] as? Int) ?? -1
    }

    private static func fixtureEventLog(_ state: [String: Any]) -> [String] {
        (state["events"] as? [String]) ?? []
    }

    /// The journal bytes an older build wrote: schema v1, a flattened
    /// `verified` Bool, and no two-layer delivery/evidence fields. The
    /// completed claim carries a `verified=false` attempt, which is exactly
    /// the false-completion class recovery must catch.
    private static func legacyVersionOneJournalBytes(
        taskID: String,
        targetVersion: Int,
        attemptID: String
    ) throws -> Data {
        let observationID = "legacy-observation-\(UUID().uuidString.prefix(8))"
        let targetDigest = SHA256.hash(data: Data("fixture\u{0}\u{0}设置".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let legacySnapshot: [String: Any] = [
            "schemaVersion": 1,
            "taskID": taskID,
            "targetVersion": targetVersion,
            "status": "completed",
            "completedStepCount": 1,
            "totalStepCount": 1,
            "attempts": [
                [
                    "id": attemptID,
                    "observationID": observationID,
                    "revision": 1,
                    "action": "click",
                    "targetDigest": targetDigest,
                    "verified": false
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: legacySnapshot, options: [.sortedKeys])
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parsedJournalStatus(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else {
            return "unparsable"
        }
        return status
    }

    private static func parsedJournalSchemaVersion(_ data: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemaVersion = object["schemaVersion"] as? Int else {
            return -1
        }
        return schemaVersion
    }

    private static func parsedJournalAttemptIDs(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attempts = object["attempts"] as? [[String: Any]] else {
            return []
        }
        return attempts.compactMap { $0["id"] as? String }
    }

    private static func writeReport(_ report: [String: Any], to outputURL: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL)
            print("[UnknownRecoveryProbe] Report: \(outputURL.path)")
        } catch {
            print("[UnknownRecoveryProbe] Could not save report: \(error.localizedDescription)")
        }
    }
}
#endif
