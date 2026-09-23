import Foundation
import Network

/// The host's own, independent state readback service.
///
/// It binds 127.0.0.1:19476 inside the app process and serves exactly two
/// endpoints, so an acceptance runner can prove the app's side effects without
/// reading pixels:
///
/// * `GET  /state` → JSON written by the store from real UI callbacks
/// * `POST /reset` → resets test semantics (keeps `page_views`)
///
/// Anything else is a 404. One request per connection (`Connection: close`).
/// Nothing here launches, activates or focuses any app.
final class StateServer {
    static let shared = StateServer()

    static let portNumber: UInt16 = 19476
    static let host = "127.0.0.1"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.yishuziyu.her.cua-host.state-server")

    /// Strong references to in-flight request sessions; otherwise a session
    /// would be deallocated while its receive loop is still pending.
    private var sessions: [HTTPSession] = []
    private let sessionsLock = NSLock()

    private init() {}

    func startIfNeeded() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(Self.host),
                port: NWEndpoint.Port(rawValue: Self.portNumber)!)
            let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.portNumber)!)
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    print("CuaHost state service failed on \(Self.host):\(Self.portNumber): \(error)")
                }
            }
            newListener.start(queue: queue)
            listener = newListener
            print("CuaHost state service ready on \(Self.host):\(Self.portNumber) (/state, /reset)")
        } catch {
            print("CuaHost state service could not start on \(Self.host):\(Self.portNumber): \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = HTTPSession(connection: connection)
        session.onFinish = { [weak self, weak session] in
            guard let self, let session else { return }
            self.sessionsLock.lock()
            self.sessions.removeAll { $0 === session }
            self.sessionsLock.unlock()
        }
        sessionsLock.lock()
        sessions.append(session)
        sessionsLock.unlock()
        session.receiveMore()
    }
}

private final class HTTPSession {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.yishuziyu.her.cua-host.connection")
    private var buffer = Data()
    private let maxHeadBytes = 64 * 1024

    /// Called once the connection is done so the owner can drop its strong
    /// reference. Idempotent from the caller's perspective.
    var onFinish: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
    }

    func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > self.maxHeadBytes {
                    self.respond(status: 431, body: #"{"error":"request head too large"}"#)
                    return
                }
                if self.tryHandleRequest() {
                    return
                }
            }
            if isComplete || error != nil {
                self.cancel()
                return
            }
            self.receiveMore()
        }
    }

    /// Attempts to answer one buffered request. Returns true once the response
    /// has been sent and the connection may be closed.
    private func tryHandleRequest() -> Bool {
        guard let headRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }
        let head = String(decoding: buffer[..<headRange.lowerBound], as: UTF8.self)
        let bodyStart = headRange.upperBound

        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            respond(status: 400, body: #"{"error":"malformed request line"}"#)
            return true
        }
        let tokens = requestLine.split(whereSeparator: { $0 == " " })
        guard tokens.count >= 2 else {
            respond(status: 400, body: #"{"error":"malformed request line"}"#)
            return true
        }
        let method = tokens[0].uppercased()
        let rawPath = String(tokens[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            contentLength = Int(value) ?? 0
        }
        // Wait for the full body before answering (clients may split writes).
        if buffer.count - bodyStart < contentLength {
            return false
        }
        buffer.removeSubrange(0..<(bodyStart + contentLength))

        let store = HostStore.shared
        switch (method, path) {
        case ("GET", "/state"):
            respond(status: 200, body: store.stateJSON)
        case ("POST", "/reset"):
            store.reset()
            respond(status: 200, body: store.stateJSON)
        default:
            respond(status: 404, body: #"{"error":"not found"}"#)
        }
        return true
    }

    private func respond(status: Int, body: String) {
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(for: status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.utf8.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + Data(body.utf8), completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    private func cancel() {
        connection.cancel()
        onFinish?()
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 431: return "Request Header Fields Too Large"
        default: return "Status \(status)"
        }
    }
}
