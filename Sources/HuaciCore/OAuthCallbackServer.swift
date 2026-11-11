import Foundation
import Network

/// One-shot HTTP listener on the loopback interface that receives the OAuth
/// redirect and returns its query parameters.
final class OAuthCallbackServer: @unchecked Sendable {
    enum LifecycleError: Error { case alreadyStarted, alreadyWaiting }

    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumConnections = 16
    private static let connectionLifetime: TimeInterval = 5

    private let port: UInt16
    private let path: String
    private let expectedState: String?
    private let queue = DispatchQueue(label: "app.huaci.oauth-callback")
    private let lock = NSLock()
    private var started = false
    private var waitClaimed = false
    private var callbackClaimed = false
    private var listener: NWListener?
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var result: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var connections: [ObjectIdentifier: (connection: NWConnection, deadline: DispatchWorkItem)] = [:]

    init(port: UInt16, path: String, expectedState: String? = nil) {
        self.port = port
        self.path = path
        self.expectedState = expectedState
    }

    /// Starts listening once and returns the bound port.
    func start() async throws -> UInt16 {
        try lock.withLock {
            guard !started else { throw LifecycleError.alreadyStarted }
            guard result == nil else { throw TranslationError.cancelled }
            started = true
        }
        return try await withTaskCancellationHandler {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
            } catch {
                finish(.failure(Self.bindError(port)))
                throw Self.bindError(port)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let continuation = self.lock.withLock {
                        defer { self.startWaiter = nil }
                        return self.startWaiter
                    }
                    continuation?.resume(returning: listener?.port?.rawValue ?? self.port)
                case .failed, .waiting:
                    self.finish(.failure(Self.bindError(self.port)))
                case .cancelled:
                    self.finish(.failure(TranslationError.cancelled))
                default:
                    break
                }
            }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard result == nil else {
                    lock.unlock()
                    listener.cancel()
                    continuation.resume(throwing: TranslationError.cancelled)
                    return
                }
                self.listener = listener
                startWaiter = continuation
                lock.unlock()
                listener.start(queue: queue)
            }
        } onCancel: {
            self.stop()
        }
    }

    /// One caller may await the redirect; cancelling that task stops the server.
    func waitForCallback() async throws -> [String: String] {
        try lock.withLock {
            guard !waitClaimed else { throw LifecycleError.alreadyWaiting }
            waitClaimed = true
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func stop() {
        finish(.failure(TranslationError.cancelled))
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let waiter = self.waiter
        self.waiter = nil
        let startWaiter = self.startWaiter
        self.startWaiter = nil
        let listener = self.listener
        self.listener = nil
        let connections = Array(self.connections.values)
        self.connections.removeAll()
        lock.unlock()
        listener?.cancel()
        for entry in connections {
            entry.deadline.cancel()
            entry.connection.cancel()
        }
        if let startWaiter {
            switch outcome {
            case .failure(let error): startWaiter.resume(throwing: error)
            case .success: startWaiter.resume(throwing: TranslationError.cancelled)
            }
        }
        waiter?.resume(with: outcome)
    }

    private func handle(_ connection: NWConnection) {
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let connection else { return }
            self?.close(connection)
        }
        let accepted = lock.withLock {
            guard result == nil, connections.count < Self.maximumConnections else { return false }
            connections[ObjectIdentifier(connection)] = (connection, deadline)
            return true
        }
        guard accepted else { connection.cancel(); return }
        queue.asyncAfter(deadline: .now() + Self.connectionLifetime, execute: deadline)
        connection.start(queue: queue)
        receive(connection, buffered: Data())
    }

    private func close(_ connection: NWConnection) {
        let entry = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
        entry?.deadline.cancel()
        connection.cancel()
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumHeaderBytes + 1 - buffered.count) {
            [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard self.lock.withLock({ self.connections[ObjectIdentifier(connection)] != nil }) else { return }
            let bytes = buffered + (data ?? Data())
            if let end = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound {
                guard end <= Self.maximumHeaderBytes else {
                    self.respond(connection, status: "431 Request Header Fields Too Large", body: "Request too large")
                    return
                }
                self.handleRequest(connection, header: Data(bytes[..<end]))
            } else if bytes.count >= Self.maximumHeaderBytes {
                self.respond(connection, status: "431 Request Header Fields Too Large", body: "Request too large")
            } else if error != nil || complete {
                self.close(connection)
            } else {
                self.receive(connection, buffered: bytes)
            }
        }
    }

    private func handleRequest(_ connection: NWConnection, header: Data) {
        guard let request = String(data: header, encoding: .utf8),
              let target = Self.requestTarget(request),
              let components = URLComponents(string: target), components.path == path else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        let params = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                uniquingKeysWith: { first, _ in first })
        guard params["state"]?.isEmpty == false,
              params["code"]?.isEmpty == false || params["error"]?.isEmpty == false else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        if let expectedState, params["state"] != expectedState {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        let claimed = lock.withLock {
            guard result == nil, !callbackClaimed else { return false }
            callbackClaimed = true
            return true
        }
        guard claimed else { close(connection); return }
        // Deliver after sending so caller cleanup cannot truncate the browser response.
        respond(connection, status: "200 OK", body: "已收到授权回调，请返回划词查看登录结果。") {
            self.finish(.success(params))
        }
    }

    /// The target of a complete `GET <target> HTTP/1.x` request line.
    static func requestTarget(_ request: String) -> String? {
        guard let end = request.range(of: "\r\n") else { return nil }
        let parts = request[..<end.lowerBound].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
        return String(parts[1])
    }

    private func respond(_ connection: NWConnection, status: String, body: String, completion: (() -> Void)? = nil) {
        let html = """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>划词</title></head>
        <body style="font-family:-apple-system,sans-serif;padding:48px;text-align:center"><p>\(body)</p></body></html>
        """
        let payload = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
            completion?()
        })
    }

    private static func bindError(_ port: UInt16) -> TranslationError {
        .notConfigured("无法监听本机端口 \(port) 接收登录回调，可能被其他程序（例如正在登录的 Codex CLI）占用。请关闭后重试。")
    }
}
