import Foundation
import Testing
@testable import HuaciCore

final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    var tokens: OAuthTokens?

    init(_ tokens: OAuthTokens? = nil) {
        self.tokens = tokens
    }

    func load() -> OAuthTokens? { tokens }

    @discardableResult
    func save(_ tokens: OAuthTokens) -> Bool {
        self.tokens = tokens
        return true
    }

    func clear() { tokens = nil }
}

/// Unsigned JWT; only the payload matters to the client.
func jwt(_ claims: [String: Any]) -> String {
    func encode(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(["alg": "none"])).\(encode(claims)).sig"
}

func queryItems(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

func formBody(_ index: Int) -> [String: String] {
    let body = String(decoding: StubURLProtocol.requests[index].body, as: UTF8.self)
    var components = URLComponents()
    components.percentEncodedQuery = body
    return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

struct OAuthTests {
    @Test func pkceChallengeMatchesRFC7636Example() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedPKCEIsUniqueAndURLSafe() {
        let first = PKCE.generate()
        let second = PKCE.generate()
        #expect(first.verifier != second.verifier)
        #expect((43...128).contains(first.verifier.count))
        #expect(first.verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
        #expect(PKCE(verifier: first.verifier).challenge == first.challenge)
    }

    @Test func chatGPTAuthorizationURL() throws {
        let url = OAuthProvider.chatGPT.authorizationURL(pkce: PKCE(verifier: String(repeating: "a", count: 43)),
                                                         state: "s1", redirectURI: OAuthProvider.chatGPT.redirectURI(port: 1455))
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/oauth/authorize?"))
        let query = queryItems(url)
        #expect(query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(query["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "s1")
        #expect(query["scope"]?.contains("offline_access") == true)
        #expect(query["codex_cli_simplified_flow"] == "true")
    }

    @Test func antigravityAuthorizationURLRequestsOfflineAccess() {
        let provider = OAuthProvider.antigravity
        let url = provider.authorizationURL(pkce: .generate(), state: "s", redirectURI: provider.redirectURI(port: 51121))
        #expect(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
        let query = queryItems(url)
        #expect(query["redirect_uri"] == "http://localhost:51121/oauth-callback")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        #expect(query["scope"]?.contains("https://www.googleapis.com/auth/cloud-platform") == true)
    }

    @Test func antigravityClientComesFromInfoPlistThenEnvironment() {
        let info = ["HuaciAntigravityClientID": "plist-id", "HuaciAntigravityClientSecret": " "]
        let environment = ["ANTIGRAVITY_CLIENT_ID": "env-id", "ANTIGRAVITY_CLIENT_SECRET": "env-secret"]
        #expect(AntigravityAuth.configuredValue(infoKey: "HuaciAntigravityClientID", environmentKey: "ANTIGRAVITY_CLIENT_ID",
                                                info: info, environment: environment) == "plist-id")
        // A blank plist value falls through to the environment.
        #expect(AntigravityAuth.configuredValue(infoKey: "HuaciAntigravityClientSecret", environmentKey: "ANTIGRAVITY_CLIENT_SECRET",
                                                info: info, environment: environment) == "env-secret")
        #expect(AntigravityAuth.configuredValue(infoKey: "HuaciAntigravityClientID", environmentKey: "ANTIGRAVITY_CLIENT_ID",
                                                info: nil, environment: [:]) == "")
    }

    @Test func chatGPTAccountComesFromIDTokenClaims() async throws {
        let idToken = jwt([
            "email": "me@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1", "chatgpt_plan_type": "plus"],
        ])
        let response = OAuthTokenResponse(accessToken: "at", refreshToken: "rt", idToken: idToken, expiresIn: 3600)
        let account = try await OAuthProvider.chatGPT.resolveAccount(response, .shared)
        #expect(account.email == "me@example.com")
        #expect(account.accountID == "acct-1")
    }
}

extension TranslatorTests {
    /// Sign-in and token refresh against a real loopback callback server; the
    /// token endpoint is stubbed.
    @Suite struct OAuthFlow {
        static let provider = OAuthProvider(
            name: "Test",
            authorizeURL: URL(string: "https://auth.example.com/authorize")!,
            tokenURL: URL(string: "https://auth.example.com/token")!,
            clientID: "client-1",
            clientSecret: "secret-1",
            scopes: ["a", "b"],
            callbackPort: 0,
            callbackPath: "/cb",
            resolveAccount: { response, _ in OAuthAccount(email: "user@example.com", accountID: "id-\(response.accessToken)") }
        )

        /// Plays the browser: follows the redirect URI from the authorization
        /// URL with the given query.
        static func browser(_ query: @escaping @Sendable ([String: String]) -> String) -> @Sendable (URL) async -> Void {
            { url in
                let params = queryItems(url)
                let callback = URL(string: "\(params["redirect_uri"]!)?\(query(params))")!
                _ = try? await URLSession(configuration: .ephemeral).data(from: callback)
            }
        }

        let tokenReply = StubURLProtocol.Reply(status: 200, body: #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600}"#)

        @Test func signInExchangesCodeFromLoopbackCallback() async throws {
            let store = MemoryCredentialStore()
            let auth = OAuthSession(provider: Self.provider, store: store, session: StubURLProtocol.session([tokenReply]))

            let tokens = try await auth.signIn(open: Self.browser { "code=code-1&state=\($0["state"]!)" })

            #expect(tokens.accessToken == "at-1")
            #expect(tokens.refreshToken == "rt-1")
            #expect(tokens.email == "user@example.com")
            #expect(tokens.accountID == "id-at-1")
            #expect(tokens.expiresAt > Date().addingTimeInterval(3000))
            #expect(store.tokens == tokens)

            let sent = try #require(StubURLProtocol.requests.first)
            #expect(sent.request.url == Self.provider.tokenURL)
            #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            let form = formBody(0)
            #expect(form["grant_type"] == "authorization_code")
            #expect(form["code"] == "code-1")
            #expect(form["client_id"] == "client-1")
            #expect(form["client_secret"] == "secret-1")
            #expect(form["redirect_uri"]?.hasSuffix("/cb") == true)
            #expect(form["code_verifier"].map { PKCE(verifier: $0).challenge } != nil)
        }

        @Test func signInSendsVerifierMatchingChallenge() async throws {
            let auth = OAuthSession(provider: Self.provider, store: MemoryCredentialStore(), session: StubURLProtocol.session([tokenReply]))
            let challenge = LockedValue<String?>(nil)
            let browser = Self.browser { "code=c&state=\($0["state"]!)" }

            _ = try await auth.signIn { url in
                challenge.value = queryItems(url)["code_challenge"]
                await browser(url)
            }

            let verifier = try #require(formBody(0)["code_verifier"])
            #expect(PKCE(verifier: verifier).challenge == challenge.value)
        }

        @Test func signInRejectsMismatchedState() async throws {
            let store = MemoryCredentialStore()
            let auth = OAuthSession(provider: Self.provider, store: store, session: StubURLProtocol.session([tokenReply]))

            await #expect(throws: TranslationError.self) {
                try await auth.signIn(open: Self.browser { _ in "code=code-1&state=forged" })
            }
            #expect(StubURLProtocol.requests.isEmpty)
            #expect(store.tokens == nil)
        }

        @Test func signInReportsDeniedAuthorization() async throws {
            let auth = OAuthSession(provider: Self.provider, store: MemoryCredentialStore(), session: StubURLProtocol.session([]))
            do {
                _ = try await auth.signIn(open: Self.browser { "error=access_denied&state=\($0["state"]!)" })
                Issue.record("Expected sign-in to fail")
            } catch let error as TranslationError {
                #expect(error.userMessage.contains("access_denied"))
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func cancellingSignInStopsWaiting() async throws {
            let auth = OAuthSession(provider: Self.provider, store: MemoryCredentialStore(), session: StubURLProtocol.session([]))
            let task = Task { try await auth.signIn(open: { _ in }) }
            try await Task.sleep(nanoseconds: 200_000_000)
            task.cancel()
            await #expect(throws: TranslationError.cancelled) { try await task.value }
        }

        @Test func signInWithoutClientFailsBeforeOpeningBrowser() async throws {
            let unconfigured = OAuthProvider(
                name: "Test", authorizeURL: Self.provider.authorizeURL, tokenURL: Self.provider.tokenURL,
                clientID: "", clientSecret: nil, scopes: [], callbackPort: 0, callbackPath: "/cb",
                resolveAccount: { _, _ in OAuthAccount() }
            )
            #expect(!unconfigured.isClientConfigured)
            let auth = OAuthSession(provider: unconfigured, store: MemoryCredentialStore(), session: StubURLProtocol.session([]))
            let opened = LockedValue(false)

            await #expect(throws: TranslationError.self) {
                try await auth.signIn { _ in opened.value = true }
            }
            #expect(!opened.value)
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func missingSignInIsReported() async throws {
            let auth = OAuthSession(provider: Self.provider, store: MemoryCredentialStore(), session: StubURLProtocol.session([]))
            await #expect(throws: TranslationError.notConfigured("请先在设置中登录 Test。")) {
                try await auth.validTokens()
            }
        }

        @Test func freshTokensAreUsedWithoutRefresh() async throws {
            let tokens = OAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600))
            let auth = OAuthSession(provider: Self.provider, store: MemoryCredentialStore(tokens), session: StubURLProtocol.session([]))
            #expect(try await auth.validTokens() == tokens)
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func expiredTokensAreRefreshedAndSaved() async throws {
            let old = OAuthTokens(accessToken: "old", refreshToken: "rt-0", expiresAt: Date().addingTimeInterval(-10),
                                  email: "user@example.com", accountID: "acct", projectID: "proj")
            let store = MemoryCredentialStore(old)
            // Google omits refresh_token on refresh; the old one must be kept.
            let auth = OAuthSession(provider: Self.provider, store: store, session: StubURLProtocol.session([
                .init(status: 200, body: #"{"access_token":"new","expires_in":3600}"#),
            ]))

            let tokens = try await auth.validTokens()

            #expect(tokens.accessToken == "new")
            #expect(tokens.refreshToken == "rt-0")
            #expect(tokens.email == "user@example.com")
            #expect(tokens.accountID == "acct")
            #expect(tokens.projectID == "proj")
            #expect(store.tokens == tokens)
            let form = formBody(0)
            #expect(form["grant_type"] == "refresh_token")
            #expect(form["refresh_token"] == "rt-0")
            #expect(form["client_id"] == "client-1")
        }

        @Test func concurrentCallersShareOneRefresh() async throws {
            let old = OAuthTokens(accessToken: "old", refreshToken: "rt", expiresAt: .distantPast)
            let auth = OAuthSession(provider: Self.provider, store: MemoryCredentialStore(old), session: StubURLProtocol.session([
                .init(status: 200, body: #"{"access_token":"new","refresh_token":"rt-2","expires_in":3600}"#),
            ]))

            async let first = auth.validTokens()
            async let second = auth.validTokens()
            let results = try await [first, second]

            #expect(results.allSatisfy { $0.accessToken == "new" })
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func revokedRefreshTokenRequiresSignInAgain() async throws {
            let old = OAuthTokens(accessToken: "old", refreshToken: "rt", expiresAt: .distantPast)
            let auth = OAuthSession(provider: Self.provider, store: MemoryCredentialStore(old), session: StubURLProtocol.session([
                .init(status: 400, body: #"{"error":"invalid_grant","error_description":"Token has been revoked."}"#),
            ]))
            await #expect(throws: TranslationError.notConfigured("Test 登录已失效，请在设置中重新登录。")) {
                try await auth.validTokens()
            }
        }

        @Test func signOutClearsTokens() async throws {
            let store = MemoryCredentialStore(OAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture))
            let auth = OAuthSession(provider: Self.provider, store: store, session: StubURLProtocol.session([]))
            await auth.signOut()
            #expect(store.tokens == nil)
        }
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
