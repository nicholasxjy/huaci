import Foundation
import Network

/// One-shot HTTP listener on the loopback interface that receives the OAuth
/// redirect and returns its query parameters.
final class OAuthCallbackServer: @unchecked Sendable {
    private let port: UInt16
    private let path: String
    private let queue = DispatchQueue(label: "app.huaci.oauth-callback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var result: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?

    init(port: UInt16, path: String) {
        self.port = port
        self.path = path
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        } catch {
            throw Self.bindError(port)
        }
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [weak self, port] state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener.port?.rawValue ?? port) }
                case .failed, .waiting:
                    listener.cancel()
                    if resumed.set() { continuation.resume(throwing: Self.bindError(port)) }
                case .cancelled:
                    if resumed.set() { continuation.resume(throwing: TranslationError.cancelled) }
                    self?.finish(.failure(TranslationError.cancelled))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the redirect; cancelling the task stops the server.
    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
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
            finish(.failure(CancellationError()))
            stop()
        }
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(with: outcome)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let target = data.flatMap { Self.requestTarget(String(decoding: $0, as: UTF8.self)) }
            guard let target, let components = URLComponents(string: target), components.path == self.path else {
                Self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            let params = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                    uniquingKeysWith: { first, _ in first })
            let succeeded = params["error"] == nil && params["code"] != nil
            Self.respond(connection, status: "200 OK", body: succeeded
                ? "授权完成，可以关闭此页面并返回划词。"
                : "授权没有完成，请返回划词重试。")
            self.finish(.success(params))
        }
    }

    /// The target of `GET <target> HTTP/1.1`.
    static func requestTarget(_ request: String) -> String? {
        let line = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>划词</title></head>
        <body style="font-family:-apple-system,sans-serif;padding:48px;text-align:center"><p>\(body)</p></body></html>
        """
        let payload = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func bindError(_ port: UInt16) -> TranslationError {
        .notConfigured("无法监听本机端口 \(port) 接收登录回调，可能被其他程序（例如正在登录的 Codex CLI）占用。请关闭后重试。")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns true only for the first call.
    func set() -> Bool {
        lock.withLock {
            defer { isSet = true }
            return !isSet
        }
    }
}
