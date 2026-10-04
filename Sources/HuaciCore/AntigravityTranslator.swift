import CryptoKit
import Foundation

/// Google sign-in with the Antigravity IDE's OAuth client; requests go to the
/// Cloud Code Assist backend that Antigravity uses, shaped as Antigravity
/// shapes them. Not an official public API.
public enum AntigravityAuth {
    /// Antigravity's OAuth client is kept out of the repository: the build
    /// script writes it into Info.plist, and environment variables of the same
    /// name work for `swift run`. Empty when not configured.
    public static let clientID = configuredValue(infoKey: "HuaciAntigravityClientID", environmentKey: "ANTIGRAVITY_CLIENT_ID")
    public static let clientSecret = configuredValue(infoKey: "HuaciAntigravityClientSecret", environmentKey: "ANTIGRAVITY_CLIENT_SECRET")

    static let onboardAttempts = 5
    static let onboardDelay: UInt64 = 2_000_000_000

    static func configuredValue(infoKey: String, environmentKey: String,
                                info: [String: Any]? = Bundle.main.infoDictionary,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        [info?[infoKey] as? String, environment[environmentKey]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    /// Email and project after sign-in. The sign-in is kept without a project;
    /// requests look for one again and report why there is none.
    static func resolveAccount(_ response: OAuthTokenResponse, session: URLSession,
                               backend: AntigravityBackend = .live) async throws -> OAuthAccount {
        let email = try? await userEmail(accessToken: response.accessToken, session: session)
        let project = try? await project(accessToken: response.accessToken, storedID: nil, session: session, backend: backend)
        return OAuthAccount(email: email, projectID: project?.id)
    }

    private static func userEmail(accessToken: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json")!, timeoutInterval: 15)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTP.perform(request, session: session)
        guard response.statusCode == 200 else { return nil }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["email"] as? String
    }

    /// The account's Code Assist project and tiers, set up (onboarded) the
    /// way Antigravity does it when Code Assist has none. A project kept with
    /// the sign-in is still the one used; the tiers are asked for anyway.
    static func project(accessToken: String, storedID: String?, session: URLSession,
                        backend: AntigravityBackend) async throws -> AntigravityProject {
        let version = await backend.version()
        let userAgent = backend.userAgent(version: version)
        let load: [String: Any]
        do {
            load = try await post(backend.url(backend.loadBase, "loadCodeAssist"), ["metadata": ["ideType": "ANTIGRAVITY"]],
                                  accessToken: accessToken, headers: ["User-Agent": userAgent], session: session)
        } catch let error as TranslationError where storedID != nil && error != .cancelled {
            return AntigravityProject(id: storedID!)
        }
        let current = tierID(load["currentTier"])
        let paid = tierID(load["paidTier"])
        if let storedID { return AntigravityProject(id: storedID, tier: current, paid: paid) }
        if let id = companionProject(load["cloudaicompanionProject"]) {
            return AntigravityProject(id: id, tier: current, paid: paid)
        }

        let tiers = load["allowedTiers"] as? [[String: Any]] ?? []
        var tier = (tiers.first { $0["isDefault"] as? Bool == true } ?? tiers.first)?["id"] as? String ?? ""
        if tier.isEmpty || tier == "legacy-tier" { tier = "free-tier" }
        let body: [String: Any] = [
            "tier_id": tier,
            "metadata": ["ide_type": "ANTIGRAVITY", "ide_version": version, "ide_name": "antigravity"],
        ]
        let headers = ["User-Agent": "\(userAgent) google-api-nodejs-client/10.3.0", "X-Goog-Api-Client": "gl-node/22.21.1"]
        for attempt in 0..<onboardAttempts {
            let reply = try await post(backend.url(backend.base, "onboardUser"), body, accessToken: accessToken, headers: headers, session: session)
            if reply["done"] as? Bool == true {
                if let id = companionProject((reply["response"] as? [String: Any])?["cloudaicompanionProject"]) {
                    return AntigravityProject(id: id, tier: tier, paid: paid)
                }
                break
            }
            if attempt < onboardAttempts - 1 { try await Task.sleep(nanoseconds: onboardDelay) }
        }
        // An account Google won't serve Antigravity to (its region, its age) says why.
        let reason = (load["ineligibleTiers"] as? [[String: Any]] ?? [])
            .lazy.compactMap { $0["reasonMessage"] as? String }.first { !$0.isEmpty }
        if let reason { throw TranslationError.notConfigured("Antigravity 不为此 Google 账号提供服务：\(reason)") }
        throw TranslationError.notConfigured("Antigravity 还没有为此 Google 账号分配项目。请先用该账号登录一次 Antigravity 应用，再重试。")
    }

    /// Code Assist's project comes as an id or as `{id, name}`.
    private static func companionProject(_ value: Any?) -> String? {
        let id = value as? String ?? (value as? [String: Any])?["id"] as? String
        return id?.isEmpty == false ? id : nil
    }

    private static func tierID(_ value: Any?) -> String? {
        (value as? [String: Any])?["id"] as? String
    }

    private static func post(_ url: URL, _ body: [String: Any], accessToken: String, headers: [String: String],
                             session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTP.perform(request, session: session)
        guard (200..<300).contains(response.statusCode) else { throw HTTP.error(status: response.statusCode, data: data) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

/// The account's Code Assist project and the tiers `loadCodeAssist` gave.
struct AntigravityProject: Equatable, Sendable {
    let id: String
    var tier: String?
    var paid: String?

    /// Tiers to name in `fetchAvailableModels`' entitlement, best first. Google
    /// refuses a free tier there, so a free account names none.
    var entitlements: [String] {
        var out: [String] = []
        for tier in [paid, tier].compactMap({ $0 }) where tier != "free-tier" && tier != "legacy-tier" && !out.contains(tier) {
            out.append(tier)
        }
        return out
    }
}

/// Where Antigravity's requests go and which version they claim.
public struct AntigravityBackend: Sendable {
    /// Generation, onboarding and the model list.
    public var base: URL
    /// `loadCodeAssist`, which finds the account's project.
    public var loadBase: URL
    public var version: @Sendable () async -> String

    public init(base: URL, loadBase: URL, version: @escaping @Sendable () async -> String) {
        self.base = base
        self.loadBase = loadBase
        self.version = version
    }

    public static let live = AntigravityBackend(
        base: URL(string: "https://daily-cloudcode-pa.googleapis.com")!,
        loadBase: URL(string: "https://cloudcode-pa.googleapis.com")!,
        version: { await AntigravityVersion.shared.current() }
    )

    func userAgent(version: String) -> String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/hub/\(version) darwin/\(arch)"
    }

    /// `{base}/v1internal:{method}`; the method may carry a query.
    func url(_ base: URL, _ method: String) -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: "\(root)/v1internal:\(method)")!
    }
}

/// The newest Antigravity's version, which its requests carry; asked of its
/// updater at most every few hours.
public actor AntigravityVersion {
    public static let shared = AntigravityVersion(session: .shared)
    public static let fallback = "2.9.1"
    static let manifestURL = URL(string: "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml")!
    static let maxAge: TimeInterval = 6 * 3600

    private let session: URLSession
    private var value: String?
    private var checkedAt: Date?

    public init(session: URLSession) {
        self.session = session
    }

    public func current() async -> String {
        if let checkedAt, Date().timeIntervalSince(checkedAt) < Self.maxAge { return value ?? Self.fallback }
        checkedAt = Date()
        var request = URLRequest(url: Self.manifestURL, timeoutInterval: 5)
        request.setValue("electron-builder", forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await HTTP.perform(request, session: session), response.statusCode == 200,
           let version = Self.parse(String(decoding: data.prefix(64 * 1024), as: UTF8.self)) {
            value = version
        }
        return value ?? Self.fallback
    }

    /// The `version:` line of an electron-builder manifest.
    static func parse(_ manifest: String) -> String? {
        for line in manifest.split(whereSeparator: \.isNewline) where line.hasPrefix("version:") {
            let version = line.dropFirst("version:".count).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            let digits = CharacterSet(charactersIn: "0123456789.")
            return !version.isEmpty && version.unicodeScalars.allSatisfy(digits.contains) ? version : nil
        }
        return nil
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

/// Streams `v1internal:streamGenerateContent` and joins the reply.
public final class AntigravityTranslator: Translator {
    private let auth: OAuthSession
    private let model: String
    private let session: URLSession
    private let backend: AntigravityBackend

    public init(auth: OAuthSession, model: String, session: URLSession = .shared, backend: AntigravityBackend = .live) throws {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw TranslationError.notConfigured("请在设置中填写 Antigravity 模型名称。") }
        self.auth = auth
        self.model = model
        self.session = session
        self.backend = backend
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
            "systemInstruction": ["role": "user", "parts": [["text": messages.system]]],
            "generationConfig": generationConfig,
            "sessionId": Self.sessionID(for: messages.user),
        ]

        let tokens = try await auth.validTokens()
        let projectID: String
        if let stored = tokens.projectID {
            projectID = stored
        } else {
            projectID = try await AntigravityAuth.project(accessToken: tokens.accessToken, storedID: nil, session: session, backend: backend).id
        }
        let body: [String: Any] = [
            "project": projectID,
            "model": model,
            "request": inner,
            "requestType": "agent",
            "userAgent": "antigravity",
            "requestId": "agent-\(UUID().uuidString.lowercased())",
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let url = backend.url(backend.base, "streamGenerateContent?alt=sse")
        let userAgent = backend.userAgent(version: await backend.version())

        let data = try await auth.send(session: session) { tokens in
            var urlRequest = URLRequest(url: url, timeoutInterval: 60)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            urlRequest.httpBody = payload
            return urlRequest
        }
        return try ResultParser.parse(try Self.outputText(fromEvents: data), for: request)
    }

    /// Names the conversation as Antigravity does: from its first message.
    static func sessionID(for firstMessage: String) -> String {
        let digest = Array(SHA256.hash(data: Data(firstMessage.utf8)))
        let value = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } & 0x7fff_ffff_ffff_ffff
        return "-\(value)"
    }

    /// Joins the non-thought text of each `{response}` chunk in the stream.
    static func outputText(fromEvents data: Data) throws -> String {
        var text = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let chunk = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { continue }
            if let error = chunk["error"] as? [String: Any] {
                throw TranslationError.rejected(error["message"] as? String ?? "请求失败")
            }
            let response = chunk["response"] as? [String: Any] ?? chunk
            let candidate = (response["candidates"] as? [[String: Any]])?.first
            let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            text += parts
                .filter { $0["thought"] as? Bool != true }
                .compactMap { $0["text"] as? String }
                .joined()
        }
        guard !text.isEmpty else { throw TranslationError.invalidResponse }
        return text
    }
}
