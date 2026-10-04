import Foundation
import Testing
@testable import HuaciCore

/// Intercepts URLSession traffic so translators can be tested end to end
/// without a network.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []

    static func session(_ replies: [Reply]) -> URLSession {
        self.replies = replies
        requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func bodyJSON(_ index: Int) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: requests[index].body) as? [String: Any])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append((request, Self.readBody(request)))
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: "") : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

func completion(_ content: String) -> String {
    let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: [content], options: .fragmentsAllowed), as: UTF8.self)
    return #"{"choices":[{"message":{"role":"assistant","content":\#(encoded.dropFirst().dropLast())}}]}"#
}

@Suite(.serialized)
struct TranslatorTests {
    let request = TranslationRequest(text: "run", kind: .word, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
    let personal = PersonalAPIConfig(baseURL: "https://api.example.com/v1/", apiKey: " sk-personal ", model: "gpt-test")

    @Test(arguments: [
        ("https://api.openai.com/v1", "https://api.openai.com/v1/chat/completions"),
        ("https://api.openai.com/v1/", "https://api.openai.com/v1/chat/completions"),
        ("https://host/openai/v1/chat/completions", "https://host/openai/v1/chat/completions"),
        ("http://localhost:11434/v1", "http://localhost:11434/v1/chat/completions"),
    ])
    func endpointNormalization(_ input: String, _ expected: String) {
        #expect(OpenAICompatibleTranslator.endpoint(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "api.openai.com/v1", "ftp://host/v1"])
    func invalidEndpointIsRejected(_ input: String) {
        #expect(OpenAICompatibleTranslator.endpoint(from: input) == nil)
        #expect(throws: TranslationError.self) {
            try OpenAICompatibleTranslator(config: PersonalAPIConfig(baseURL: input, apiKey: "k", model: "m"))
        }
    }

    @Test func personalAPISendsChatCompletion() async throws {
        let session = StubURLProtocol.session([.init(status: 200, body: completion(#"{"kind":"word","headword":"run","translation":"跑","senses":[{"pos":"v.","meanings":["跑"]}],"examples":[]}"#))])
        let translator = try OpenAICompatibleTranslator(config: personal, session: session)

        let result = try await translator.translate(request)

        #expect(result.kind == .word)
        #expect(result.translation == "跑")
        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-personal")
        let body = try StubURLProtocol.bodyJSON(0)
        #expect(body["model"] as? String == "gpt-test")
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.last?["content"]?.contains("<source>\nrun\n</source>") == true)
    }

    @Test func retriesWithoutResponseFormatWhenRejected() async throws {
        let session = StubURLProtocol.session([
            .init(status: 400, body: #"{"error":{"message":"Unsupported parameter: response_format"}}"#),
            .init(status: 200, body: completion("跑步")),
        ])
        let translator = try OpenAICompatibleTranslator(config: personal, session: session)

        let result = try await translator.translate(request)

        #expect(result.translation == "跑步")
        #expect(StubURLProtocol.requests.count == 2)
        #expect(try StubURLProtocol.bodyJSON(1)["response_format"] == nil)
    }

    @Test(arguments: [
        (401, TranslationError.unauthorized),
        (429, TranslationError.rateLimited),
        (504, TranslationError.timeout),
        (500, TranslationError.http(status: 500, message: "boom")),
    ])
    func personalAPIErrorsAreMapped(_ status: Int, _ expected: TranslationError) async throws {
        let session = StubURLProtocol.session([.init(status: status, body: #"{"error":{"message":"boom"}}"#)])
        let translator = try OpenAICompatibleTranslator(config: personal, session: session)
        await #expect(throws: expected) { try await translator.translate(request) }
    }

    @Test func overlongInputIsRejectedLocally() async throws {
        let translator = try OpenAICompatibleTranslator(config: personal, session: StubURLProtocol.session([]))
        let long = TranslationRequest(text: String(repeating: "a", count: OpenAICompatibleTranslator.maxInputCharacters + 1),
                                      kind: .text, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        await #expect(throws: TranslationError.inputTooLong(max: OpenAICompatibleTranslator.maxInputCharacters)) {
            try await translator.translate(long)
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }
}
