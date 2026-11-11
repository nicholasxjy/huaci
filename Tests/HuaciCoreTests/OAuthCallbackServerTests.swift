import Darwin
import Foundation
import Testing
@testable import HuaciCore

@Suite(.timeLimit(.minutes(1)))
struct OAuthCallbackServerTests {
    @Test(arguments: ["path", "code", "state", "crlf"])
    func fragmentedRequestWaitsForCompleteHeaders(split: String) async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        defer { server.stop() }
        let client = try CallbackSocket(port: port)
        let request = "GET /cb?code=code-123&state=state-456 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let marker = ["path": "/c", "code": "code=code-", "state": "state=state-", "crlf": "Host: localhost\r\n\r"][split]!
        let bytes = Data(request.utf8)
        let boundary = bytes.range(of: Data(marker.utf8))!.upperBound
        try client.send(String(decoding: bytes.prefix(boundary), as: UTF8.self))
        try await Task.sleep(nanoseconds: 40_000_000)
        let early = client.readAvailable()
        #expect(early == nil, "An incomplete HTTP header must not receive a response")
        guard early == nil else { return }
        try client.send(String(decoding: bytes.dropFirst(boundary), as: UTF8.self))
        let response = try client.response()
        #expect(response.contains("200 OK"))
        let params = try await server.waitForCallback()
        #expect(params == ["code": "code-123", "state": "state-456"])
    }

    @Test func incidentalRequestsDoNotConsumeCallback() async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        defer { server.stop() }
        for target in ["/favicon.ico", "/cb", "/cb?code=incidental", "/cb?state=s", "/cb?error=access_denied",
                       "/cb?code=&state=s", "/cb?code=c&state=", "/cb?error=&state=s"] {
            let client = try CallbackSocket(port: port)
            try client.send("GET \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try client.response().contains("404 Not Found"))
        }
        let client = try CallbackSocket(port: port)
        try client.send("GET /cb?code=real&state=expected HTTP/1.1\r\nHost: localhost\r\n\r\n")
        _ = try client.response()
        #expect(try await server.waitForCallback() == ["code": "real", "state": "expected"])
    }

    @Test(arguments: ["code=forged&state=unvalidated", "error=access_denied&state=unvalidated"])
    func callbackCopyDoesNotClaimAuthenticationSucceeded(query: String) async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        defer { server.stop() }
        let client = try CallbackSocket(port: port)
        try client.send("GET /cb?\(query) HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let response = try client.response()
        #expect(response.contains("已收到授权回调，请返回划词查看登录结果。"))
        #expect(!response.contains("授权完成"))
        #expect(!response.contains("授权没有完成"))
        let expected = Dictionary(URLComponents(string: "/cb?\(query)")!.queryItems!.map { ($0.name, $0.value ?? "") },
                                  uniquingKeysWith: { first, _ in first })
        #expect(try await server.waitForCallback() == expected)
    }

    @Test func malformedAndOversizedRequestsDoNotConsumeCallback() async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        defer { server.stop() }
        for request in ["GET /cb?code=c&state=s\r\n\r\n", "POST /cb?code=c&state=s HTTP/1.1\r\n\r\n"] {
            let client = try CallbackSocket(port: port)
            try client.send(request)
            #expect(try client.response().contains("404 Not Found"))
        }
        let oversized = try CallbackSocket(port: port)
        try oversized.send("GET /cb?code=c&state=s HTTP/1.1\r\nX: " + String(repeating: "x", count: 16 * 1024))
        #expect(try oversized.response().contains("431 Request Header Fields Too Large"))
        let client = try CallbackSocket(port: port)
        try client.send("GET /cb?code=a%2Bb&code=ignored&state=s%26t HTTP/1.1\r\n\r\n")
        #expect(try client.response().contains("200 OK"))
        #expect(try await server.waitForCallback() == ["code": "a+b", "state": "s&t"])
    }

    @Test func truncatedRequestDoesNotConsumeCallback() async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        defer { server.stop() }
        let truncated = try CallbackSocket(port: port)
        try truncated.send("GET /cb?code=partial&state=s HTTP/1.1\r\n")
        truncated.endRequest()
        #expect(truncated.isClosed())
        let client = try CallbackSocket(port: port)
        try client.send("GET /cb?code=complete&state=s HTTP/1.1\r\n\r\n")
        _ = try client.response()
        #expect(try await server.waitForCallback() == ["code": "complete", "state": "s"])
    }

    @Test func stopClosesPartialConnectionsBeforeWaiting() async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        let client = try CallbackSocket(port: port)
        try client.send("GET /cb?code=unfinished")
        try await Task.sleep(nanoseconds: 40_000_000)
        server.stop()
        server.stop()
        #expect(client.isClosed())
        await #expect(throws: TranslationError.cancelled) { try await server.waitForCallback() }
    }

    @Test(arguments: [false, true])
    func cancellationClosesPartialConnections(cancelBeforeWaiting: Bool) async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        defer { server.stop() }
        let client = try CallbackSocket(port: port)
        try client.send("GET /cb?state=unfinished")
        let waiter = Task {
            if cancelBeforeWaiting { withUnsafeCurrentTask { $0?.cancel() } }
            return try await server.waitForCallback()
        }
        if !cancelBeforeWaiting {
            try await Task.sleep(nanoseconds: 40_000_000)
            waiter.cancel()
        }
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(client.isClosed())
    }

    @Test func oneWaiterAndOneStartAreEnforced() async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        defer { server.stop() }
        #expect(port != 0)
        await #expect(throws: OAuthCallbackServer.LifecycleError.alreadyStarted) { try await server.start() }
        let first = Task { try await server.waitForCallback() }
        try await Task.sleep(nanoseconds: 40_000_000)
        await #expect(throws: OAuthCallbackServer.LifecycleError.alreadyWaiting) { try await server.waitForCallback() }
        let client = try CallbackSocket(port: port)
        try client.send("GET /cb?code=c&state=s HTTP/1.1\r\n\r\n")
        #expect(try client.response().contains("200 OK"))
        #expect(try await first.value == ["code": "c", "state": "s"])
        await #expect(throws: OAuthCallbackServer.LifecycleError.alreadyWaiting) { try await server.waitForCallback() }
        await #expect(throws: OAuthCallbackServer.LifecycleError.alreadyStarted) { try await server.start() }
    }

    @Test func stopResumesPendingWaiter() async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        _ = try await server.start()
        let waiter = Task { try await server.waitForCallback() }
        try await Task.sleep(nanoseconds: 40_000_000)
        server.stop()
        await #expect(throws: TranslationError.cancelled) { try await waiter.value }
    }

    @Test func callbackClosesOtherPendingConnections() async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        defer { server.stop() }
        let partial = try CallbackSocket(port: port)
        try partial.send("GET /cb?code=unfinished")
        let callback = try CallbackSocket(port: port)
        try callback.send("GET /cb?code=c&state=s HTTP/1.1\r\n\r\n")
        #expect(try callback.response().contains("200 OK"))
        #expect(try await server.waitForCallback() == ["code": "c", "state": "s"])
        #expect(partial.isClosed())
    }

    @Test func stopWithoutStartingIsTerminal() async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        server.stop()
        await #expect(throws: TranslationError.cancelled) { try await server.start() }
        await #expect(throws: TranslationError.cancelled) { try await server.waitForCallback() }
    }

    @Test func stoppingDuringStartupAlwaysCompletes() async {
        for _ in 0..<20 {
            let server = OAuthCallbackServer(port: 0, path: "/cb")
            let start = Task { try await server.start() }
            await Task.yield()
            server.stop()
            // Startup may win the race; either result must terminate, and stop remains terminal.
            _ = await start.result
            await #expect(throws: TranslationError.cancelled) { try await server.waitForCallback() }
        }
    }

    @Test func cancellingStartupStopsListener() async {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let start = Task { try await server.start() }
        start.cancel()
        _ = await start.result
        await #expect(throws: TranslationError.cancelled) { try await server.waitForCallback() }
    }

    @Test func idleConnectionsAreBoundedAndExpire() async throws {
        let server = OAuthCallbackServer(port: 0, path: "/cb")
        let port = try await server.start()
        defer { server.stop() }
        var clients: [CallbackSocket] = []
        for _ in 0..<16 {
            let client = try CallbackSocket(port: port)
            try client.send("GET /cb?code=partial")
            clients.append(client)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        let excess = try CallbackSocket(port: port)
        #expect(excess.isClosed())
        try await Task.sleep(nanoseconds: 5_100_000_000)
        for client in clients { #expect(client.isClosed()) }
        let callback = try CallbackSocket(port: port)
        try callback.send("GET /cb?code=c&state=s HTTP/1.1\r\n\r\n")
        #expect(try callback.response().contains("200 OK"))
        #expect(try await server.waitForCallback() == ["code": "c", "state": "s"])
    }
}

private final class CallbackSocket {
    private let descriptor: Int32

    init(port: UInt16) throws {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    deinit { Darwin.close(descriptor) }

    func send(_ text: String) throws {
        let data = Array(text.utf8)
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { throw POSIXError(.EPIPE) }
                sent += count
            }
        }
    }

    /// nil means the connection remains open without a response.
    func readAvailable() -> String? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return nil }
        return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
    }

    func endRequest() { Darwin.shutdown(descriptor, SHUT_WR) }

    func isClosed() -> Bool {
        var byte: UInt8 = 0
        let count = Darwin.recv(descriptor, &byte, 1, 0)
        return count == 0 || (count < 0 && errno == ECONNRESET)
    }

    func response() throws -> String {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count == 0 { return String(decoding: result, as: UTF8.self) }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            result.append(contentsOf: bytes.prefix(count))
            if let end = result.range(of: Data("\r\n\r\n".utf8))?.upperBound {
                let header = String(decoding: result[..<end], as: UTF8.self)
                let lengthLine = header.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Length: ") }
                if let lengthLine, let length = Int(lengthLine.dropFirst("Content-Length: ".count)),
                   result.count >= end + length {
                    return String(decoding: result, as: UTF8.self)
                }
            }
        }
    }
}
