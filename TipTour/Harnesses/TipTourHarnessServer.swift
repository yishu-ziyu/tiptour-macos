//
//  TipTourHarnessServer.swift
//  TipTour
//
//  Local-only HTTP harness for external orchestrators such as TipTour.
//  The server deliberately exposes TipTour's existing local engine instead
//  of embedding any external agent runtime inside the macOS app.
//

import AppKit
import Foundation
import Network

@MainActor
final class TipTourHarnessServer {
    private let tipTourEngine: TipTourEngine
    private let port: NWEndpoint.Port
    private let activityReporter: @MainActor (String) -> Void
    private var listener: NWListener?
    private var restartAttempts = 0
    private let maximumRestartAttempts = 5
    private let maximumRequestBytes = 1_048_576
    private var intentionallyStopped = false
    private var listenerReady = false

    init(
        tipTourEngine: TipTourEngine,
        port: UInt16 = 19474,
        activityReporter: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.tipTourEngine = tipTourEngine
        self.port = NWEndpoint.Port(rawValue: port) ?? 19474
        self.activityReporter = activityReporter
    }

    func start() {
        guard listener == nil else { return }
        PipelineLogStore.shared.record(
            category: "harness",
            name: "listener_start",
            status: "started",
            metadata: ["port": String(port.rawValue)]
        )

        do {
            let parameters = NWParameters.tcp
            if let loopbackAddress = IPv4Address("127.0.0.1") {
                parameters.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(loopbackAddress),
                    port: port
                )
            }

            let listener = try NWListener(using: parameters)
            intentionallyStopped = false
            listenerReady = false
            self.listener = listener
            configureAndStart(listener)
            scheduleStartupReadinessCheck(for: listener)
        } catch {
            print("[Harness] failed to start local harness: \(error)")
            PipelineLogStore.shared.record(
                category: "harness",
                name: "listener_start",
                status: "failed",
                message: error.localizedDescription,
                metadata: ["port": String(port.rawValue)]
            )
            scheduleRestart()
        }
    }

    func stop() {
        intentionallyStopped = true
        listenerReady = false
        listener?.cancel()
        listener = nil
        PipelineLogStore.shared.record(
            category: "harness",
            name: "listener_stop",
            status: "ok",
            metadata: ["port": String(port.rawValue)]
        )
    }

    private func configureAndStart(_ listener: NWListener) {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handle(connection: connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listenerReady = true
                    self.restartAttempts = 0
                    print("[Harness] TipTour local harness listening on http://127.0.0.1:\(self.port)")
                    PipelineLogStore.shared.record(
                        category: "harness",
                        name: "listener_ready",
                        status: "ok",
                        metadata: ["port": String(self.port.rawValue)]
                    )
                case .waiting(let error):
                    self.listenerReady = false
                    print("[Harness] local harness waiting: \(error)")
                    PipelineLogStore.shared.record(
                        category: "harness",
                        name: "listener_waiting",
                        status: "warning",
                        message: error.localizedDescription,
                        metadata: ["port": String(self.port.rawValue)]
                    )
                case .failed(let error):
                    self.listenerReady = false
                    print("[Harness] local harness failed: \(error)")
                    PipelineLogStore.shared.record(
                        category: "harness",
                        name: "listener_failed",
                        status: "failed",
                        message: error.localizedDescription,
                        metadata: ["port": String(self.port.rawValue)]
                    )
                    if self.listener === listener {
                        self.listener?.cancel()
                        self.listener = nil
                    }
                    if !self.intentionallyStopped {
                        self.scheduleRestart()
                    }
                case .cancelled:
                    self.listenerReady = false
                    guard !self.intentionallyStopped else { return }
                    print("[Harness] local harness cancelled unexpectedly")
                    PipelineLogStore.shared.record(
                        category: "harness",
                        name: "listener_cancelled",
                        status: "warning",
                        metadata: ["port": String(self.port.rawValue)]
                    )
                    if self.listener === listener {
                        self.listener = nil
                    }
                    self.scheduleRestart()
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
    }

    private func scheduleStartupReadinessCheck(for listener: NWListener) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.listener === listener,
                      !self.listenerReady,
                      !self.intentionallyStopped else {
                    return
                }

                print("[Harness] local harness did not become ready; restarting")
                PipelineLogStore.shared.record(
                    category: "harness",
                    name: "listener_startup_check",
                    status: "warning",
                    message: "Listener did not become ready within the startup window.",
                    metadata: ["port": String(self.port.rawValue)]
                )
                self.listener?.cancel()
                self.listener = nil
                self.scheduleRestart()
            }
        }
    }

    private func scheduleRestart() {
        guard restartAttempts < maximumRestartAttempts else {
            print("[Harness] local harness restart limit reached")
            PipelineLogStore.shared.record(
                category: "harness",
                name: "listener_restart",
                status: "failed",
                message: "Restart limit reached.",
                metadata: [
                    "port": String(port.rawValue),
                    "attempts": String(restartAttempts)
                ]
            )
            return
        }

        restartAttempts += 1
        let attempt = restartAttempts
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Task { @MainActor in
                guard let self, self.listener == nil else { return }
                print("[Harness] retrying local harness start (attempt \(attempt))")
                PipelineLogStore.shared.record(
                    category: "harness",
                    name: "listener_restart",
                    status: "started",
                    metadata: [
                        "port": String(self.port.rawValue),
                        "attempt": String(attempt)
                    ]
                )
                self.start()
            }
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        receiveHTTPData(from: connection, buffer: Data())
    }

    private func receiveHTTPData(from connection: NWConnection, buffer requestData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                print("[Harness] receive failed: \(error)")
                PipelineLogStore.shared.record(
                    category: "harness",
                    name: "receive",
                    status: "failed",
                    message: error.localizedDescription
                )
                connection.cancel()
                return
            }

            var updatedRequestData = requestData
            if let data {
                updatedRequestData.append(data)
            }

            if updatedRequestData.count > self.maximumRequestBytes {
                Task { @MainActor in
                    let denied = self.jsonResponse(
                        ["ok": false, "reason": "request_too_large"],
                        statusCode: 413,
                        statusText: "Content Too Large"
                    )
                    PipelineLogStore.shared.record(
                        category: "harness", name: "request", status: "rejected",
                        metadata: ["status_code": "413"]
                    )
                    connection.send(content: denied.data, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                return
            }

            if self.requestDataIsComplete(updatedRequestData) || isComplete {
                Task { @MainActor in
                    await self.respond(to: updatedRequestData, on: connection)
                }
            } else {
                self.receiveHTTPData(from: connection, buffer: updatedRequestData)
            }
        }
    }

    private func requestDataIsComplete(_ requestData: Data) -> Bool {
        guard let headerRange = requestData.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }

        let headerData = requestData[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let contentLength = headerText
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line -> Int? in
                let value = line.split(separator: ":", maxSplits: 1).dropFirst().joined()
                return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            } ?? 0

        let bodyStartIndex = headerRange.upperBound
        return requestData.count - bodyStartIndex >= contentLength
    }

    private func respond(to requestData: Data, on connection: NWConnection) async {
        let request = parseRequest(requestData)
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.host,
              allowedHosts.contains(host),
              request.origin == nil || request.origin == "http://\(host)" else {
            let denied = jsonResponse(
                ["ok": false, "reason": "invalid_request_origin"],
                statusCode: 403,
                statusText: "Forbidden"
            )
            PipelineLogStore.shared.record(
                category: "harness", name: "request", status: "rejected",
                metadata: ["status_code": "403"]
            )
            connection.send(content: denied.data, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        PipelineLogStore.shared.record(
            category: "harness",
            name: "request",
            status: "received",
            metadata: [
                "method": request.method,
                "path": request.path,
                "body_bytes": String(request.body.count)
            ]
        )

        let response: HarnessHTTPResponse
        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/v1/health"):
            response = jsonResponse(["ok": true, "service": "tiptour-harness"])
        case ("GET", "/v1/capabilities"):
            activityReporter("TipTour checking TipTour capabilities")
            response = jsonResponse([
                "ok": true,
                "tools": [
                    "tiptour.agent_contract",
                    "tiptour.observe",
                    "tiptour.visual_context",
                    "tiptour.resolve_highlight_source",
                    "tiptour.screenshots",
                    "tiptour.skills",
                    "tiptour.active_skill",
                    "tiptour.targets",
                    "tiptour.ground_target",
                    "tiptour.act",
                    "tiptour.plan_next_action",
                    "tiptour.action_history",
                    "tiptour.submit_workflow_plan",
                    "tiptour.tasks",
                    "tiptour.task_status",
                    "tiptour.task_events",
                    "tiptour.cancel_task"
                ],
                "single_action": true,
                "local_tasks": true,
                "task_planning": false,
                "task_storage": "memory",
                "trace_metadata": TipTourActionTrace.metadataKey,
                "transport": "localhost-http"
            ])
        case ("GET", "/v1/agent-contract"), ("GET", "/v1/agent_contract"):
            activityReporter("TipTour reading TipTour agent contract")
            response = encodableResponse(tipTourEngine.agentContract())
        case ("GET", "/v1/observe"):
            activityReporter("TipTour observing the desktop")
            response = encodableResponse(tipTourEngine.observe())
        case ("GET", "/v1/visual-context"), ("GET", "/v1/visual_context"), ("GET", "/v1/observation-snapshot"):
            activityReporter("TipTour asking TipTour for visual context")
            let visualContext = await tipTourEngine.visualContext(
                intent: nil,
                app: nil,
                requestedMode: "auto",
                reason: "observe",
                targetLabel: nil,
                targetID: nil,
                targetMark: nil,
                refresh: false,
                traceID: nil
            )
            response = encodableResponse(visualContext)
        case ("POST", "/v1/visual-context"), ("POST", "/v1/visual_context"), ("POST", "/v1/observation-snapshot"):
            activityReporter("TipTour asking TipTour for visual context")
            response = await handleVisualContextRequest(body: request.body)
        case ("GET", "/v1/resolve-highlight-source"), ("GET", "/v1/resolve_highlight_source"):
            activityReporter("TipTour resolving the highlighted source")
            response = encodableResponse(tipTourEngine.resolveHighlightSource(TipTourHighlightSourceRequest()))
        case ("POST", "/v1/resolve-highlight-source"), ("POST", "/v1/resolve_highlight_source"):
            activityReporter("TipTour resolving the highlighted source")
            response = await handleResolveHighlightSourceRequest(body: request.body)
        case ("GET", "/v1/screenshots"), ("GET", "/v1/screenshot"):
            activityReporter("TipTour reading screenshots")
            let screenshots = await tipTourEngine.screenshots()
            response = encodableResponse(screenshots)
        case ("GET", "/v1/skills"):
            activityReporter("TipTour reading app skills")
            response = encodableResponse(tipTourEngine.skills())
        case ("GET", "/v1/skills/active"), ("GET", "/v1/active-skill"), ("GET", "/v1/active_skill"):
            activityReporter("TipTour reading the active app skill")
            response = encodableResponse(tipTourEngine.activeSkill())
        case ("GET", "/v1/targets"), ("GET", "/v1/grounding-targets"):
            activityReporter("TipTour checking screen targets")
            response = await handleTargetsRequest()
        case ("POST", "/v1/ground-target"), ("POST", "/v1/ground_target"):
            activityReporter("TipTour grounding a visible target")
            response = await handleGroundTargetRequest(body: request.body)
        case ("GET", "/v1/action-history"), ("GET", "/v1/action_history"):
            activityReporter("TipTour checking recent actions")
            response = encodableResponse(tipTourEngine.actionHistory())
        case ("GET", "/v1/tasks"):
            activityReporter("TipTour checking TipTour tasks")
            response = encodableResponse(tipTourEngine.longTasks())
        case ("POST", "/v1/tasks"):
            activityReporter("TipTour starting a TipTour task")
            response = await handleStartTaskRequest(body: request.body)
        case ("POST", "/v1/act"), ("POST", "/v1/action"):
            activityReporter("TipTour executing one action")
            response = await handlePlanNextActionRequest(body: request.body)
        case ("POST", "/v1/plan-next-action"), ("POST", "/v1/plan_next_action"):
            activityReporter("TipTour planning the next action")
            response = await handlePlanNextActionRequest(body: request.body)
        case ("POST", "/v1/workflow-plan"), ("POST", "/v1/submit_workflow_plan"):
            activityReporter("TipTour submitting one action")
            response = await handleWorkflowPlanRequest(body: request.body)
        default:
            if let taskResponse = await handleTaskPathRequest(request) {
                response = taskResponse
            } else {
                response = jsonResponse(
                    ["ok": false, "reason": "not_found"],
                    statusCode: 404,
                    statusText: "Not Found"
                )
            }
        }

        PipelineLogStore.shared.record(
            category: "harness",
            name: "response",
            status: response.statusCode >= 400 ? "failed" : "ok",
            metadata: [
                "method": request.method,
                "path": request.path,
                "status_code": String(response.statusCode),
                "status_text": response.statusText,
                "response_bytes": String(response.bodyByteCount)
            ]
        )

        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleTargetsRequest() async -> HarnessHTTPResponse {
        let targets = await tipTourEngine.localPerceptionTargets(
            refresh: true,
            reason: "harness /v1/targets"
        )
        return encodableResponse(targets)
    }

    private func handleVisualContextRequest(body: Data) async -> HarnessHTTPResponse {
        do {
            let request = body.isEmpty
                ? HarnessVisualContextRequest()
                : try JSONDecoder().decode(HarnessVisualContextRequest.self, from: body)
            let result = await tipTourEngine.visualContext(
                intent: request.normalizedIntent,
                app: request.app,
                requestedMode: request.normalizedVisualContextMode,
                reason: request.normalizedReason,
                targetLabel: request.normalizedTargetLabel,
                targetID: request.normalizedTargetID,
                targetMark: request.normalizedTargetMark,
                refresh: request.shouldRefreshTargets,
                traceID: request.normalizedTraceID
            )
            return encodableResponse(result)
        } catch {
            PipelineLogStore.shared.record(
                category: "harness",
                name: "visual_context_decode",
                status: "failed",
                message: error.localizedDescription,
                metadata: ["body_bytes": String(body.count)]
            )
            return jsonResponse(
                [
                    "ok": false,
                    "reason": "invalid_request",
                    "message": error.localizedDescription
                ],
                statusCode: 400,
                statusText: "Bad Request"
            )
        }
    }

    private func handleResolveHighlightSourceRequest(body: Data) async -> HarnessHTTPResponse {
        do {
            let request = body.isEmpty
                ? TipTourHighlightSourceRequest()
                : try JSONDecoder().decode(TipTourHighlightSourceRequest.self, from: body)
            return encodableResponse(tipTourEngine.resolveHighlightSource(request))
        } catch {
            PipelineLogStore.shared.record(
                category: "harness",
                name: "resolve_highlight_source_decode",
                status: "failed",
                message: error.localizedDescription,
                metadata: ["body_bytes": String(body.count)]
            )
            return jsonResponse(
                [
                    "ok": false,
                    "reason": "invalid_request",
                    "message": error.localizedDescription
                ],
                statusCode: 400,
                statusText: "Bad Request"
            )
        }
    }

    private func handleGroundTargetRequest(body: Data) async -> HarnessHTTPResponse {
        do {
            let request = try JSONDecoder().decode(HarnessGroundTargetRequest.self, from: body)
            guard request.hasGroundingInput else {
                PipelineLogStore.shared.record(
                    category: "harness",
                    name: "ground_target_decode",
                    status: "rejected",
                    message: "Ground target request did not include query, goal, target_id, or target_mark.",
                    metadata: ["body_bytes": String(body.count)]
                )
                return jsonResponse(
                    [
                        "ok": false,
                        "reason": "missing_target_query",
                        "message": "POST /v1/ground-target requires query, goal, target_label, target_id, or target_mark."
                    ],
                    statusCode: 400,
                    statusText: "Bad Request"
                )
            }

            let result = await tipTourEngine.groundTarget(
                goal: request.normalizedGoal,
                app: request.app,
                actionType: request.normalizedActionType,
                targetLabel: request.normalizedTargetLabel,
                targetID: request.normalizedTargetID,
                targetMark: request.normalizedTargetMark,
                refresh: request.shouldRefreshTargets,
                allowScreenshotPlanning: request.shouldAllowScreenshotPlanning
            )
            return encodableResponse(result)
        } catch {
            PipelineLogStore.shared.record(
                category: "harness",
                name: "ground_target_decode",
                status: "failed",
                message: error.localizedDescription,
                metadata: ["body_bytes": String(body.count)]
            )
            return jsonResponse(
                [
                    "ok": false,
                    "reason": "invalid_request",
                    "message": error.localizedDescription
                ],
                statusCode: 400,
                statusText: "Bad Request"
            )
        }
    }


    private func handlePlanNextActionRequest(body: Data) async -> HarnessHTTPResponse {
        do {
            let request = try JSONDecoder().decode(HarnessPlanNextActionRequest.self, from: body)
            let result = await tipTourEngine.runPointerAction(request.pointerActionRequest)
            if request.shouldIncludeTargets {
                return encodableResponse(result)
            }
            return encodableResponse(HarnessCompactPlanNextActionResponse(result))
        } catch {
            PipelineLogStore.shared.record(
                category: "harness",
                name: "plan_next_action_decode",
                status: "failed",
                message: error.localizedDescription,
                metadata: ["body_bytes": String(body.count)]
            )
            return jsonResponse(
                [
                    "ok": false,
                    "reason": "invalid_request",
                    "message": error.localizedDescription
                ],
                statusCode: 400,
                statusText: "Bad Request"
            )
        }
    }

    private func handleWorkflowPlanRequest(body: Data) async -> HarnessHTTPResponse {
        do {
            let request = try JSONDecoder().decode(HarnessWorkflowPlanRequest.self, from: body)
            let plan = request.toWorkflowPlan()
            let result = await tipTourEngine.submitSingleActionWorkflowPlanAndWait(plan)
            return encodableResponse(result)
        } catch {
            PipelineLogStore.shared.record(
                category: "harness",
                name: "workflow_plan_decode",
                status: "failed",
                message: error.localizedDescription,
                metadata: ["body_bytes": String(body.count)]
            )
            return jsonResponse(
                [
                    "ok": false,
                    "reason": "invalid_request",
                    "message": error.localizedDescription
                ],
                statusCode: 400,
                statusText: "Bad Request"
            )
        }
    }

    private func handleStartTaskRequest(body: Data) async -> HarnessHTTPResponse {
        do {
            let request = try JSONDecoder().decode(HarnessLongTaskStartRequest.self, from: body)
            guard let prompt = request.normalizedPrompt else {
                PipelineLogStore.shared.record(
                    category: "harness",
                    name: "task_start_decode",
                    status: "rejected",
                    message: "Task start request did not include a prompt.",
                    metadata: ["body_bytes": String(body.count)]
                )
                return jsonResponse(
                    [
                        "ok": false,
                        "reason": "missing_prompt",
                        "message": "POST /v1/tasks requires prompt, goal, task, or title."
                    ],
                    statusCode: 400,
                    statusText: "Bad Request"
                )
            }

            let result = tipTourEngine.startLongTask(
                title: request.title,
                prompt: prompt,
                app: request.app,
                steps: request.longTaskSteps,
                traceID: request.normalizedTraceID
            )
            return encodableResponse(result)
        } catch {
            PipelineLogStore.shared.record(
                category: "harness",
                name: "task_start_decode",
                status: "failed",
                message: error.localizedDescription,
                metadata: ["body_bytes": String(body.count)]
            )
            return jsonResponse(
                [
                    "ok": false,
                    "reason": "invalid_request",
                    "message": error.localizedDescription
                ],
                statusCode: 400,
                statusText: "Bad Request"
            )
        }
    }

    private func handleTaskPathRequest(_ request: HarnessHTTPRequest) async -> HarnessHTTPResponse? {
        let pathParts = request.path.split(separator: "/").map(String.init)
        guard pathParts.count >= 3,
              pathParts[0] == "v1",
              pathParts[1] == "tasks" else {
            return nil
        }

        let taskID = pathParts[2]
        if pathParts.count == 3, request.method == "GET" {
            activityReporter("TipTour checking TipTour task \(taskID)")
            return encodableResponse(tipTourEngine.longTask(id: taskID))
        }

        if pathParts.count == 4,
           pathParts[3] == "events",
           request.method == "GET" {
            activityReporter("TipTour reading TipTour task events")
            return encodableResponse(tipTourEngine.longTaskEvents(id: taskID))
        }

        if pathParts.count == 4,
           pathParts[3] == "cancel",
           request.method == "POST" {
            activityReporter("TipTour cancelling TipTour task")
            return encodableResponse(tipTourEngine.cancelLongTask(id: taskID))
        }

        return jsonResponse(
            ["ok": false, "reason": "not_found"],
            statusCode: 404,
            statusText: "Not Found"
        )
    }

    private func parseRequest(_ requestData: Data) -> HarnessHTTPRequest {
        guard let headerRange = requestData.range(of: Data("\r\n\r\n".utf8)) else {
            return HarnessHTTPRequest(method: "", path: "", host: nil, origin: nil, body: Data())
        }

        let headerData = requestData[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let requestLine = headerText.split(separator: "\r\n").first ?? ""
        let requestLineParts = requestLine.split(separator: " ")
        let method = requestLineParts.first.map(String.init) ?? ""
        let rawPath = requestLineParts.dropFirst().first.map(String.init) ?? ""
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let headerLines = headerText.components(separatedBy: "\r\n").dropFirst()
        let hostValues = headerLines.compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "host" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let originValues = headerLines.compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "origin" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let body = requestData[headerRange.upperBound...]

        return HarnessHTTPRequest(
            method: method,
            path: path,
            host: hostValues.count == 1 ? hostValues[0] : nil,
            origin: originValues.count <= 1 ? originValues.first : "invalid",
            body: Data(body)
        )
    }

    private func encodableResponse<T: Encodable>(_ value: T) -> HarnessHTTPResponse {
        do {
            let data = try JSONEncoder().encode(value)
            return httpResponse(body: data)
        } catch {
            return jsonResponse(
                ["ok": false, "reason": "encoding_failed"],
                statusCode: 500,
                statusText: "Internal Server Error"
            )
        }
    }

    private func jsonResponse(
        _ payload: [String: Any],
        statusCode: Int = 200,
        statusText: String = "OK"
    ) -> HarnessHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
        return httpResponse(body: data, statusCode: statusCode, statusText: statusText)
    }

    private func httpResponse(
        body: Data,
        statusCode: Int = 200,
        statusText: String = "OK"
    ) -> HarnessHTTPResponse {
        var responseData = Data()
        responseData.append(Data("HTTP/1.1 \(statusCode) \(statusText)\r\n".utf8))
        responseData.append(Data("Content-Type: application/json\r\n".utf8))
        responseData.append(Data("Content-Length: \(body.count)\r\n".utf8))
        responseData.append(Data("Connection: close\r\n".utf8))
        responseData.append(Data("\r\n".utf8))
        responseData.append(body)
        return HarnessHTTPResponse(
            data: responseData,
            statusCode: statusCode,
            statusText: statusText,
            bodyByteCount: body.count
        )
    }
}

private struct HarnessHTTPRequest {
    let method: String
    let path: String
    let host: String?
    let origin: String?
    let body: Data
}

private struct HarnessHTTPResponse {
    let data: Data
    let statusCode: Int
    let statusText: String
    let bodyByteCount: Int
}

private struct HarnessVisualContextRequest: Decodable {
    let intent: String?
    let goal: String?
    let task: String?
    let reason: String?
    let app: String?
    let visualContext: String?
    let visual_context: String?
    let mode: String?
    let targetLabel: String?
    let target_label: String?
    let label: String?
    let query: String?
    let targetID: String?
    let target_id: String?
    let targetMark: Int?
    let target_mark: Int?
    let refresh: Bool?
    let refreshTargets: Bool?
    let refresh_targets: Bool?
    let traceID: String?
    let trace_id: String?

    init() {
        self.intent = nil
        self.goal = nil
        self.task = nil
        self.reason = nil
        self.app = nil
        self.visualContext = nil
        self.visual_context = nil
        self.mode = nil
        self.targetLabel = nil
        self.target_label = nil
        self.label = nil
        self.query = nil
        self.targetID = nil
        self.target_id = nil
        self.targetMark = nil
        self.target_mark = nil
        self.refresh = nil
        self.refreshTargets = nil
        self.refresh_targets = nil
        self.traceID = nil
        self.trace_id = nil
    }

    var normalizedIntent: String? {
        firstNonEmpty(intent, goal, task)
    }

    var normalizedReason: String? {
        firstNonEmpty(reason)
    }

    var normalizedVisualContextMode: String? {
        firstNonEmpty(visualContext, visual_context, mode)
    }

    var normalizedTargetLabel: String? {
        firstNonEmpty(query, targetLabel, target_label, label)
    }

    var normalizedTargetID: String? {
        firstNonEmpty(targetID, target_id)
    }

    var normalizedTargetMark: Int? {
        targetMark ?? target_mark
    }

    var shouldRefreshTargets: Bool {
        refreshTargets ?? refresh_targets ?? refresh ?? true
    }

    var normalizedTraceID: String? {
        firstNonEmpty(traceID, trace_id)
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private struct HarnessPlanNextActionRequest: Decodable {
    let goal: String
    let app: String?
    let type: String?
    let action: String?
    let label: String?
    let targetLabel: String?
    let target_label: String?
    let targetID: String?
    let target_id: String?
    let targetMark: Int?
    let target_mark: Int?
    let execute: Bool?
    let allowScreenshotPlanning: Bool?
    let allow_screenshot_planning: Bool?
    let validateStateChange: Bool?
    let validate_state_change: Bool?
    let includeTargets: Bool?
    let include_targets: Bool?
    let debug: Bool?
    let traceID: String?
    let trace_id: String?

    var pointerActionRequest: PointerActionRequest {
        PointerActionRequest(
            goal: goal,
            app: app,
            actionType: WorkflowStep.StepType.normalized(from: type ?? action),
            targetLabel: targetLabel ?? target_label ?? label,
            targetID: targetID ?? target_id,
            targetMark: targetMark ?? target_mark,
            execute: execute ?? true,
            allowScreenshotPlanning: allowScreenshotPlanning ?? allow_screenshot_planning ?? false,
            validateStateChange: validateStateChange ?? validate_state_change ?? true,
            traceID: traceID ?? trace_id
        )
    }

    var shouldIncludeTargets: Bool {
        includeTargets ?? include_targets ?? debug ?? false
    }
}

private struct HarnessCompactPlanNextActionResponse: Encodable {
    let ok: Bool
    let traceID: String
    let reason: String?
    let message: String?
    let activeApp: String?
    let plannedStep: TipTourEnginePlannedActionStep?
    let submission: TipTourEngineSubmissionResult?
    let workflowOutcome: TipTourEngineWorkflowOutcome?
    let validation: TipTourEngineActionValidation?
    let attempts: [TipTourEngineActionAttempt]
    let repaired: Bool
    let targetCount: Int

    private enum CodingKeys: String, CodingKey {
        case ok
        case traceID = "trace_id"
        case reason
        case message
        case activeApp
        case plannedStep
        case submission
        case workflowOutcome
        case validation
        case attempts
        case repaired
        case targetCount
    }

    init(_ result: TipTourEnginePlanNextActionResult) {
        self.ok = result.ok
        self.traceID = result.traceID
        self.reason = result.reason
        self.message = result.message
        self.activeApp = result.activeApp
        self.plannedStep = result.plannedStep
        self.submission = result.submission
        self.workflowOutcome = result.workflowOutcome
        self.validation = result.validation
        self.attempts = result.attempts
        self.repaired = result.repaired
        self.targetCount = result.targets.count
    }
}

private struct HarnessGroundTargetRequest: Decodable {
    let query: String?
    let intent: String?
    let goal: String?
    let app: String?
    let type: String?
    let action: String?
    let targetLabel: String?
    let target_label: String?
    let label: String?
    let targetID: String?
    let target_id: String?
    let targetMark: Int?
    let target_mark: Int?
    let refresh: Bool?
    let refreshTargets: Bool?
    let refresh_targets: Bool?
    let allowScreenshotPlanning: Bool?
    let allow_screenshot_planning: Bool?

    var hasGroundingInput: Bool {
        normalizedTargetLabel != nil
            || firstNonEmpty(intent, goal) != nil
            || normalizedTargetID != nil
            || normalizedTargetMark != nil
    }

    var normalizedGoal: String {
        firstNonEmpty(intent, goal, query, targetLabel, target_label, label, targetID, target_id)
            ?? targetMark.map { "target \($0)" }
            ?? target_mark.map { "target \($0)" }
            ?? "ground visible target"
    }

    var normalizedActionType: WorkflowStep.StepType {
        WorkflowStep.StepType.normalized(from: type ?? action)
    }

    var normalizedTargetLabel: String? {
        firstNonEmpty(query, targetLabel, target_label, label)
    }

    var normalizedTargetID: String? {
        firstNonEmpty(targetID, target_id)
    }

    var normalizedTargetMark: Int? {
        targetMark ?? target_mark
    }

    var shouldRefreshTargets: Bool {
        refreshTargets ?? refresh_targets ?? refresh ?? true
    }

    var shouldAllowScreenshotPlanning: Bool {
        allowScreenshotPlanning ?? allow_screenshot_planning ?? false
    }


    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private struct HarnessWorkflowPlanRequest: Decodable {
    let goal: String
    let app: String?
    let traceID: String?
    let trace_id: String?
    let steps: [HarnessWorkflowStepRequest]

    func toWorkflowPlan() -> WorkflowPlan {
        WorkflowPlan(
            goal: goal,
            app: app,
            steps: steps.enumerated().map { index, step in
                step.toWorkflowStep(index: index)
            },
            traceID: traceID ?? trace_id
        )
    }
}

private struct HarnessLongTaskStartRequest: Decodable {
    let title: String?
    let prompt: String?
    let goal: String?
    let task: String?
    let app: String?
    let steps: [HarnessWorkflowStepRequest]?
    let traceID: String?
    let trace_id: String?

    var normalizedPrompt: String? {
        let candidate = prompt ?? goal ?? task ?? title
        let trimmedCandidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedCandidate.isEmpty ? nil : trimmedCandidate
    }

    var longTaskSteps: [TipTourLongTaskStep] {
        let taskGoal = normalizedPrompt ?? "Local task"
        return (steps ?? []).enumerated().map { index, step in
            step.toLongTaskStep(
                index: index,
                defaultGoal: taskGoal
            )
        }
    }

    var normalizedTraceID: String? {
        let candidate = traceID ?? trace_id
        let trimmedCandidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedCandidate.isEmpty ? nil : trimmedCandidate
    }
}

private struct HarnessWorkflowStepRequest: Decodable {
    let id: String?
    let type: String?
    let action: String?
    let label: String?
    let targetLabel: String?
    let target_label: String?
    let targetID: String?
    let target_id: String?
    let targetMark: Int?
    let target_mark: Int?
    let key: String?
    let shortcut: String?
    let value: String?
    let text: String?
    let direction: String?
    let amount: Int?
    let by: String?
    let hint: String?
    let targetContext: String?
    let target_context: String?
    let title: String?
    let settleDelayMs: Int?
    let settle_delay_ms: Int?
    let refreshTargetsAfter: Bool?
    let refresh_targets_after: Bool?
    let point_2d: [Int]?
    let box_2d: [Int]?
    let screenNumber: Int?
    let screen: Int?

    func toWorkflowStep(index: Int) -> WorkflowStep {
        let normalizedPointBox = point_2d.flatMap { point -> [Int]? in
            guard point.count == 2 else { return nil }
            return [point[0], point[1], point[0], point[1]]
        }

        return WorkflowStep(
            id: id ?? "harness_step_\(index + 1)",
            type: WorkflowStep.StepType.normalized(from: type ?? action),
            label: label ?? targetLabel ?? target_label ?? key ?? shortcut,
            targetID: targetID ?? target_id,
            targetMark: targetMark ?? target_mark,
            value: value ?? text,
            direction: direction,
            amount: amount,
            by: by,
            targetContext: WorkflowStep.TargetContext.normalized(from: targetContext ?? target_context),
            hint: hint ?? "",
            hintX: nil,
            hintY: nil,
            box2DNormalized: box_2d ?? normalizedPointBox,
            screenNumber: screenNumber ?? screen
        )
    }

    func toLongTaskStep(index: Int, defaultGoal: String) -> TipTourLongTaskStep {
        let workflowStep = toWorkflowStep(index: index)
        let actionLabelCandidates = [
            label,
            targetLabel,
            target_label,
            key,
            shortcut,
            value,
            text,
            workflowStep.type.rawValue
        ]
        let actionLabel = actionLabelCandidates
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? workflowStep.type.rawValue
        let stepTitle = title ?? hint ?? "Step \(index + 1)"
        let stepGoal = hint ?? defaultGoal
        let settleDelay = max(0, settleDelayMs ?? settle_delay_ms ?? 0)
        let shouldRefreshTargets = refreshTargetsAfter ?? refresh_targets_after ?? false
        return TipTourLongTaskStep(
            title: stepTitle,
            goal: stepGoal,
            actionLabel: String(actionLabel.prefix(120)),
            workflowStep: workflowStep,
            settleDelayMilliseconds: settleDelay,
            refreshTargetsAfter: shouldRefreshTargets
        )
    }
}
