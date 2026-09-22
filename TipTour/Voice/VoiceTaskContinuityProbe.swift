#if DEBUG
import Foundation
import Security

/// Two bounded real-provider turns through the production session and router.
/// The task executor is an in-memory fixture; no desktop, microphone, speaker,
/// persistent task journal, user memory or other provider is used.
@MainActor
enum VoiceTaskContinuityProbe {
    static func run(progressAudioURL: URL, cancelAudioURL: URL, outputURL: URL) async {
        var report: [String: Any] = ["passed": false, "synthetic_input": true,
            "desktop_actions": 0, "microphone_opened": false, "audio_played": false,
            "phase": "keychain", "provider_connection_attempted": false,
            "verification_level": "real_provider_with_fixture_executor"]
        do {
            guard let key = KeychainStore.get(forKey: "stepfunAPIKey", allowInteraction: false, onFailure: { status in
                report["keychain_status"] = Int(status)
                report["keychain_message"] = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown Keychain status"
            }), !key.isEmpty else {
                throw DesktopTaskContractError.invalid("StepFun Keychain unavailable; no credential fallback or prompt used.")
            }
            let target = DesktopTaskTarget(id: "probe-alpha", label: "探针 Alpha", source: "fixture",
                box: [0, 0, 40, 30], display: [0, 0, 800, 600])
            var fixtureActions = 0
            var unexpectedEngineAccesses = 0
            var coordinator: DesktopTaskCoordinator!
            defer { coordinator = nil }
            coordinator = DesktopTaskCoordinator(observe: {
                DesktopTaskObservation(app: "fixture", targets: [target], windowID: 1)
            }, decide: { _, _, _, _ in
                throw DesktopTaskContractError.invalid("The fixture only accepts exact targets.")
            }, executeStep: { _, _, _, _ in
                fixtureActions += 1
                coordinator.pauseForUserInput()
                return DesktopTaskActionResult(delivery: .sent, outcomeEvidence: .systemVerified,
                    detail: "in-memory fixture readback")
            })
            coordinator.beginUserTurn("fixture-setup")
            let admitted = await coordinator.submit(DesktopTaskSubmission(goal: "探针任务：完成两个步骤", steps: [
                DesktopActionStep(targetLabel: target.label), DesktopActionStep(targetLabel: target.label)
            ], turnID: "fixture-setup"))
            await coordinator.waitUntilSettled()
            coordinator.pauseForDisconnection()

            let engine = TipTourEngine(isAutopilotEnabledProvider: { false }, isScreenshotStreamingEnabledProvider: { false },
                isAccurateGroundingEnabledProvider: { false }, isCuaActionDriverEnabledProvider: { false },
                detectionElementCountProvider: { 0 }, refreshLocalPerception: { _ in unexpectedEngineAccesses += 1 },
                normalizeWorkflowSteps: { steps, _ in steps }, startWorkflowPlan: { _ in unexpectedEngineAccesses += 1 })
            let router = StepFunRealtimeToolRouter(engine: engine, visionClient: StepFunVisionClient(apiKey: key),
                preservesTaskLifetime: true, coordinator: coordinator)
            var rounds: [[String: Any]] = []
            var previousTurnID: String?
            for (name, audioURL) in [("progress", progressAudioURL), ("cancel_after_reconnect", cancelAudioURL)] {
                let recorder = RecordingHandler(base: router.makeSessionHandler())
                let session = StepFunRealtimeSession(apiKey: key,
                    model: TipTourDefaults.StepFunConfiguration.realtimeModel,
                    voice: TipTourDefaults.StepFunConfiguration.realtimeVoice,
                    instructions: CompanionManager.stepfunVoiceInstructions + CompanionManager.taskContinuityVoiceInstructions,
                    tools: StepFunRealtimeToolDeclarations.withTaskControls, turnDetection: .manual, toolHandler: recorder)
                router.onTaskReceiptChanged = { [weak session] _ in session?.refreshTaskContext() }
                report["phase"] = "provider"
                report["provider_connection_attempted"] = true
                let result = try await session.runSyntheticProbe(audio: Data(contentsOf: audioURL))
                await coordinator.waitUntilSettled()
                let control = recorder.controls.last
                let isProgress = name == "progress"
                let correctControl = isProgress
                    ? control?.action == .status
                    : control?.action == .cancel && control?.taskID == admitted.taskID
                        && control?.targetVersion == admitted.targetVersion && control?.turnID == recorder.turnID
                let expectedStatus = isProgress ? "paused" : "cancelled"
                let passed = !result.timedOut && result.error == nil && !result.audio.isEmpty
                    && recorder.controls.count == 1 && recorder.rejectedTools == 0 && correctControl
                    && coordinator.lastReceipt?.taskID == admitted.taskID && coordinator.lastReceipt?.status == expectedStatus
                    && fixtureActions == 1 && unexpectedEngineAccesses == 0
                    && (previousTurnID == nil || previousTurnID != recorder.turnID)
                rounds.append(["name": name, "passed": passed, "timed_out": result.timedOut,
                    "error": result.error ?? "", "tool_count": recorder.controls.count,
                    "input_transcript": result.inputTranscript,
                    "rejected_tools": recorder.rejectedTools, "action": control?.action.rawValue ?? "none",
                    "control_binding_valid": correctControl, "task_id": coordinator.lastReceipt?.taskID ?? "",
                    "turn_id": recorder.turnID ?? "", "status": coordinator.lastReceipt?.status ?? "missing",
                    "rendered_texts": result.renderedTexts, "captured_audio_bytes": result.audio.count])
                report["rounds"] = rounds
                previousTurnID = recorder.turnID
                router.invalidateSessionBinding()
                if !passed { break }
            }
            report["fixture_actions"] = fixtureActions
            report["unexpected_engine_accesses"] = unexpectedEngineAccesses
            report["passed"] = rounds.count == 2 && rounds.allSatisfy { $0["passed"] as? Bool == true }
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

    private final class RecordingHandler: StepFunRealtimeToolHandling {
        let base: StepFunRealtimeToolHandling
        let preservesTaskLifetime = true
        private(set) var turnID: String?
        private(set) var controls: [StepFunTaskControlArguments] = []
        private(set) var rejectedTools = 0
        init(base: StepFunRealtimeToolHandling) { self.base = base }
        var taskContext: String? { base.taskContext }
        func beginUserTurn(_ turnID: String) { self.turnID = turnID; base.beginUserTurn(turnID) }
        func interrupt() { base.interrupt() }
        func prepareForUserSpeech() { base.prepareForUserSpeech() }
        func handleToolCall(name: String, argumentsJSON: String) async throws -> String {
            guard name == "task_control" else {
                rejectedTools += 1
                throw DesktopTaskContractError.invalid("This probe does not expose real desktop or screen operations.")
            }
            controls.append(try StepFunTaskControlArguments.decode(Data(argumentsJSON.utf8)))
            return try await base.handleToolCall(name: name, argumentsJSON: argumentsJSON)
        }
    }
}
#endif
