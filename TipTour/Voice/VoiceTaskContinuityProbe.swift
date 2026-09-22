#if DEBUG
import Foundation
import Security

/// Bounded real-provider turns through the production session and router.
/// The task executor is an in-memory fixture; no desktop, microphone, speaker,
/// persistent task journal, user memory or other provider is used.
///
/// Work order 02: progress language must obey the two-layer facts. A step counts
/// as done because the input was delivered, because the system read the result
/// back, or because the user said it worked — and only the second may be spoken
/// as "已确认". Two task chains therefore run through the same production path
/// with the same two public synthetic PCM inputs:
///
/// 1. `delivery_only_then_cancel` — a two-step chain whose first step is only
///    `delivery_confirmed`. The user asks how far the task has got and then
///    explicitly cancels it. Progress must be announced as 已处理.
/// 2. `all_system_verified` — a two-step chain where every step is independently
///    system-verified. This is the only path allowed to say 已确认.
///
/// Each chain holds the step the fixture is executing, so the progress question
/// is answered from a running/pausing receipt: that is the only state in which
/// Her announces progress instead of a terminal result, and it is exactly the
/// state in which the old wording reported a delivered input as a confirmed one.
@MainActor
enum VoiceTaskContinuityProbe {
    /// What the in-memory fixture proves about the step it executed. The
    /// coordinator — not the probe — decides whether that satisfies the step.
    private enum StepEvidence {
        /// The input reached the target and nothing read the result back.
        case deliveryConfirmed
        /// An independent read-back proved the requested effect.
        case systemVerified
    }

    static func run(progressAudioURL: URL, cancelAudioURL: URL, outputURL: URL) async {
        var report: [String: Any] = ["passed": false, "synthetic_input": true,
            "desktop_actions": 0, "microphone_opened": false, "audio_played": false,
            "phase": "keychain", "provider_connection_attempted": false,
            "verification_level": "real_provider_with_fixture_executor",
            "work_order": "02-progress-evidence-language"]
        let receiptLog = PublishedReceiptLog()
        do {
            guard let key = KeychainStore.get(forKey: "stepfunAPIKey", allowInteraction: false, onFailure: { status in
                report["keychain_status"] = Int(status)
                report["keychain_message"] = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown Keychain status"
            }), !key.isEmpty else {
                throw DesktopTaskContractError.invalid("StepFun Keychain unavailable; no credential fallback or prompt used.")
            }
            let target = DesktopTaskTarget(id: "probe-alpha", label: "探针 Alpha", source: "fixture",
                box: [0, 0, 40, 30], display: [0, 0, 800, 600])
            let fixture = ProbeTaskFixture()
            var unexpectedEngineAccesses = 0
            var coordinator: DesktopTaskCoordinator!
            defer { coordinator = nil }
            coordinator = DesktopTaskCoordinator(observe: {
                DesktopTaskObservation(app: "fixture", targets: [target], windowID: 1)
            }, decide: { _, _, _, _ in
                throw DesktopTaskContractError.invalid("The fixture only accepts exact targets.")
            }, executeStep: { _, _, _, _ in
                let stepIndex = fixture.enterNextStep()
                guard stepIndex == fixture.heldStepIndex else {
                    fixture.recordPerformedStep(stepIndex)
                    return fixture.stepResult()
                }
                // The user starts speaking while this step is still being
                // delivered. The production session performs this same call, and
                // it is what moves a running task into the pausing state where a
                // progress question is answered with progress instead of a
                // terminal result.
                coordinator.pauseForUserInput()
                await fixture.holdStep()
                guard fixture.mayDeliverHeldStep else {
                    // An explicit cancel stops the in-flight delivery, exactly
                    // like the driver being stopped before it returns.
                    return DesktopTaskActionResult(delivery: .notSent, outcomeEvidence: .notObserved,
                        detail: "用户在送达前取消，夹具没有下发这一步。")
                }
                fixture.recordPerformedStep(stepIndex)
                return fixture.stepResult()
            })

            let engine = TipTourEngine(isAutopilotEnabledProvider: { false }, isScreenshotStreamingEnabledProvider: { false },
                isAccurateGroundingEnabledProvider: { false }, isCuaActionDriverEnabledProvider: { false },
                detectionElementCountProvider: { 0 }, refreshLocalPerception: { _ in unexpectedEngineAccesses += 1 },
                normalizeWorkflowSteps: { steps, _ in steps }, startWorkflowPlan: { _ in unexpectedEngineAccesses += 1 })
            let router = StepFunRealtimeToolRouter(engine: engine, visionClient: StepFunVisionClient(apiKey: key),
                preservesTaskLifetime: true, coordinator: coordinator)
            // The panel and the model context are refreshed from this callback in
            // production, so it is the receipt stream the user actually saw.
            router.onTaskReceiptChanged = { receipt in receiptLog.record(receipt) }

            let context = ProbeContext(apiKey: key, target: target, progressAudioURL: progressAudioURL,
                cancelAudioURL: cancelAudioURL, coordinator: coordinator, router: router, fixture: fixture,
                receiptLog: receiptLog)

            report["phase"] = "provider"
            report["provider_connection_attempted"] = true
            var taskChains: [[String: Any]] = []
            taskChains.append(await runTaskChain(context: context, chainName: "delivery_only_then_cancel",
                stepEvidence: .deliveryConfirmed, heldStepIndex: 1, cancelAfterProgress: true))
            taskChains.append(await runTaskChain(context: context, chainName: "all_system_verified",
                stepEvidence: .systemVerified, heldStepIndex: 1, cancelAfterProgress: false))

            report["task_chains"] = taskChains
            report["published_receipts"] = receiptLog.snapshots
            report["progress_over_claims"] = receiptLog.progressOverClaims
            report["fixture_actions"] = fixture.totalPerformedStepCount
            report["unexpected_engine_accesses"] = unexpectedEngineAccesses
            report["passed"] = taskChains.allSatisfy { $0["passed"] as? Bool == true }
                && receiptLog.progressOverClaims.isEmpty
            report["phase"] = "completed"
        } catch {
            report["error"] = error.localizedDescription
        }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL)
            print("[VoiceTaskContinuityProbe] Report: \(outputURL.path)")
        } catch {
            print("[VoiceTaskContinuityProbe] Could not save report: \(error.localizedDescription)")
        }
    }

    // MARK: - Task chains

    /// One two-step task chain: submit the chain, ask for progress while the
    /// chain is still running, optionally cancel it explicitly, then let the
    /// held step settle and check what the user would have been told.
    private static func runTaskChain(context: ProbeContext, chainName: String, stepEvidence: StepEvidence,
                                     heldStepIndex: Int?, cancelAfterProgress: Bool) async -> [String: Any] {
        context.receiptLog.currentChainName = chainName
        context.fixture.beginTaskChain(heldStepIndex: heldStepIndex, stepEvidence: stepEvidence)
        let setupTurnID = "fixture-setup-\(chainName)"
        context.coordinator.beginUserTurn(setupTurnID)
        let admitted = await context.coordinator.submit(DesktopTaskSubmission(goal: "探针任务：点击探针 Alpha 再按回车",
            steps: [DesktopActionStep(action: .click, targetLabel: context.target.label),
                    DesktopActionStep(action: .pressKey, key: "return")],
            turnID: setupTurnID))

        var checks: [[String: Any]] = []
        var rounds: [[String: Any]] = []

        /// One real provider turn: the production session with synthetic PCM in,
        /// the production router and coordinator behind the tool call, and the
        /// verified receipt speech out.
        func runProviderTurn(roundName: String, audioURL: URL) async -> [String: Any] {
            let recorder = RecordingHandler(base: context.router.makeSessionHandler())
            let session = StepFunRealtimeSession(apiKey: context.apiKey,
                model: TipTourDefaults.StepFunConfiguration.realtimeModel,
                voice: TipTourDefaults.StepFunConfiguration.realtimeVoice,
                instructions: CompanionManager.stepfunVoiceInstructions + CompanionManager.taskContinuityVoiceInstructions,
                tools: StepFunRealtimeToolDeclarations.withTaskControls, turnDetection: .manual, toolHandler: recorder)
            context.router.onTaskReceiptChanged = { [weak session] receipt in
                context.receiptLog.record(receipt)
                session?.refreshTaskContext()
            }
            var round: [String: Any] = ["chain": chainName, "name": roundName,
                "audio_source": audioURL.lastPathComponent]
            do {
                let result = try await session.runSyntheticProbe(audio: Data(contentsOf: audioURL))
                let control = recorder.controls.last
                round["input_transcript"] = result.inputTranscript
                round["tool_call_count"] = recorder.controls.count
                round["rejected_tools"] = recorder.rejectedTools
                round["tool_name"] = recorder.lastToolName ?? "none"
                round["tool_arguments"] = recorder.lastToolArgumentsJSON ?? ""
                round["control_action"] = control?.action.rawValue ?? "none"
                round["control_task_id"] = control?.taskID ?? ""
                round["control_target_version"] = control?.targetVersion ?? 0
                round["control_turn_id"] = control?.turnID ?? ""
                round["timed_out"] = result.timedOut
                round["error"] = result.error ?? ""
                round["rendered_texts"] = result.renderedTexts
                round["spoken_text"] = spokenText(from: result.renderedTexts)
                round["captured_audio_bytes"] = result.audio.count
            } catch {
                round["timed_out"] = false
                round["error"] = error.localizedDescription
            }
            round["turn_id"] = recorder.turnID ?? ""
            // The state the panel would show once this turn is over.
            round["task_id"] = context.coordinator.lastReceipt?.taskID ?? ""
            round["receipt_status"] = context.coordinator.lastReceipt?.status ?? "missing"
            round["completed_step_count"] = context.coordinator.lastReceipt?.completedStepCount ?? -1
            round["total_step_count"] = context.coordinator.lastReceipt?.totalStepCount ?? -1
            round["fixture_performed_step_indices"] = context.fixture.performedStepIndices
            context.router.invalidateSessionBinding()
            return round
        }

        // The chain must still be running on the held step when the user speaks;
        // otherwise the question would be answered from a terminal receipt and
        // would prove nothing about progress wording.
        let heldStepIsInFlight = await waitUntil({ context.fixture.isTaskInFlightOnHeldStep }, timeoutSeconds: 30)
        checks.append(check(name: "task_still_running_on_held_step", passed: heldStepIsInFlight,
            detail: "admitted status \(admitted.status), entered steps \(context.fixture.enteredStepIndices)"))

        var progressSpeech = ""
        var progressTurnID = ""
        var progressTaskID = ""
        var performedDuringProgress: [Int] = []
        if heldStepIsInFlight {
            let progressRound = await runProviderTurn(roundName: "progress_question", audioURL: context.progressAudioURL)
            rounds.append(progressRound)
            progressSpeech = progressRound["spoken_text"] as? String ?? ""
            progressTurnID = progressRound["turn_id"] as? String ?? ""
            progressTaskID = progressRound["task_id"] as? String ?? ""
            performedDuringProgress = progressRound["fixture_performed_step_indices"] as? [Int] ?? []
            let progressToolName = progressRound["tool_name"] as? String ?? "none"
            let progressToolArguments = progressRound["tool_arguments"] as? String ?? ""
            let progressError = progressRound["error"] as? String ?? ""
            let progressAudioBytes = progressRound["captured_audio_bytes"] as? Int ?? 0
            checks.append(check(name: "progress_question_used_a_single_task_control",
                passed: progressRound["tool_call_count"] as? Int == 1 && progressRound["rejected_tools"] as? Int == 0,
                detail: "tool \(progressToolName), arguments \(progressToolArguments)"))
            checks.append(check(name: "progress_question_did_not_time_out_or_error",
                passed: progressRound["timed_out"] as? Bool == false && progressError.isEmpty && progressAudioBytes > 0,
                detail: "error \(progressError), audio bytes \(progressAudioBytes)"))
        }

        var cancelControlWasValid = false
        var cancelTurnID = ""
        if heldStepIsInFlight, cancelAfterProgress {
            let cancelRound = await runProviderTurn(roundName: "explicit_cancel", audioURL: context.cancelAudioURL)
            rounds.append(cancelRound)
            cancelTurnID = cancelRound["turn_id"] as? String ?? ""
            let cancelAction = cancelRound["control_action"] as? String ?? "none"
            let cancelControlTaskID = cancelRound["control_task_id"] as? String ?? ""
            let cancelControlVersion = cancelRound["control_target_version"] as? Int ?? 0
            let cancelControlTurnID = cancelRound["control_turn_id"] as? String ?? ""
            let cancelTaskID = cancelRound["task_id"] as? String ?? ""
            let cancelError = cancelRound["error"] as? String ?? ""
            let cancelAudioBytes = cancelRound["captured_audio_bytes"] as? Int ?? 0
            cancelControlWasValid = cancelAction == "cancel"
                && cancelControlTaskID == admitted.taskID
                && cancelControlVersion == admitted.targetVersion
                && cancelControlTurnID == cancelTurnID
                && cancelTaskID == admitted.taskID
            checks.append(check(name: "explicit_cancel_bound_to_current_task_and_turn",
                passed: cancelControlWasValid,
                detail: "action \(cancelAction), task \(cancelControlTaskID), version \(cancelControlVersion), "
                    + "turn \(cancelControlTurnID)"))
            checks.append(check(name: "cancel_turn_did_not_time_out_or_error",
                passed: cancelRound["timed_out"] as? Bool == false && cancelError.isEmpty && cancelAudioBytes > 0,
                detail: "error \(cancelError), audio bytes \(cancelAudioBytes)"))
        }

        // Never leave a held step suspended: a probe that exits with a live task
        // would be indistinguishable from one that finished.
        context.fixture.releaseHeldStep(allowingActionDelivery: !cancelControlWasValid)
        await context.coordinator.waitUntilSettled()
        let finalStatus = context.coordinator.lastReceipt?.status ?? "missing"

        let taskIDWasStable = !admitted.taskID.isEmpty && progressTaskID == admitted.taskID
            && (!cancelAfterProgress || (rounds.last?["task_id"] as? String) == admitted.taskID)
        let finalCancelTaskID = rounds.last?["task_id"] as? String ?? "none"
        checks.append(check(name: "task_id_unchanged_across_turns", passed: taskIDWasStable,
            detail: "admitted \(admitted.taskID), progress \(progressTaskID), after cancel \(finalCancelTaskID)"))
        if cancelAfterProgress {
            checks.append(check(name: "progress_turn_differs_from_cancel_turn",
                passed: !progressTurnID.isEmpty && !cancelTurnID.isEmpty && progressTurnID != cancelTurnID,
                detail: "progress turn \(progressTurnID), cancel turn \(cancelTurnID)"))
            checks.append(check(name: "asking_progress_neither_repeats_nor_runs_ahead",
                passed: performedDuringProgress == [0],
                detail: "fixture performed steps after the progress question: \(performedDuringProgress)"))
            checks.append(check(name: "progress_speech_reports_handled_not_confirmed",
                passed: progressSpeech.contains("已处理 1/2 步") && !progressSpeech.contains("已确认"),
                detail: "spoken text: \(progressSpeech)"))
            checks.append(check(name: "status_is_cancelled_after_explicit_cancel", passed: finalStatus == "cancelled",
                detail: "final status \(finalStatus)"))
        } else {
            checks.append(check(name: "progress_speech_reports_system_verified_steps",
                passed: progressSpeech.contains("已确认 1/2 步") && !progressSpeech.contains("已处理"),
                detail: "spoken text: \(progressSpeech)"))
            let allVerifiedTwoOfTwoStates = context.receiptLog.snapshots.filter { snapshot in
                snapshot["chain"] as? String == chainName
                    && snapshot["processed_step_count"] as? Int == 2
                    && snapshot["total_step_count"] as? Int == 2
                    && snapshot["all_processed_steps_system_verified"] as? Bool == true
            }
            let saysConfirmedTwoOfTwo = allVerifiedTwoOfTwoStates.contains { snapshot in
                (snapshot["spoken_summary"] as? String ?? "").contains("已确认 2/2 步")
            }
            let twoOfTwoWording = allVerifiedTwoOfTwoStates
                .map { "\($0["status"] as? String ?? "?"): \($0["spoken_summary"] as? String ?? "?")" }
                .joined(separator: " | ")
            checks.append(check(name: "fully_verified_two_of_two_state_says_confirmed",
                passed: saysConfirmedTwoOfTwo,
                detail: "all-verified 2/2 states: \(twoOfTwoWording)"))
            let fullyVerifiedTwoOfTwoWasDowngraded = allVerifiedTwoOfTwoStates.contains { snapshot in
                (snapshot["spoken_summary"] as? String ?? "").contains("已处理 2/2 步")
            }
            checks.append(check(name: "fully_verified_two_of_two_is_not_downgraded_to_handled",
                passed: !fullyVerifiedTwoOfTwoWasDowngraded,
                detail: "all-verified 2/2 states: \(twoOfTwoWording)"))
            checks.append(check(name: "every_step_performed_exactly_once",
                passed: context.fixture.performedStepIndices == [0, 1],
                detail: "fixture performed steps: \(context.fixture.performedStepIndices)"))
            checks.append(check(name: "status_is_completed_after_both_verified_steps", passed: finalStatus == "completed",
                detail: "final status \(finalStatus)"))
        }

        let passedChecks = checks.filter { $0["passed"] as? Bool == true }.count
        return ["chain": chainName,
            "step_evidence": stepEvidence == .deliveryConfirmed ? "delivery_confirmed" : "system_verified",
            "goal": admitted.goal, "task_id": admitted.taskID, "setup_turn_id": setupTurnID,
            "admitted_status": admitted.status, "target_version": admitted.targetVersion,
            "rounds": rounds, "checks": checks, "passed": passedChecks == checks.count,
            "check_summary": "\(passedChecks)/\(checks.count)"]
    }

    // MARK: - Helpers

    private static func check(name: String, passed: Bool, detail: String) -> [String: Any] {
        ["name": name, "passed": passed, "detail": detail]
    }

    /// The sentence the voice was required to read. The verified receipt speech
    /// is the last rendered transcript of a turn: anything before it was the
    /// model's preamble, which the receipt path suppresses from playback.
    private static func spokenText(from renderedTexts: [String]) -> String {
        renderedTexts.last ?? ""
    }

    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeoutSeconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Everything a task chain needs, so the two chains stay identical except
    /// for the evidence the fixture reports.
    private struct ProbeContext {
        let apiKey: String
        let target: DesktopTaskTarget
        let progressAudioURL: URL
        let cancelAudioURL: URL
        let coordinator: DesktopTaskCoordinator
        let router: StepFunRealtimeToolRouter
        let fixture: ProbeTaskFixture
        let receiptLog: PublishedReceiptLog
    }

    /// In-memory executor stand-in for the probe's task chains.
    ///
    /// It records which steps it actually performed, and it can hold the step it
    /// is executing so the chain stays in flight. Holding is what makes the
    /// user's progress question arrive while the task is still running, which is
    /// the state whose wording this work order is about.
    @MainActor
    private final class ProbeTaskFixture {
        var heldStepIndex: Int?
        var stepEvidence: StepEvidence = .deliveryConfirmed
        private(set) var enteredStepIndices: [Int] = []
        private(set) var performedStepIndices: [Int] = []
        private(set) var totalPerformedStepCount = 0
        private(set) var mayDeliverHeldStep = true
        private var holdContinuation: CheckedContinuation<Void, Never>?
        private var isHoldingStep = false

        func beginTaskChain(heldStepIndex: Int?, stepEvidence: StepEvidence) {
            self.heldStepIndex = heldStepIndex
            self.stepEvidence = stepEvidence
            enteredStepIndices = []
            performedStepIndices = []
            mayDeliverHeldStep = true
            holdContinuation = nil
            isHoldingStep = false
        }

        func enterNextStep() -> Int {
            let stepIndex = enteredStepIndices.count
            enteredStepIndices.append(stepIndex)
            return stepIndex
        }

        /// True while the chain is still executing the held step. This is the
        /// state the user's progress question has to arrive in.
        var isTaskInFlightOnHeldStep: Bool {
            guard let heldStepIndex else { return false }
            return enteredStepIndices.contains(heldStepIndex) && isHoldingStep
        }

        func holdStep() async {
            isHoldingStep = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // A release that lands before this continuation is stored must
                // not be lost, or the chain would hang instead of reporting.
                if !isHoldingStep { continuation.resume() } else { holdContinuation = continuation }
            }
            isHoldingStep = false
        }

        func releaseHeldStep(allowingActionDelivery: Bool) {
            mayDeliverHeldStep = allowingActionDelivery
            isHoldingStep = false
            holdContinuation?.resume()
            holdContinuation = nil
        }

        func recordPerformedStep(_ stepIndex: Int) {
            performedStepIndices.append(stepIndex)
            totalPerformedStepCount += 1
        }

        func stepResult() -> DesktopTaskActionResult {
            switch stepEvidence {
            case .deliveryConfirmed:
                return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .notObserved,
                    detail: "夹具只确认输入已送达，没有结果读回")
            case .systemVerified:
                return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                    detail: "夹具读回确认结果已生效")
            }
        }
    }

    /// Every receipt the coordinator published, captured through the same
    /// callback the panel and the model context use, so the evidence shows the
    /// states the product actually displayed and spoke from.
    @MainActor
    private final class PublishedReceiptLog {
        private(set) var snapshots: [[String: Any]] = []
        var currentChainName = "setup"

        func record(_ receipt: DesktopTaskReceipt) {
            snapshots.append(["chain": currentChainName,
                "task_id": receipt.taskID,
                "turn_id": receipt.turnID,
                "status": receipt.status,
                "completed_step_count": receipt.completedStepCount,
                "total_step_count": receipt.totalStepCount,
                "processed_step_count": receipt.processedStepCount,
                "system_verified_step_count": receipt.systemVerifiedStepCount,
                "user_confirmed_step_count": receipt.userConfirmedStepCount,
                "all_processed_steps_system_verified": receipt.areAllProcessedStepsSystemVerified,
                // Attempt identity plus the two-layer facts for every action in
                // this invocation: what was delivered, and what was verified.
                "current_action_facts": receipt.currentActions.map { action in
                    ["attempt_id": action.id, "action": action.action.rawValue, "label": action.label,
                     "completion_policy": action.completionPolicy.rawValue,
                     "delivery": action.delivery.rawValue,
                     "outcome_evidence": action.outcomeEvidence.rawValue,
                     "completion_basis": action.completionBasis?.rawValue ?? "none",
                     "satisfied": action.satisfied]
                },
                "current_action_completion_bases": receipt.currentActions.map { $0.completionBasis?.rawValue ?? "none" },
                "spoken_summary": receipt.spokenSummary])
        }

        /// Over-claims only: a progress sentence that reports "已确认" for steps
        /// the system never independently verified. The work order forbids this
        /// for delivery-only and mixed evidence alike.
        var progressOverClaims: [[String: Any]] {
            snapshots.filter { snapshot in
                let summary = snapshot["spoken_summary"] as? String ?? ""
                let processed = snapshot["processed_step_count"] as? Int ?? 0
                let total = snapshot["total_step_count"] as? Int ?? 0
                let isAllSystemVerified = snapshot["all_processed_steps_system_verified"] as? Bool ?? false
                return summary.contains("已确认 \(processed)/\(total) 步") && !isAllSystemVerified
            }
        }
    }

    private final class RecordingHandler: StepFunRealtimeToolHandling {
        let base: StepFunRealtimeToolHandling
        let preservesTaskLifetime = true
        private(set) var turnID: String?
        private(set) var controls: [StepFunTaskControlArguments] = []
        private(set) var toolCalls: [(name: String, argumentsJSON: String)] = []
        private(set) var rejectedTools = 0
        init(base: StepFunRealtimeToolHandling) { self.base = base }
        var taskContext: String? { base.taskContext }
        var lastToolName: String? { toolCalls.last?.name }
        var lastToolArgumentsJSON: String? { toolCalls.last?.argumentsJSON }
        func beginUserTurn(_ turnID: String) { self.turnID = turnID; base.beginUserTurn(turnID) }
        func interrupt() { base.interrupt() }
        func prepareForUserSpeech() { base.prepareForUserSpeech() }
        func handleToolCall(name: String, argumentsJSON: String) async throws -> String {
            guard name == "task_control" else {
                rejectedTools += 1
                throw DesktopTaskContractError.invalid("This probe does not expose real desktop or screen operations.")
            }
            toolCalls.append((name: name, argumentsJSON: argumentsJSON))
            controls.append(try StepFunTaskControlArguments.decode(Data(argumentsJSON.utf8)))
            return try await base.handleToolCall(name: name, argumentsJSON: argumentsJSON)
        }
    }
}
#endif
