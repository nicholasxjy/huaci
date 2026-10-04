import CryptoKit
import Foundation

// MARK: - PKCE

/// Proof Key for Code Exchange (RFC 7636, S256).
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func generate() -> PKCE {
        PKCE(verifier: Base64URL.encode(randomBytes(64)))
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// Reads JWT claims without verifying the signature; the token came straight
/// from the issuer over TLS and is only used for display and routing.
enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let data = Base64URL.decode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Tokens

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var email: String?
    /// ChatGPT workspace/account id sent as `ChatGPT-Account-Id`.
    public var accountID: String?
    /// Google Cloud project used by Antigravity requests.
    public var projectID: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date,
                email: String? = nil, accountID: String? = nil, projectID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
        self.accountID = accountID
        self.projectID = projectID
    }
}

public struct OAuthTokenResponse: Decodable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresIn: Double?

    public init(accessToken: String, refreshToken: String?, idToken: String?, expiresIn: Double?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresIn = expiresIn
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }

    /// `expires_in`, else the access token's `exp` claim, else one hour.
    func expiry(now: Date) -> Date {
        if let expiresIn { return now.addingTimeInterval(expiresIn) }
        if let exp = JWT.claims(accessToken)?["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        return now.addingTimeInterval(3600)
    }
}

/// Account details looked up once after sign-in.
public struct OAuthAccount: Equatable, Sendable {
    public var email: String?
    public var accountID: String?
    public var projectID: String?

    public init(email: String? = nil, accountID: String? = nil, projectID: String? = nil) {
        self.email = email
        self.accountID = accountID
        self.projectID = projectID
    }
}

// MARK: - Provider

/// An OAuth client registration with a loopback redirect.
public struct OAuthProvider: Sendable {
    public typealias AccountResolver = @Sendable (OAuthTokenResponse, URLSession) async throws -> OAuthAccount

    public let name: String
    public let authorizeURL: URL
    public let tokenURL: URL
    public let clientID: String
    public let clientSecret: String?
    public let scopes: [String]
    /// Fixed by the client registration; 0 picks a free port (tests only).
    public let callbackPort: UInt16
    public let callbackPath: String
    public let extraAuthorizeParameters: [URLQueryItem]
    public let resolveAccount: AccountResolver

    public init(name: String, authorizeURL: URL, tokenURL: URL, clientID: String, clientSecret: String?,
                scopes: [String], callbackPort: UInt16, callbackPath: String,
                extraAuthorizeParameters: [URLQueryItem] = [], resolveAccount: @escaping AccountResolver) {
        self.name = name
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.callbackPort = callbackPort
        self.callbackPath = callbackPath
        self.extraAuthorizeParameters = extraAuthorizeParameters
        self.resolveAccount = resolveAccount
    }

    /// False when the build carries no client registration (see README).
    public var isClientConfigured: Bool { !clientID.isEmpty }

    public func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)\(callbackPath)"
    }

    public func authorizationURL(pkce: PKCE, state: String, redirectURI: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ] + extraAuthorizeParameters
        // `+` in values must be escaped for form-style query parsers.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

// MARK: - Credential storage

public protocol CredentialStore: AnyObject, Sendable {
    func load() -> OAuthTokens?
    @discardableResult func save(_ tokens: OAuthTokens) -> Bool
    func clear()
}

/// Tokens as JSON in one Keychain item.
public final class KeychainCredentialStore: CredentialStore {
    private let keychain: Keychain
    private let key: Keychain.Key

    public init(keychain: Keychain, key: Keychain.Key) {
        self.keychain = keychain
        self.key = key
    }

    public func load() -> OAuthTokens? {
        guard let json = keychain.read(key) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
    }

    @discardableResult
    public func save(_ tokens: OAuthTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return keychain.write(String(decoding: data, as: UTF8.self), for: key)
    }

    public func clear() {
        keychain.delete(key)
    }
}

// MARK: - Session

/// Browser sign-in and token refresh for one provider. Refreshes are
/// serialized so concurrent requests share one token exchange.
public actor OAuthSession {
    public nonisolated let provider: OAuthProvider
    private let store: CredentialStore
    private let session: URLSession
    private var refreshTask: Task<OAuthTokens, Error>?

    /// Tokens are refreshed this long before they expire.
    static let refreshMargin: TimeInterval = 120
    static let signInTimeout: UInt64 = 300

    public init(provider: OAuthProvider, store: CredentialStore, session: URLSession = .shared) {
        self.provider = provider
        self.store = store
        self.session = session
    }

    public nonisolated var tokens: OAuthTokens? { store.load() }

    /// Opens the authorization page through `open` and waits for the loopback
    /// redirect, then exchanges the code and stores the tokens.
    @discardableResult
    public func signIn(open: @escaping @Sendable (URL) async -> Void) async throws -> OAuthTokens {
        try checkClient()
        let server = OAuthCallbackServer(port: provider.callbackPort, path: provider.callbackPath)
        let port = try await server.start()
        defer { server.stop() }

        let pkce = PKCE.generate()
        let state = Base64URL.encode(PKCE.randomBytes(24))
        let redirectURI = provider.redirectURI(port: port)
        await open(provider.authorizationURL(pkce: pkce, state: state, redirectURI: redirectURI))

        let params: [String: String]
        do {
            params = try await withTimeout(seconds: Self.signInTimeout) { try await server.waitForCallback() }
        } catch TranslationError.timeout {
            throw TranslationError.notConfigured("等待浏览器授权超时，请重新登录。")
        }
        guard params["state"] == state else {
            throw TranslationError.notConfigured("登录校验失败（state 不匹配），请重试。")
        }
        if let error = params["error"] {
            let detail = params["error_description"].map { "\(error)：\($0)" } ?? error
            throw TranslationError.notConfigured("\(provider.name) 授权失败：\(detail)")
        }
        guard let code = params["code"], !code.isEmpty else {
            throw TranslationError.notConfigured("\(provider.name) 没有返回授权码，请重试。")
        }

        var form = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", provider.clientID),
            ("code_verifier", pkce.verifier),
        ]
        if let secret = provider.clientSecret { form.append(("client_secret", secret)) }
        let response = try await requestTokens(form)
        guard let refreshToken = response.refreshToken else {
            throw TranslationError.notConfigured("\(provider.name) 没有返回 refresh token，请重新登录。")
        }
        let account = try await provider.resolveAccount(response, session)
        let tokens = OAuthTokens(accessToken: response.accessToken, refreshToken: refreshToken,
                                 expiresAt: response.expiry(now: Date()), email: account.email,
                                 accountID: account.accountID, projectID: account.projectID)
        refreshTask?.cancel()
        refreshTask = nil
        guard store.save(tokens) else {
            throw TranslationError.notConfigured("登录信息保存到钥匙串失败，请重试。")
        }
        return tokens
    }

    public func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        store.clear()
    }

    /// Stored tokens, refreshed first when expiring or when `forceRefresh` is
    /// set (after the API rejected the current access token).
    public func validTokens(forceRefresh: Bool = false) async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let tokens = store.load() else {
            throw TranslationError.notConfigured("请先在设置中登录 \(provider.name)。")
        }
        guard forceRefresh || tokens.expiresAt.timeIntervalSinceNow < Self.refreshMargin else { return tokens }

        let task = Task { try await self.refresh(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func checkClient() throws {
        guard provider.isClientConfigured else {
            throw TranslationError.notConfigured("此版本没有配置 \(provider.name) 的 OAuth 客户端，无法登录。请按 README 配置后重新打包。")
        }
    }

    private func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        try checkClient()
        var form = [
            ("grant_type", "refresh_token"),
            ("refresh_token", tokens.refreshToken),
            ("client_id", provider.clientID),
        ]
        if let secret = provider.clientSecret { form.append(("client_secret", secret)) }
        let response = try await requestTokens(form)
        var updated = tokens
        updated.accessToken = response.accessToken
        updated.refreshToken = response.refreshToken ?? tokens.refreshToken
        updated.expiresAt = response.expiry(now: Date())
        if let idToken = response.idToken, let accountID = ChatGPTAuth.accountID(fromIDToken: idToken) {
            updated.accountID = accountID
        }
        // Signed out while the refresh was in flight: don't bring the tokens back.
        try Task.checkCancellation()
        store.save(updated)
        return updated
    }

    private func requestTokens(_ form: [(String, String)]) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: provider.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let (data, response) = try await HTTP.perform(request, session: session)
        guard (200..<300).contains(response.statusCode) else {
            if [400, 401].contains(response.statusCode) {
                throw TranslationError.notConfigured("\(provider.name) 登录已失效，请在设置中重新登录。")
            }
            throw HTTP.error(status: response.statusCode, data: data)
        }
        guard let tokens = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data) else {
            throw TranslationError.invalidResponse
        }
        return tokens
    }

    static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}

/// Runs `operation`, failing with `.timeout` after `seconds`.
func withTimeout<T: Sendable>(seconds: UInt64, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw TranslationError.timeout
        }
        defer { group.cancelAll() }
        do {
            return try await group.next()!
        } catch is CancellationError {
            throw TranslationError.cancelled
        }
    }
}
