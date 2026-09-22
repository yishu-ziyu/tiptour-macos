//
//  StepFunRealtimeToolRouter.swift
//  TipTour
//
//  Screen questions use visual context; action requests enter the shared task
//  coordinator directly. Concrete target identities survive model handoffs.
//

import AppKit
import Foundation

@MainActor
final class StepFunRealtimeToolRouter: StepFunRealtimeToolHandling {
    private let engine: TipTourEngine
    private var visionClient: StepFunVisionClient
    let preservesTaskLifetime: Bool
    private var activeSessionID: UUID?
    var onTaskReceiptChanged: ((DesktopTaskReceipt) -> Void)?
    private var currentDescription: StepFunScreenDescription?
    private var describedTargets: [Int: DesktopTaskTarget] = [:]
    private var screenHistory: [String] = []
    private var windowMonitor: Task<Void, Never>?
    private var inputMonitor: Any?
    private var contentVersion = 0
    private var lastWindowContext = ""
    private var currentTurnID = UUID().uuidString
    private let injectedCoordinator: DesktopTaskCoordinator?
    var onWindowContextChanged: ((String) -> Void)?
    private lazy var executor = DesktopTaskExecutor(engine: engine, currentContext: { [weak self] in
        self?.executionContext()
    })

    private lazy var coordinator = injectedCoordinator ?? DesktopTaskCoordinator(
        observe: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.observeForAction()
        },
        observeContext: { [weak self] in
            guard let self else { throw CancellationError() }
            return try self.observeContextForAction()
        },
        decideWithStep: { [weak self] goal, step, observation, history, useGeneralReasoning in
            guard let self else { throw CancellationError() }
            return try await self.chooseStep(goal: goal, step: step, observation: observation,
                                             history: history, useGeneralReasoning: useGeneralReasoning)
        },
        executeStep: { [weak self] goal, observation, target, step in
            guard let self else { throw CancellationError() }
            return try await self.executor.execute(goal: goal, observation: observation, target: target, step: step)
        }
    )

    init(engine: TipTourEngine, visionClient: StepFunVisionClient, preservesTaskLifetime: Bool = false,
         coordinator: DesktopTaskCoordinator? = nil) {
        self.engine = engine
        self.visionClient = visionClient
        self.preservesTaskLifetime = preservesTaskLifetime
        self.injectedCoordinator = coordinator
        if preservesTaskLifetime {
            self.coordinator.canReserveDesktop = { [weak engine] in
                engine?.hasActiveLegacyTask == false && !WorkflowRunner.shared.isBusy
            }
            self.coordinator.onReceiptChanged = { [weak self] receipt in self?.onTaskReceiptChanged?(receipt) }
            if injectedCoordinator == nil { self.coordinator.configureJournal(.applicationDefault()) }
        }
    }

    func updateVisionClient(_ client: StepFunVisionClient) { visionClient = client }
    fileprivate func isCurrentSession(_ sessionID: UUID) -> Bool { activeSessionID == sessionID }

    func invalidateSessionBinding() {
        activeSessionID = nil
        coordinator.endUserTurn()
    }

    func makeSessionHandler() -> StepFunRealtimeToolHandling {
        guard preservesTaskLifetime else { return self }
        let sessionID = UUID()
        activeSessionID = sessionID
        coordinator.endUserTurn()
        currentDescription = nil
        describedTargets = [:]
        currentTurnID = UUID().uuidString
        return TaskSessionBinding(router: self, sessionID: sessionID)
    }

    var taskContext: String? {
        guard preservesTaskLifetime, let receipt = coordinator.lastReceipt else { return nil }
        let payload: [String: Any] = ["control_turn_id": currentTurnID,
            "task": (try? JSONSerialization.jsonObject(with: Data(receipt.toolOutput.utf8))) ?? [:]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    var currentTaskReceipt: DesktopTaskReceipt? { coordinator.lastReceipt }

    func startMonitoring() {
        windowMonitor?.cancel()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.contentVersion += 1
                self?.currentDescription = nil
                self?.describedTargets = [:]
            }
        }
        windowMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
                let context = "app=\(app.localizedName ?? "unknown"), window=\(self.currentWindowID() ?? -1)"
                if context != self.lastWindowContext {
                    self.lastWindowContext = context
                    self.currentDescription = nil
                    self.describedTargets = [:]
                    self.onWindowContextChanged?(context)
                }
            }
        }
    }

    func stopMonitoring() {
        windowMonitor?.cancel()
        windowMonitor = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    func interrupt() {
        if preservesTaskLifetime {
            coordinator.pauseForDisconnection()
            pausePendingDelivery()
            return
        }
        coordinator.interrupt()
        WorkflowRunner.shared.stop()
    }

    func prepareForUserSpeech() {
        guard preservesTaskLifetime else { return }
        coordinator.pauseForUserInput()
        pausePendingDelivery()
    }

    private func pausePendingDelivery() {
        guard let attempt = coordinator.lastReceipt?.currentActions.last else { return }
        WorkflowRunner.shared.pauseBeforeDelivery(traceID: attempt.id)
    }

    func beginUserTurn(_ turnID: String) {
        currentTurnID = turnID
        coordinator.beginUserTurn(turnID)
    }

    func handleToolCall(name: String, argumentsJSON: String) async throws -> String {
        let arguments = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any] ?? [:]
        switch name {
        case "task_control":
            guard preservesTaskLifetime else { return rejectedAction("任务控制入口尚未启用。") }
            let control = try StepFunTaskControlArguments.decode(Data(argumentsJSON.utf8))
            if control.action == .status {
                return coordinator.lastReceipt?.toolOutput ?? rejectedAction("当前没有任务。")
            }
            guard let taskID = control.taskID, let version = control.targetVersion,
                  let turnID = control.turnID, turnID == currentTurnID,
                  let current = coordinator.lastReceipt,
                  current.taskID == taskID, current.targetVersion == version else {
                return rejectedAction("任务控制不属于当前发言，未执行。")
            }
            if control.action == .cancel {
                guard let receipt = coordinator.cancelTask(taskID: taskID, targetVersion: version, turnID: turnID) else {
                    return rejectedAction("任务身份或版本已变化，未取消其他任务。")
                }
                if let attempt = receipt.currentActions.last,
                   WorkflowRunner.shared.activePlan?.traceID == attempt.id,
                   let operationID = WorkflowRunner.shared.currentOperationID {
                    WorkflowRunner.shared.stop(operationID: operationID)
                }
                return receipt.toolOutput
            }
            if let attempt = coordinator.lastReceipt?.currentActions.last,
               WorkflowRunner.shared.activePlan?.traceID == attempt.id,
               WorkflowRunner.shared.pausedReason == .userSpeaking,
               let operationID = WorkflowRunner.shared.currentOperationID {
                WorkflowRunner.shared.stop(operationID: operationID)
            }
            let receipt = await coordinator.continueTask(taskID: taskID, targetVersion: version,
                turnID: turnID, onlyAfterUserInput: control.action == .statusAndContinue)
            return receipt?.toolOutput ?? rejectedAction("当前任务不满足继续条件，保持暂停。")
        case "describe_screen":
            return await describeScreen(intent: arguments["intent"] as? String ?? "描述当前屏幕")
        case "act_on_screen":
            let actionArguments: StepFunActionArguments
            var requestedSteps: [DesktopActionStep]
            let continuationOnly: Bool
            do {
                actionArguments = try StepFunActionArguments.decode(Data(argumentsJSON.utf8))
                continuationOnly = actionArguments.intent == .resume && actionArguments.steps == nil
                    && actionArguments.action == nil && actionArguments.targetLabel == nil && actionArguments.index == nil
                    && actionArguments.region == nil && actionArguments.anchorLabel == nil && actionArguments.relation == nil
                    && actionArguments.text == nil && actionArguments.key == nil && actionArguments.application == nil
                    && actionArguments.direction == nil && actionArguments.amount == nil && actionArguments.expectedLabel == nil
                    && actionArguments.observationID == nil
                requestedSteps = continuationOnly ? [] : try actionArguments.validatedSteps()
                // Evidence trail: the raw model arguments and the effective plan are
                // already captured with the tool call; this line records only WHY the
                // plan had to be reshaped. Voice probes/runners capture stdout.
                if !actionArguments.normalizationNotes.isEmpty {
                    print("[TaskRouter] steps normalization applied: \(actionArguments.normalizationNotes.joined(separator: "; "))")
                }
            } catch {
                return rejectedAction("任务参数不完整或有冲突，没有执行。")
            }
            var exactTarget: DesktopTaskTarget?
            if let index = actionArguments.index {
                guard let description = currentDescription,
                      description.entry(index: index, observationID: actionArguments.observationID) != nil,
                      let target = describedTargets[index] else {
                    return rejectedAction("此前的观察编号已失效，没有执行；请保留目标重新定位。")
                }
                if let name = requestedSteps[0].targetLabel,
                   DesktopActionStep.normalized(name) != DesktopActionStep.normalized(target.label) {
                    return rejectedAction("观察编号与目标名称不一致，没有执行。")
                }
                requestedSteps[0].targetLabel = target.label
                exactTarget = target
            }
            let goal = actionArguments.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? exactTarget.map { "点击控件「\($0.label)」" } ?? ""
            guard !goal.isEmpty else { return rejectedAction("缺少完整操作目标，没有执行。") }
            currentDescription = nil
            describedTargets = [:]
            if preservesTaskLifetime {
                return await coordinator.submit(DesktopTaskSubmission(goal: goal, exactTarget: exactTarget,
                    steps: continuationOnly ? nil : requestedSteps,
                    intent: actionArguments.intent ?? (actionArguments.resumePrevious == true ? .resume : .new),
                    uncertainResolution: actionArguments.uncertainResolution, turnID: currentTurnID)).toolOutput
            }
            let receipt = await coordinator.run(goal: goal, exactTarget: exactTarget,
                resumePrevious: actionArguments.resumePrevious ?? false, steps: continuationOnly ? nil : requestedSteps,
                intent: actionArguments.intent, uncertainResolution: actionArguments.uncertainResolution,
                turnID: currentTurnID)
            DesktopVoiceTrace.event("task_result", turnID: receipt.turnID,
                fields: ["task_id": receipt.taskID, "target_version": String(receipt.targetVersion), "status": receipt.status,
                         "current_action_count": String(receipt.currentActions.count), "prior_action_count": String(receipt.priorActions.count)],
                privateFields: ["receipt": receipt.toolOutput])
            return receipt.toolOutput
        default:
            return "不支持工具 \(name)。"
        }
    }

    private func observeForAction(requireActionPermissions: Bool = true) async throws -> DesktopTaskObservation {
        let state = engine.observe()
        guard !requireActionPermissions || (state.isCuaActionDriverEnabled && state.isAutopilotEnabled) else {
            throw NSError(domain: "DesktopTask", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要开启桌面操作和自动点击。"])
        }
        let context = executionContext()
        let previousFrameID = LocalPerceptionTargetCache.shared.frameEvidence()?.id
        let list = await engine.localPerceptionTargets(refresh: true, reason: "voice action observation")
        try Task.checkCancellation()
        guard let app = list.activeBundleIdentifier, !app.isEmpty,
              let context, context.app == app, executionContext() == context,
              let frame = LocalPerceptionTargetCache.shared.frameEvidence(), frame.id != previousFrameID,
              Date().timeIntervalSince(frame.capturedAt) < StepFunScreenDescription.validitySeconds else {
            throw NSError(domain: "DesktopTask", code: 2, userInfo: [NSLocalizedDescriptionKey: "观察期间窗口已变化，请重新发起任务。"])
        }
        // This is the same image used by OCR, not a later screenshot of a
        // different screen. The screenshot toggle still gates remote images.
        let imageData = state.isScreenshotStreamingEnabled
            ? NSBitmapImageRep(cgImage: frame.image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) : nil
        let observation = DesktopTaskObservation(app: app, targets: list.targets.map(Self.taskTarget),
            windowID: context.windowID, id: frame.id, capturedAt: frame.capturedAt, contentVersion: context.contentVersion,
            imageDataURL: imageData.map { "data:image/jpeg;base64,\($0.base64EncodedString())" })
        DesktopVoiceTrace.event("scene_observed", turnID: currentTurnID,
            fields: ["observation_id": observation.id, "target_count": String(observation.targets.count)],
            privateFields: ["candidates": observation.targets.map { "\($0.id) | \($0.label)" }.joined(separator: "\n")])
        return observation
    }

    private func observeContextForAction() throws -> DesktopTaskObservation {
        let state = engine.observe()
        guard state.isCuaActionDriverEnabled, state.isAutopilotEnabled else {
            throw NSError(domain: "DesktopTask", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要开启桌面操作和自动操作。"])
        }
        guard let context = executionContext() else {
            throw NSError(domain: "DesktopTask", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有可用的前台应用上下文。"])
        }
        let observation = DesktopTaskObservation(
            app: context.app,
            targets: [],
            windowID: context.windowID,
            id: "ctx_\(UUID().uuidString.prefix(8))",
            capturedAt: Date(),
            contentVersion: context.contentVersion
        )
        DesktopVoiceTrace.event("action_context_observed", turnID: currentTurnID,
            fields: ["observation_id": observation.id, "target_count": "0", "mode": "context_only"])
        return observation
    }

    private func chooseStep(goal: String, step: DesktopActionStep, observation: DesktopTaskObservation, history: [String],
                            useGeneralReasoning: Bool) async throws -> DesktopTaskDecision {
        // Reuse the user's JEV key only when configured; otherwise the configured
        // general StepFun model owns semantic selection. Exact targets need neither.
        if !useGeneralReasoning, !(KeychainStore.get(forKey: "jevAPIKey", allowInteraction: false) ?? "").isEmpty,
           let request = JevGrounding.request(task: goal, candidates: observation.targets.map { target in
               JevCandidate(id: target.id, label: target.label, source: target.source, confidence: 1,
                            centre: CGPoint(x: (target.box[0] + target.box[2]) / 2,
                                            y: (target.box[1] + target.box[3]) / 2))
           }, history: history, excluding: [],
              forcedActionKind: step.allowsActionDecision ? nil : step.action.rawValue) {
            let (answers, metrics) = try await JevClient.shared.ask(state: request.state, questions: request.questions)
            let forcedAction = step.allowsActionDecision ? nil : step.action.rawValue
            let decision = try JevGrounding.decision(from: answers, pool: request.pool, metrics: metrics,
                                                      forcedActionKind: forcedAction)
            let completed = decision.done >= JevGrounding.doneThreshold && (!decision.choseNone || !history.isEmpty)
            print("[DesktopTask] decision provider=JEV, done=\(decision.done), choseNone=\(decision.choseNone), ms=\(metrics.milliseconds)")
            return DesktopTaskDecision(targetID: decision.stopReason == nil ? decision.best?.candidate.id : nil,
                                       action: decision.actionKind,
                                       completed: completed,
                                       reason: completed ? "JEV 判断目标已完成。" : (decision.stopReason ?? "JEV 已判断当前任务状态。"),
                                       declined: decision.choseNone,
                                       source: .jevFanout,
                                       actionProbability: decision.actionProbability,
                                       actionMargin: decision.actionMargin,
                                       targetProbability: decision.targetProbability,
                                       targetMargin: decision.targetMargin)
        }
        var imageDataURL: String?
        if useGeneralReasoning {
            guard executionContext()?.app == observation.app, currentWindowID() == observation.windowID,
                  contentVersion == observation.contentVersion else { throw CancellationError() }
            imageDataURL = engine.observe().isScreenshotStreamingEnabled ? observation.imageDataURL : nil
        }
        print("[DesktopTask] decision provider=StepFun general, visual=\(imageDataURL != nil)")
        return try await visionClient.planDesktopStep(goal: goal, observation: observation, history: history, imageDataURL: imageDataURL)
    }

    private func describeScreen(intent: String, retriesRemaining: Int = 1) async -> String {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              let frontmostBundleIdentifier = frontmostApplication.bundleIdentifier,
              frontmostBundleIdentifier != Bundle.main.bundleIdentifier,
              let frontmostBundleURL = frontmostApplication.bundleURL else {
            return "当前没有可确认的前台应用窗口。"
        }

        let visibleApplication = DesktopApplicationCandidate(
            bundleIdentifier: frontmostBundleIdentifier,
            url: frontmostBundleURL,
            names: [frontmostApplication.localizedName ?? frontmostBundleIdentifier]
        )
        let presence = DesktopApplicationResolver.presence(of: visibleApplication)
        guard presence.hasVisibleWindow else {
            return "「\(frontmostApplication.localizedName ?? frontmostBundleIdentifier)」进程正在运行，但当前没有可见窗口，所以我不能说我看到了它。"
        }

        if Self.isWindowVisibilityConfirmation(intent) {
            return presence.isForeground
                ? "能确认当前前台是「\(frontmostApplication.localizedName ?? frontmostBundleIdentifier)」，而且它有可见窗口。"
                : "应用有可见窗口，但当前没有位于前台，所以我不能说正在看它。"
        }

        let observation: DesktopTaskObservation
        do { observation = try await observeForAction(requireActionPermissions: false) }
        catch { return "当前画面尚未稳定，未取得有效观察。" }
        let observedContentVersion = observation.contentVersion
        guard !Task.isCancelled else { return "屏幕读取已取消。" }
        let presented = observation.targets
        let entries = presented.enumerated().map { index, target in
            StepFunScreenControlEntry(index: index + 1, label: target.label, kind: target.source)
        }
        let description = StepFunScreenDescription(entries: entries, activeAppName: observation.app,
            capturedAt: observation.capturedAt, observationID: observation.id)
        let rendered = description.renderedForVoiceModel()

        // Most conversational screen questions only need reliable app/window
        // identity plus visible labels. Keep that path local and sub-second;
        // reserve the remote vision model for genuinely visual semantics.
        if !Self.requiresRemoteVisualSemantics(intent), !presented.isEmpty {
            currentDescription = description
            describedTargets = Dictionary(uniqueKeysWithValues: presented.enumerated().map { ($0.offset + 1, $0.element) })
            let labels = presented.prefix(18).map(\.label).filter { !$0.isEmpty }
            let summary = labels.isEmpty ? "没有读到可靠的界面文字。" : "本地能确认的界面文字或控件包括：\(labels.joined(separator: "、"))。"
            DesktopVoiceTrace.event("screen_answer_local", turnID: currentTurnID,
                fields: ["target_count": String(presented.count), "remote_vision": "false"])
            return "当前可见窗口属于「\(frontmostApplication.localizedName ?? frontmostBundleIdentifier)」。\(summary)"
        }

        guard engine.observe().isScreenshotStreamingEnabled else {
            return "当前截图发送已关闭。我能确认「\(frontmostApplication.localizedName ?? frontmostBundleIdentifier)」有可见窗口，但不能解释窗口里的视觉内容。\n\(rendered)"
        }

        let relatedProcessIdentifiers = DesktopApplicationResolver.processIdentifiers(
            belongingTo: frontmostBundleURL
        )
        let windowCapture: CompanionWindowCGImageCapture
        do {
            guard let capturedWindow = try await CompanionScreenCaptureUtility.captureVisibleApplicationWindow(
                processIdentifiers: relatedProcessIdentifiers,
                preferredFrontmostProcessIdentifier: frontmostApplication.processIdentifier
            ) else {
                return "读取时没有找到「\(frontmostApplication.localizedName ?? frontmostBundleIdentifier)」的可见窗口，所以我不能声称看到了内容。"
            }
            windowCapture = capturedWindow
        } catch {
            return "目标应用窗口截图失败：\(error.localizedDescription)。"
        }
        // The observation belongs to this exact window, not to the app in
        // general: while the slow vision call runs, the app can switch windows
        // without changing its bundle ID or process.
        let observedWindow = DesktopObservedWindowIdentity(
            bundleIdentifier: frontmostBundleIdentifier,
            processIdentifier: windowCapture.processIdentifier,
            windowID: Int(windowCapture.windowID),
            frame: windowCapture.frame,
            capturedAt: windowCapture.capturedAt,
            contentVersion: observedContentVersion,
            contentFingerprint: DesktopWindowContentFingerprint.hash(of: windowCapture.image)
        )
        guard let jpegData = NSBitmapImageRep(cgImage: windowCapture.image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            return "目标应用窗口无法编码为视觉输入。\n\(rendered)"
        }
        let imageDataURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        do {
            let previous = screenHistory.joined(separator: "\n")
            let result = try await visionClient.describeScreen(imageDataURL: imageDataURL, intent: intent,
                                                               previousObservations: previous, controlsContext: rendered)
            try Task.checkCancellation()
            let currentFrontmostApplication = NSWorkspace.shared.frontmostApplication
            let relatedProcessesStillCurrent = DesktopApplicationResolver.processIdentifiers(
                belongingTo: frontmostBundleURL
            ).contains(windowCapture.processIdentifier)
            guard observedWindow.isStillCurrent(
                frontmostBundleIdentifier: currentFrontmostApplication?.bundleIdentifier,
                frontmostWindowID: currentWindowID(),
                currentWindowFrame: Self.currentFrameOfWindow(windowCapture.windowID),
                observedProcessStillExists: relatedProcessesStillCurrent,
                currentContentVersion: contentVersion,
                maximumAge: StepFunScreenDescription.validitySeconds
            ) else {
                if retriesRemaining > 0 { return await describeScreen(intent: intent, retriesRemaining: retriesRemaining - 1) }
                return "读取期间页面仍在变化，这份旧观察不能回答当前画面。请待页面稳定再读。"
            }
            // The same window can change content without any window event — a
            // page navigation, a dialog, an auto-refresh. Re-capture the SAME
            // window and compare a content fingerprint, and re-verify that the
            // same process still owns the window.
            let recapture: CompanionWindowCGImageCapture?
            do {
                recapture = try await CompanionScreenCaptureUtility.recaptureWindow(
                    matchingWindowID: windowCapture.windowID,
                    processIdentifiers: DesktopApplicationResolver.processIdentifiers(belongingTo: frontmostBundleURL)
                )
            } catch {
                recapture = nil
            }
            guard let recapture,
                  recapture.processIdentifier == windowCapture.processIdentifier,
                  observedWindow.contentStillMatches(DesktopWindowContentFingerprint.hash(of: recapture.image)) else {
                if retriesRemaining > 0 { return await describeScreen(intent: intent, retriesRemaining: retriesRemaining - 1) }
                return "读取期间页面内容已变化，这份旧观察不能回答当前画面。请待页面稳定再读。"
            }
            // Create numbering only after the slow vision call and reject changed
            // windows; final actions still revalidate the stored exact target.
            currentDescription = description
            describedTargets = Dictionary(uniqueKeysWithValues: presented.enumerated().map { ($0.offset + 1, $0.element) })
            screenHistory.append("\(Date().formatted())，\(observation.app)，问题：\(intent)，观察：\(result.description)")
            screenHistory = Array(screenHistory.suffix(4))
            print("[StepFunRealtimeTools] screen vision completed in \(result.elapsedMilliseconds) ms")
            let taskContext = coordinator.lastReceipt.map { "\n最近操作记录：\($0.toolOutput)" } ?? ""
            return "当前屏幕观察（数据）：\n\(result.description)\n可操作控件：\n\(rendered)\(taskContext)"
        } catch is CancellationError {
            return "屏幕读取已取消。"
        } catch {
            return "屏幕读取失败：\(error.localizedDescription)。本地控件：\n\(rendered)"
        }
    }

    private static func taskTarget(_ target: LocalPerceptionTargetCache.SnapshotTarget) -> DesktopTaskTarget {
        DesktopTaskTarget(id: target.id, label: target.label, source: target.source, box: target.globalBox, display: target.displayFrame)
    }

    private static func isWindowVisibilityConfirmation(_ intent: String) -> Bool {
        let normalized = DesktopActionStep.normalized(intent)
        let asksWhetherVisible = normalized.contains("看到") || normalized.contains("看见") || normalized.contains("能看")
        let asksForContent = normalized.contains("什么") || normalized.contains("内容") || normalized.contains("画面")
        let isQuestion = normalized.contains("吗") || normalized.contains("没") || normalized.contains("是否")
        return asksWhetherVisible && isQuestion && !asksForContent
    }

    private static func requiresRemoteVisualSemantics(_ intent: String) -> Bool {
        let normalized = DesktopActionStep.normalized(intent)
        let visualKeywords = [
            "图片", "照片", "图像", "图表", "图里", "颜色", "视觉", "壁纸",
            "视频", "外观", "长什么样", "形状", "画面细节", "这张图", "这个图"
        ]
        return visualKeywords.contains { normalized.contains($0) }
    }

    private func rejectedAction(_ detail: String) -> String {
        DesktopTaskReceipt(goal: "未执行的请求", status: "failed", actions: [], detail: detail, turnID: currentTurnID).toolOutput
    }

    private func executionContext() -> DesktopExecutionContext? {
        guard let app = NSWorkspace.shared.frontmostApplication, let identifier = app.bundleIdentifier else { return nil }
        return DesktopExecutionContext(app: identifier, processIdentifier: app.processIdentifier,
            windowID: currentWindowID(), contentVersion: contentVersion)
    }

    private func currentWindowID() -> Int? {
        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.first { ($0[kCGWindowOwnerPID as String] as? Int) == Int(processIdentifier)
            && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int
    }

    /// The live frame of a specific window, used to detect that the captured
    /// window moved or closed while a slow vision call was in flight.
    private static func currentFrameOfWindow(_ windowID: CGWindowID) -> CGRect? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) }),
              let boundsDictionary = windowInfo[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
    }
}

// A retired voice session may still call stop(). Its binding cannot pause or
// control tasks belonging to the replacement session.
@MainActor
private final class TaskSessionBinding: StepFunRealtimeToolHandling {
    private let router: StepFunRealtimeToolRouter
    private let sessionID: UUID
    init(router: StepFunRealtimeToolRouter, sessionID: UUID) {
        self.router = router
        self.sessionID = sessionID
    }
    var preservesTaskLifetime: Bool { true }
    var taskContext: String? { isCurrent ? router.taskContext : nil }
    private var isCurrent: Bool { router.isCurrentSession(sessionID) }
    func handleToolCall(name: String, argumentsJSON: String) async throws -> String {
        guard isCurrent else { return "语音连接已过期，未执行。" }
        return try await router.handleToolCall(name: name, argumentsJSON: argumentsJSON)
    }
    func interrupt() { if isCurrent { router.interrupt() } }
    func prepareForUserSpeech() { if isCurrent { router.prepareForUserSpeech() } }
    func beginUserTurn(_ turnID: String) { if isCurrent { router.beginUserTurn(turnID) } }
}
