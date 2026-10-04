import Foundation

public protocol Translator: Sendable {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

// MARK: - Personal OpenAI-compatible API

public struct PersonalAPIConfig: Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String

    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }
}

/// Calls `/chat/completions` on a user-provided OpenAI-compatible endpoint. The
/// key is sent only to that endpoint.
public final class OpenAICompatibleTranslator: Translator {
    public static let maxInputCharacters = 8000

    private let config: PersonalAPIConfig
    private let endpoint: URL
    private let session: URLSession

    public init(config: PersonalAPIConfig, session: URLSession = .shared) throws {
        let model = config.model.trimmingCharacters(in: .whitespaces)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = Self.endpoint(from: config.baseURL) else {
            throw TranslationError.notConfigured("个人 API 服务地址无效，请在设置中填写以 https:// 开头的地址。")
        }
        guard !key.isEmpty else { throw TranslationError.notConfigured("请在设置中填写个人 API Key。") }
        guard !model.isEmpty else { throw TranslationError.notConfigured("请在设置中填写模型名称。") }
        self.config = PersonalAPIConfig(baseURL: config.baseURL, apiKey: key, model: model)
        self.endpoint = endpoint
        self.session = session
    }

    /// Accepts either a base such as `https://api.openai.com/v1` or the full
    /// `.../chat/completions` URL.
    public static func endpoint(from baseURL: String) -> URL? {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        if url.path.hasSuffix("/chat/completions") { return url }
        return url.appendingPathComponent("chat").appendingPathComponent("completions")
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard request.text.count <= Self.maxInputCharacters else {
            throw TranslationError.inputTooLong(max: Self.maxInputCharacters)
        }
        do {
            return try await send(request, jsonFormat: true)
        } catch TranslationError.http(400, let message) where message?.contains("response_format") == true {
            // Some compatible servers reject `response_format`; the prompt alone still asks for JSON.
            return try await send(request, jsonFormat: false)
        }
    }

    private func send(_ request: TranslationRequest, jsonFormat: Bool) async throws -> TranslationResult {
        let messages = PromptBuilder.messages(for: request)
        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": messages.system],
                ["role": "user", "content": messages.user],
            ],
        ]
        if jsonFormat { body["response_format"] = ["type": "json_object"] }

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 45)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await HTTP.perform(urlRequest, session: session)
        guard (200..<300).contains(response.statusCode) else {
            let message = HTTP.openAIErrorMessage(data)
            switch response.statusCode {
            case 401, 403: throw TranslationError.unauthorized
            case 429: throw TranslationError.rateLimited
            case 408, 504: throw TranslationError.timeout
            default: throw TranslationError.http(status: response.statusCode, message: message)
            }
        }

        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let content = completion.choices.first?.message.content else {
            throw TranslationError.invalidResponse
        }
        return try ResultParser.parse(content, for: request)
    }
}

// MARK: - HTTP helpers

enum HTTP {
    static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
            return (data, http)
        } catch let error as TranslationError {
            throw error
        } catch is CancellationError {
            throw TranslationError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw TranslationError.cancelled
            case .timedOut: throw TranslationError.timeout
            default: throw TranslationError.network(error.localizedDescription)
            }
        }
    }

    static func openAIErrorMessage(_ data: Data) -> String? {
        struct Reply: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        if let message = (try? JSONDecoder().decode(Reply.self, from: data))?.error?.message { return message }
        let text = String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
