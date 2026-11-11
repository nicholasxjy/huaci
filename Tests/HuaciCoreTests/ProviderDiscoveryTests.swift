import Foundation
import Testing
@testable import HuaciCore

private actor ProviderGate {
    private var entered = false
    private var started: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        started?.resume()
        started = nil
        await withCheckedContinuation { pending = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}

/// A separate transport-error fixture; the existing shared stub stays unchanged.
private final class OfflineModelsProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var offlineProject = false
    static var requestCount: Int { lock.withLock { count } }

    static func session(failProject: Bool = false) -> URLSession {
        lock.withLock {
            count = 0
            offlineProject = failProject
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineModelsProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isProject = request.url?.absoluteString.contains("loadCodeAssist") == true
        let fails = Self.lock.withLock {
            Self.count += 1
            return Self.offlineProject == isProject
        }
        if fails {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = isProject ? #"{"currentTier":{"id":"standard-tier"},"paidTier":{"id":"pro-tier"}}"#
                : #"{"models":{"gemini-3-flash":{}}}"#
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

extension TranslatorTests {
    @Suite(.timeLimit(.minutes(1))) struct ProviderDiscovery {
        static let load = #"{"currentTier":{"id":"standard-tier"},"paidTier":{"id":"pro-tier"}}"#

        @Test func projectAndModelsRefreshOnceOn401() async throws {
            let session = StubURLProtocol.session([
                .init(status: 401, body: ""),
                .init(status: 200, body: #"{"access_token":"at-2","expires_in":3600}"#),
                .init(status: 200, body: Self.load),
                .init(status: 401, body: ""),
                .init(status: 200, body: #"{"access_token":"at-3","expires_in":3600}"#),
                .init(status: 200, body: #"{"models":{"gemini-3-flash":{}}}"#),
            ])
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)
            let models = try await ModelCatalog.antigravity(auth: auth, session: session, backend: Antigravity.backend)
            #expect(models.map(\.id) == ["gemini-3-flash"])
            #expect(StubURLProtocol.requests.count == 6)
            #expect(StubURLProtocol.requests[2].request.value(forHTTPHeaderField: "Authorization") == "Bearer at-2")
            #expect(StubURLProtocol.requests[5].request.value(forHTTPHeaderField: "Authorization") == "Bearer at-3")
        }

        @Test func translationProjectAndOnboardingRefreshOn401() async throws {
            var tokens = TranslatorTests.freshTokens
            tokens.projectID = nil
            let session = StubURLProtocol.session([
                .init(status: 401, body: ""),
                .init(status: 200, body: #"{"access_token":"at-2","expires_in":3600}"#),
                .init(status: 200, body: #"{"allowedTiers":[{"id":"free-tier","isDefault":true}]}"#),
                .init(status: 401, body: ""),
                .init(status: 200, body: #"{"access_token":"at-3","expires_in":3600}"#),
                .init(status: 200, body: #"{"done":true,"response":{"cloudaicompanionProject":"new-project"}}"#),
                .init(status: 200, body: completedGeminiStream([[["text": "你好"]]])),
            ])
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(tokens), session: session)
            let translator = try AntigravityTranslator(auth: auth, model: "test", session: session, backend: Antigravity.backend)
            let request = TranslationRequest(text: "Hello", kind: .text, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
            #expect(try await translator.translate(request).translation == "你好")
            #expect(StubURLProtocol.requests.count == 7)
            #expect(StubURLProtocol.requests[2].request.value(forHTTPHeaderField: "Authorization") == "Bearer at-2")
            #expect(StubURLProtocol.requests[5].request.value(forHTTPHeaderField: "Authorization") == "Bearer at-3")
            #expect(try StubURLProtocol.bodyJSON(6)["project"] as? String == "new-project")
        }

        @Test(arguments: [400, 404, 500, 503, 408, 504])
        func unavailableDiscoveryKeepsStoredProjectUsable(_ status: Int) async throws {
            let session = StubURLProtocol.session([
                .init(status: status, body: "unavailable"),
                .init(status: 200, body: #"{"models":{"gemini-3-flash":{}}}"#),
            ])
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)
            let models = try await ModelCatalog.antigravity(auth: auth, session: session, backend: Antigravity.backend)
            #expect(models.map(\.id) == ["gemini-3-flash"])
            #expect(StubURLProtocol.requests.count == 2)
            #expect(try StubURLProtocol.bodyJSON(1)["project"] as? String == "proj-1")
        }

        @Test(arguments: [false, true])
        func exhaustedProjectAuthenticationDoesNotUseStoredProject(_ rejectedRefresh: Bool) async throws {
            let session = StubURLProtocol.session([
                .init(status: 401, body: ""),
                rejectedRefresh ? .init(status: 400, body: "invalid refresh token")
                    : .init(status: 200, body: #"{"access_token":"at-2","expires_in":3600}"#),
                .init(status: 401, body: ""),
            ])
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)
            await #expect {
                try await ModelCatalog.antigravity(auth: auth, session: session, backend: Antigravity.backend)
            } throws: { error in
                if rejectedRefresh {
                    guard case TranslationError.notConfigured = error else { return false }
                    return true
                }
                return error as? TranslationError == .unauthorized
            }
            #expect(StubURLProtocol.requests.count == (rejectedRefresh ? 2 : 3))
        }

        @Test(arguments: [429, 403])
        func unrelatedProjectFailureDoesNotUseStoredProject(_ status: Int) async throws {
            let session = StubURLProtocol.session([.init(status: status, body: "unavailable")])
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)
            await #expect(throws: HTTP.error(status: status, data: Data("unavailable".utf8))) {
                try await ModelCatalog.antigravity(auth: auth, session: session, backend: Antigravity.backend)
            }
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func unrelatedModelRejectionIsNotAnEntitlementRetry() async throws {
            let session = StubURLProtocol.session([
                .init(status: 200, body: Self.load),
                .init(status: 400, body: #"{"error":{"message":"FAILED_PRECONDITION"}}"#),
            ])
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)
            await #expect(throws: TranslationError.http(status: 400, message: "FAILED_PRECONDITION")) {
                try await ModelCatalog.antigravity(auth: auth, session: session, backend: Antigravity.backend)
            }
            #expect(StubURLProtocol.requests.count == 2)
        }

        @Test(arguments: [false, true])
        func projectNetworkFailureNeedsStoredProject(_ hasStoredProject: Bool) async throws {
            let session = OfflineModelsProtocol.session(failProject: true)
            var tokens = TranslatorTests.freshTokens
            if !hasStoredProject { tokens.projectID = nil }
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(tokens), session: session)
            if hasStoredProject {
                let models = try await ModelCatalog.antigravity(auth: auth, session: session, backend: Antigravity.backend)
                #expect(models.map(\.id) == ["gemini-3-flash"])
            } else {
                await #expect {
                    try await ModelCatalog.antigravity(auth: auth, session: session, backend: Antigravity.backend)
                } throws: { error in
                    guard case TranslationError.network = error else { return false }
                    return true
                }
            }
            #expect(OfflineModelsProtocol.requestCount == (hasStoredProject ? 2 : 1))
        }

        @Test func modelNetworkFailureIsNotRetried() async throws {
            let session = OfflineModelsProtocol.session()
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)
            await #expect {
                try await ModelCatalog.antigravity(auth: auth, session: session, backend: Antigravity.backend)
            } throws: { error in
                guard case TranslationError.network = error else { return false }
                return true
            }
            #expect(OfflineModelsProtocol.requestCount == 2)
        }

        @Test(arguments: [false, true])
        func cancellationDuringDiscoveryDoesNotRetry(_ duringModel: Bool) async throws {
            let gate = ProviderGate()
            var replies: [StubURLProtocol.Reply] = []
            if duringModel { replies.append(.init(status: 200, body: Self.load)) }
            replies.append(.init(status: 200, body: duringModel ? #"{"models":{}}"# : Self.load, beforeReply: { await gate.wait() }))
            let session = StubURLProtocol.session(replies)
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)
            let task = Task { try await ModelCatalog.antigravity(auth: auth, session: session, backend: Antigravity.backend) }
            await gate.waitUntilEntered()
            task.cancel()
            await gate.release()
            await #expect(throws: TranslationError.cancelled) { try await task.value }
            #expect(StubURLProtocol.requests.count == (duringModel ? 2 : 1))
        }

        @Test func simultaneousVersionCallsShareSuccessfulProbe() async throws {
            let session = StubURLProtocol.session([
                .init(status: 200, body: "version: 9.9.9\n", beforeReply: { try? await Task.sleep(nanoseconds: 30_000_000) }),
            ])
            let version = AntigravityVersion(session: session)
            let values = await withTaskGroup(of: String.self, returning: [String].self) { group in
                for _ in 0..<20 { group.addTask { await version.current() } }
                var results: [String] = []
                for await result in group { results.append(result) }
                return results
            }
            #expect(values.count == 20)
            #expect(values.allSatisfy { $0 == "9.9.9" })
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func versionFreshnessStartsWhenFetchSucceeds() async throws {
            let gate = ProviderGate()
            let clock = LockedValue(Date(timeIntervalSince1970: 100_000))
            let session = StubURLProtocol.session([
                .init(status: 200, body: "version: 9.9.9\n", beforeReply: { await gate.wait() }),
                .init(status: 200, body: "version: 10.0.0\n"),
            ])
            let version = AntigravityVersion(session: session, now: { clock.value })
            let task = Task { await version.current() }
            await gate.waitUntilEntered()
            clock.value = clock.value.addingTimeInterval(AntigravityVersion.maxAge / 2)
            await gate.release()
            #expect(await task.value == "9.9.9")
            clock.value = clock.value.addingTimeInterval(AntigravityVersion.maxAge / 2 + 1)
            #expect(await version.current() == "9.9.9")
            #expect(StubURLProtocol.requests.count == 1)
            clock.value = clock.value.addingTimeInterval(AntigravityVersion.maxAge / 2)
            #expect(await version.current() == "10.0.0")
            #expect(StubURLProtocol.requests.count == 2)
        }

        @Test func failedVersionProbeRetriesSoonWithoutStampingFreshness() async throws {
            let clock = LockedValue(Date(timeIntervalSince1970: 100_000))
            let session = StubURLProtocol.session([
                .init(status: 500, body: ""),
                .init(status: 200, body: "version: 9.9.9\n"),
                .init(status: 200, body: "not a manifest"),
                .init(status: 200, body: "version: 10.0.0\n"),
            ])
            let version = AntigravityVersion(session: session, now: { clock.value })
            #expect(await version.current() == AntigravityVersion.fallback)
            clock.value = clock.value.addingTimeInterval(AntigravityVersion.retryDelay - 1)
            #expect(await version.current() == AntigravityVersion.fallback)
            #expect(StubURLProtocol.requests.count == 1)
            clock.value = clock.value.addingTimeInterval(2)
            #expect(await version.current() == "9.9.9")
            clock.value = clock.value.addingTimeInterval(AntigravityVersion.maxAge + 1)
            #expect(await version.current() == "9.9.9")
            #expect(await version.current() == "9.9.9")
            #expect(StubURLProtocol.requests.count == 3)
            clock.value = clock.value.addingTimeInterval(AntigravityVersion.retryDelay + 1)
            #expect(await version.current() == "10.0.0")
            #expect(StubURLProtocol.requests.count == 4)
        }
    }
}
