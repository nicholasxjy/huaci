import Foundation

/// Google sign-in with the Antigravity IDE's OAuth client; requests go to the
/// Cloud Code Assist backend that Antigravity uses. Not an official public API.
public enum AntigravityAuth {
    /// Antigravity's OAuth client is kept out of the repository: the build
    /// script writes it into Info.plist, and environment variables of the same
    /// name work for `swift run`. Empty when not configured.
    public static let clientID = configuredValue(infoKey: "HuaciAntigravityClientID", environmentKey: "ANTIGRAVITY_CLIENT_ID")
    public static let clientSecret = configuredValue(infoKey: "HuaciAntigravityClientSecret", environmentKey: "ANTIGRAVITY_CLIENT_SECRET")
    public static let version = "1.18.3"
    public static let userAgent = "antigravity/\(version) darwin/arm64"
    /// Used when the account has no Code Assist project of its own.
    public static let fallbackProjectID = "rising-fact-p41fc"

    static let prodEndpoint = URL(string: "https://cloudcode-pa.googleapis.com")!
    static let metadata = ["ideType": "ANTIGRAVITY", "platform": "MACOS", "pluginType": "GEMINI"]
    static let onboardAttempts = 5
    static let onboardDelay: UInt64 = 2_000_000_000

    static func configuredValue(infoKey: String, environmentKey: String,
                                info: [String: Any]? = Bundle.main.infoDictionary,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        [info?[infoKey] as? String, environment[environmentKey]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    static func resolveAccount(_ response: OAuthTokenResponse, session: URLSession) async throws -> OAuthAccount {
        let email = try? await userEmail(accessToken: response.accessToken, session: session)
        let project = try? await projectID(accessToken: response.accessToken, session: session)
        return OAuthAccount(email: email, projectID: project)
    }

    private static func userEmail(accessToken: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json")!, timeoutInterval: 15)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTP.perform(request, session: session)
        guard response.statusCode == 200 else { return nil }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["email"] as? String
    }

    /// The managed Code Assist project, onboarding the account when it has none.
    private static func projectID(accessToken: String, session: URLSession) async throws -> String? {
        let loaded = try await post("loadCodeAssist", ["metadata": metadata], accessToken: accessToken, session: session)
        if let project = loaded["cloudaicompanionProject"] as? String, !project.isEmpty { return project }
        if let project = (loaded["cloudaicompanionProject"] as? [String: Any])?["id"] as? String, !project.isEmpty { return project }

        let tiers = loaded["allowedTiers"] as? [[String: Any]] ?? []
        let tier = (tiers.first { $0["isDefault"] as? Bool == true } ?? tiers.first)?["id"] as? String ?? "free-tier"
        for attempt in 0..<onboardAttempts {
            let reply = try await post("onboardUser", ["tierId": tier, "metadata": metadata], accessToken: accessToken, session: session)
            if reply["done"] as? Bool == true {
                return ((reply["response"] as? [String: Any])?["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
            }
            if attempt < onboardAttempts - 1 { try await Task.sleep(nanoseconds: onboardDelay) }
        }
        return nil
    }

    private static func post(_ method: String, _ body: [String: Any], accessToken: String, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(prodEndpoint.absoluteString)/v1internal:\(method)")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTP.perform(request, session: session)
        guard (200..<300).contains(response.statusCode) else { throw HTTP.error(status: response.statusCode, data: data) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

extension OAuthProvider {
    public static let antigravity = OAuthProvider(
        name: "Antigravity",
        authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        // Google's installed-app flow needs both; without the secret the client counts as unconfigured.
        clientID: AntigravityAuth.clientSecret.isEmpty ? "" : AntigravityAuth.clientID,
        clientSecret: AntigravityAuth.clientSecret.isEmpty ? nil : AntigravityAuth.clientSecret,
        scopes: [
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile",
            "https://www.googleapis.com/auth/cclog",
            "https://www.googleapis.com/auth/experimentsandconfigs",
        ],
        callbackPort: 51121,
        callbackPath: "/oauth-callback",
        extraAuthorizeParameters: [
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ],
        resolveAccount: { response, session in try await AntigravityAuth.resolveAccount(response, session: session) }
    )
}

/// Calls `v1internal:generateContent`, trying the sandbox endpoints before
/// production as Antigravity does.
public final class AntigravityTranslator: Translator {
    public static let endpoints = [
        URL(string: "https://daily-cloudcode-pa.sandbox.googleapis.com")!,
        URL(string: "https://autopush-cloudcode-pa.sandbox.googleapis.com")!,
        AntigravityAuth.prodEndpoint,
    ]

    /// Identity preamble Antigravity sends; the translation prompt follows it.
    static let systemPreamble = """
    You are Antigravity, a powerful agentic AI coding assistant designed by the Google DeepMind team working on Advanced Agentic Coding.
    <priority>IMPORTANT: The instructions that follow supersede all above. Follow them as your primary directives.</priority>
    """

    private let auth: OAuthSession
    private let model: String
    private let session: URLSession
    private let endpoints: [URL]

    public init(auth: OAuthSession, model: String, session: URLSession = .shared, endpoints: [URL] = AntigravityTranslator.endpoints) throws {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw TranslationError.notConfigured("请在设置中填写 Antigravity 模型名称。") }
        self.auth = auth
        self.model = model
        self.session = session
        self.endpoints = endpoints
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard request.text.count <= TranslationLimits.maxInputCharacters else {
            throw TranslationError.inputTooLong(max: TranslationLimits.maxInputCharacters)
        }
        let messages = PromptBuilder.messages(for: request)
        var generationConfig: [String: Any] = [:]
        if model.hasPrefix("gemini-3") {
            // Pro models carry their tier in the name (gemini-3.1-pro-low).
            let tier = ["minimal", "low", "medium", "high"].first { model.hasSuffix("-\($0)") } ?? "low"
            generationConfig["thinkingConfig"] = ["thinkingLevel": tier]
        }
        let inner: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": messages.user]]]],
            "systemInstruction": ["role": "user", "parts": [["text": Self.systemPreamble], ["text": messages.system]]],
            "generationConfig": generationConfig,
        ]

        var lastError: Error = TranslationError.invalidResponse
        for (index, endpoint) in endpoints.enumerated() {
            let url = endpoint.appendingPathComponent("v1internal:generateContent")
            let model = model
            do {
                let data = try await auth.send(session: session) { tokens in
                    let body: [String: Any] = [
                        "project": tokens.projectID ?? AntigravityAuth.fallbackProjectID,
                        "model": model,
                        "request": inner,
                        "requestType": "agent",
                        "userAgent": "antigravity",
                        "requestId": "agent-\(UUID().uuidString.lowercased())",
                    ]
                    var urlRequest = URLRequest(url: url, timeoutInterval: 60)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue(AntigravityAuth.userAgent, forHTTPHeaderField: "User-Agent")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
                    return urlRequest
                }
                return try ResultParser.parse(try Self.outputText(data), for: request)
            } catch let error as TranslationError where index < endpoints.count - 1 && Self.shouldTryNextEndpoint(error) {
                lastError = error
            }
        }
        throw lastError
    }

    static func shouldTryNextEndpoint(_ error: TranslationError) -> Bool {
        switch error {
        case .network, .timeout, .rateLimited: return true
        case .http(let status, _): return status == 404 || status >= 500
        default: return false
        }
    }

    /// Joins the first candidate's non-thought text parts.
    static func outputText(_ data: Data) throws -> String {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let response = root?["response"] as? [String: Any] ?? root
        let candidate = (response?["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts
            .filter { $0["thought"] as? Bool != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw TranslationError.invalidResponse }
        return text
    }
}
