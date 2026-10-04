import Foundation

/// A model a service offers, as reported by its model list endpoint.
public struct RemoteModel: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

/// Fetches the models each service currently offers, so settings can list
/// them instead of relying on hardcoded names.
public enum ModelCatalog {
    /// `GET {base}/models` on an OpenAI-compatible endpoint, sorted by id.
    public static func personalAPI(baseURL: String, apiKey: String, session: URLSession = .shared) async throws -> [RemoteModel] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let completions = OpenAICompatibleTranslator.endpoint(from: baseURL) else {
            throw TranslationError.notConfigured("个人 API 服务地址无效，请在设置中填写以 https:// 开头的地址。")
        }
        guard !key.isEmpty else { throw TranslationError.notConfigured("请在设置中填写个人 API Key。") }
        let url = completions.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTP.perform(request, session: session)
        guard (200..<300).contains(response.statusCode) else { throw HTTP.error(status: response.statusCode, data: data) }

        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw TranslationError.invalidResponse }
        return list.data.map { RemoteModel(id: $0.id) }.sorted { $0.id < $1.id }
    }

    /// The Codex backend's model list, as the Codex CLI shows it: listed
    /// models only, in the server's priority order.
    public static func chatGPT(auth: OAuthSession, session: URLSession = .shared) async throws -> [RemoteModel] {
        var components = URLComponents(url: ChatGPTTranslator.modelsEndpoint, resolvingAgainstBaseURL: false)!
        // Required; the server filters models by the client version.
        components.queryItems = [URLQueryItem(name: "client_version", value: ChatGPTAuth.clientVersion)]
        let url = components.url!
        let data = try await auth.send(session: session) { tokens in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = tokens.accountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            request.setValue(ChatGPTAuth.originator, forHTTPHeaderField: "originator")
            return request
        }

        struct List: Decodable {
            struct Model: Decodable {
                let slug: String
                let display_name: String?
                let visibility: String?
                let priority: Int?
            }
            let models: [Model]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw TranslationError.invalidResponse }
        return list.models
            .filter { ($0.visibility ?? "list") == "list" }
            .sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
            .map { RemoteModel(id: $0.slug, displayName: $0.display_name) }
    }

    /// `v1internal:fetchAvailableModels` for the account's project, named
    /// with its tier as Antigravity does (a tier Google won't take is dropped,
    /// down to none). Chat models only, in the order Antigravity's picker shows
    /// them; its usual models when it lists none.
    public static func antigravity(auth: OAuthSession, session: URLSession = .shared,
                                   backend: AntigravityBackend = .live) async throws -> [RemoteModel] {
        let tokens = try await auth.validTokens()
        let project = try await AntigravityAuth.project(accessToken: tokens.accessToken, storedID: tokens.projectID,
                                                        session: session, backend: backend)
        let url = backend.url(backend.base, "fetchAvailableModels")
        let userAgent = backend.userAgent(version: await backend.version())

        var reply: Data?
        var lastError: Error = TranslationError.invalidResponse
        for tier in project.entitlements.map(Optional.some) + [nil] {
            var body: [String: Any] = ["project": project.id]
            if let tier { body["entitlement"] = ["userTier": tier] }
            let payload = try JSONSerialization.data(withJSONObject: body)
            do {
                reply = try await auth.send(session: session) { tokens in
                    var request = URLRequest(url: url, timeoutInterval: 20)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
                    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    request.httpBody = payload
                    return request
                }
                break
            } catch TranslationError.cancelled {
                throw TranslationError.cancelled
            } catch {
                lastError = error
            }
        }
        guard let reply else { throw lastError }

        let root = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        guard let entries = root?["models"] as? [String: Any] else { throw TranslationError.invalidResponse }
        var rank: [String: Int] = [:]
        for sort in root?["agentModelSorts"] as? [[String: Any]] ?? [] {
            for group in sort["groups"] as? [[String: Any]] ?? [] {
                for id in group["modelIds"] as? [String] ?? [] where rank[id] == nil {
                    rank[id] = rank.count
                }
            }
        }
        let known = Dictionary(uniqueKeysWithValues: antigravityModels.map { ($0.id, $0.displayName) })
        let models = entries
            .compactMap { id, value -> RemoteModel? in
                guard !antigravityHidden.contains(id), !id.hasPrefix("chat_"), !id.hasPrefix("tab_") else { return nil }
                let name = ((value as? [String: Any])?["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return RemoteModel(id: id, displayName: name ?? known[id] ?? nil)
            }
            .sorted { a, b in
                switch (rank[a.id], rank[b.id]) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a.id < b.id
                }
            }
        return models.isEmpty ? antigravityModels : models
    }

    /// The models Antigravity offers, for when it doesn't say.
    static let antigravityModels = [
        RemoteModel(id: "gemini-3-flash", displayName: "Gemini 3 Flash"),
        RemoteModel(id: "gemini-3.1-pro-low", displayName: "Gemini 3.1 Pro (Low)"),
        RemoteModel(id: "gemini-pro-agent", displayName: "Gemini 3.1 Pro (High)"),
        RemoteModel(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash Lite"),
        RemoteModel(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        RemoteModel(id: "claude-opus-4-6-thinking", displayName: "Claude Opus 4.6 (Thinking)"),
        RemoteModel(id: "gpt-oss-120b-medium", displayName: "GPT-OSS 120B (Medium)"),
    ]

    /// Models Antigravity lists that aren't for chat.
    static let antigravityHidden: Set<String> = [
        "chat_20706", "chat_23310", "tab_flash_lite_preview", "tab_jump_flash_lite_preview",
        "gemini-2.5-flash-thinking", "gemini-2.5-pro",
    ]
}
