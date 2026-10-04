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

    /// `v1internal:fetchAvailableModels` for the account's project. Entries
    /// without a display name are internal and left out.
    public static func antigravity(auth: OAuthSession, session: URLSession = .shared,
                                   endpoints: [URL] = AntigravityTranslator.endpoints) async throws -> [RemoteModel] {
        let data = try await AntigravityTranslator.firstReachable(endpoints) { endpoint in
            let url = endpoint.appendingPathComponent("v1internal:fetchAvailableModels")
            return try await auth.send(session: session) { tokens in
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue(AntigravityAuth.userAgent, forHTTPHeaderField: "User-Agent")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["project": tokens.projectID ?? AntigravityAuth.fallbackProjectID])
                return request
            }
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let entries = root?["models"] as? [String: Any] else { throw TranslationError.invalidResponse }
        return entries
            .compactMap { id, value -> RemoteModel? in
                guard let name = (value as? [String: Any])?["displayName"] as? String, !name.isEmpty else { return nil }
                return RemoteModel(id: id, displayName: name)
            }
            .sorted { $0.id < $1.id }
    }
}
