import Foundation

/// "Sign in with ChatGPT" as used by the Codex CLI: the subscription's quota is
/// used through the Codex Responses backend.
public enum ChatGPTAuth {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let originator = "codex_cli_rs"
    /// Codex CLI version reported to the model list endpoint.
    public static let clientVersion = "0.160.0"

    static func accountID(fromIDToken token: String) -> String? {
        guard let claims = JWT.claims(token) else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let organizations = claims["organizations"] as? [[String: Any]]
        return auth?["chatgpt_account_id"] as? String
            ?? claims["chatgpt_account_id"] as? String
            ?? organizations?.first?["id"] as? String
    }
}

extension OAuthProvider {
    public static let chatGPT = OAuthProvider(
        name: "ChatGPT",
        authorizeURL: URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
        clientID: ChatGPTAuth.clientID,
        clientSecret: nil,
        scopes: ["openid", "profile", "email", "offline_access"],
        callbackPort: 1455,
        callbackPath: "/auth/callback",
        extraAuthorizeParameters: [
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: ChatGPTAuth.originator),
        ],
        resolveAccount: { response, _ in
            let tokens = [response.idToken, response.accessToken].compactMap { $0 }
            return OAuthAccount(
                email: tokens.lazy.compactMap { JWT.claims($0)?["email"] as? String }.first,
                accountID: tokens.lazy.compactMap(ChatGPTAuth.accountID(fromIDToken:)).first
            )
        }
    )
}

/// Calls `chatgpt.com/backend-api/codex/responses`. The backend only streams,
/// so the server-sent events are collected before parsing.
public final class ChatGPTTranslator: Translator {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    public static let modelsEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/models")!

    private let auth: OAuthSession
    private let model: String
    private let session: URLSession

    public init(auth: OAuthSession, model: String, session: URLSession = .shared) throws {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw TranslationError.notConfigured("请在设置中填写 ChatGPT 模型名称。") }
        self.auth = auth
        self.model = model
        self.session = session
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard request.text.count <= TranslationLimits.maxInputCharacters else {
            throw TranslationError.inputTooLong(max: TranslationLimits.maxInputCharacters)
        }
        let messages = PromptBuilder.messages(for: request)
        let body: [String: Any] = [
            "model": model,
            "instructions": messages.system,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": messages.user]],
            ]],
            "stream": true,
            "store": false,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        let data = try await auth.send(session: session) { tokens in
            var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: 60)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            urlRequest.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = tokens.accountID {
                urlRequest.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            urlRequest.setValue(ChatGPTAuth.originator, forHTTPHeaderField: "originator")
            urlRequest.setValue(request.id.uuidString, forHTTPHeaderField: "session_id")
            urlRequest.httpBody = payload
            return urlRequest
        }
        return try ResultParser.parse(try Self.outputText(fromEvents: data), for: request)
    }

    /// Final text from a Responses event stream: the completed response's
    /// output, or the concatenated deltas when it carries none.
    static func outputText(fromEvents data: Data) throws -> String {
        var deltas = ""
        var completed: String?
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { continue }
            let response = event["response"] as? [String: Any]
            switch event["type"] as? String {
            case "response.output_text.delta":
                deltas += event["delta"] as? String ?? ""
            case "response.completed", "response.done":
                let output = response?["output"] as? [[String: Any]] ?? []
                let text = output
                    .filter { $0["type"] as? String == "message" }
                    .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
                    .joined()
                if !text.isEmpty { completed = text }
            case "response.failed", "response.incomplete", "error":
                let error = (response?["error"] ?? event["error"]) as? [String: Any]
                let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String
                let message = error?["message"] as? String ?? event["message"] as? String ?? reason ?? "请求失败"
                throw TranslationError.rejected(message)
            default:
                continue
            }
        }
        let text = completed ?? deltas
        guard !text.isEmpty else { throw TranslationError.invalidResponse }
        return text
    }
}

extension OAuthSession {
    /// Sends a request built from valid tokens. When the API rejects the
    /// access token, refreshes once and retries.
    func send(session: URLSession, _ build: @Sendable (OAuthTokens) throws -> URLRequest) async throws -> Data {
        var tokens = try await validTokens()
        for attempt in 0..<2 {
            let (data, response) = try await HTTP.perform(try build(tokens), session: session)
            if response.statusCode == 401, attempt == 0 {
                tokens = try await validTokens(forceRefresh: true)
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw HTTP.error(status: response.statusCode, data: data)
            }
            return data
        }
        throw TranslationError.unauthorized
    }
}
