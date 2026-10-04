import Foundation
import Testing
@testable import HuaciCore

/// Server-sent events as returned by the ChatGPT Codex backend.
func sse(_ events: [[String: Any]]) -> String {
    events.map { event in
        let data = String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        return "event: \(event["type"] as! String)\ndata: \(data)\n\n"
    }.joined()
}

func completedEvents(_ text: String) -> String {
    sse([
        ["type": "response.created", "response": ["id": "r1"]],
        ["type": "response.output_text.delta", "delta": text],
        ["type": "response.completed", "response": [
            "id": "r1",
            "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]],
        ]],
    ])
}

func geminiReply(_ parts: [[String: Any]]) -> String {
    let body: [String: Any] = ["response": ["candidates": [["content": ["role": "model", "parts": parts]]]]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
}

extension TranslatorTests {
    static let freshTokens = OAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600),
                                         email: "me@example.com", accountID: "acct-1", projectID: "proj-1")

    @Suite struct ChatGPT {
        let request = TranslationRequest(text: "run", kind: .word, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        let word = #"{"kind":"word","headword":"run","translation":"跑","senses":[{"pos":"v.","meanings":["跑"]}],"examples":[]}"#

        func translator(_ replies: [StubURLProtocol.Reply], tokens: OAuthTokens = TranslatorTests.freshTokens) throws -> (ChatGPTTranslator, MemoryCredentialStore) {
            let session = StubURLProtocol.session(replies)
            let store = MemoryCredentialStore(tokens)
            let auth = OAuthSession(provider: .chatGPT, store: store, session: session)
            return (try ChatGPTTranslator(auth: auth, model: " gpt-test ", session: session), store)
        }

        @Test func sendsResponsesRequestWithAccountHeader() async throws {
            let (translator, _) = try translator([.init(status: 200, body: completedEvents(word))])

            let result = try await translator.translate(request)

            #expect(result.kind == .word)
            #expect(result.translation == "跑")
            let sent = try #require(StubURLProtocol.requests.first).request
            #expect(sent.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
            #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer at")
            #expect(sent.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
            #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            let body = try StubURLProtocol.bodyJSON(0)
            #expect(body["model"] as? String == "gpt-test")
            #expect(body["stream"] as? Bool == true)
            #expect(body["store"] as? Bool == false)
            #expect((body["instructions"] as? String)?.contains("bilingual dictionary") == true)
            let input = try #require(body["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: String]])
            #expect(content.first?["type"] == "input_text")
            #expect(content.first?["text"]?.contains("<source>\nrun\n</source>") == true)
        }

        @Test func joinsDeltasWhenCompletionHasNoOutput() async throws {
            let events = sse([
                ["type": "response.output_text.delta", "delta": "跑"],
                ["type": "response.output_text.delta", "delta": "步"],
                ["type": "response.completed", "response": ["id": "r1"]],
            ])
            let (translator, _) = try translator([.init(status: 200, body: events)])
            #expect(try await translator.translate(request).translation == "跑步")
        }

        @Test func failedResponseIsReported() async throws {
            let events = sse([["type": "response.failed", "response": ["error": ["message": "model overloaded"]]]])
            let (translator, _) = try translator([.init(status: 200, body: events)])
            await #expect(throws: TranslationError.rejected("model overloaded")) { try await translator.translate(request) }
        }

        @Test func refreshesAndRetriesOnceWhenUnauthorized() async throws {
            let (translator, store) = try translator([
                .init(status: 401, body: #"{"detail":"token expired"}"#),
                .init(status: 200, body: #"{"access_token":"at-2","refresh_token":"rt-2","expires_in":3600}"#),
                .init(status: 200, body: completedEvents("跑")),
            ])

            #expect(try await translator.translate(request).translation == "跑")

            #expect(StubURLProtocol.requests.count == 3)
            #expect(StubURLProtocol.requests[1].request.url?.absoluteString == "https://auth.openai.com/oauth/token")
            #expect(StubURLProtocol.requests[2].request.value(forHTTPHeaderField: "Authorization") == "Bearer at-2")
            #expect(store.tokens?.accessToken == "at-2")
            #expect(store.tokens?.accountID == "acct-1")
        }

        @Test func usageLimitIsRateLimited() async throws {
            let (translator, _) = try translator([.init(status: 429, body: #"{"error":{"type":"usage_limit_reached","message":"limit"}}"#)])
            await #expect(throws: TranslationError.rateLimited) { try await translator.translate(request) }
        }

        @Test func emptyModelIsRejected() throws {
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(), session: StubURLProtocol.session([]))
            #expect(throws: TranslationError.self) { try ChatGPTTranslator(auth: auth, model: " ") }
        }
    }

    @Suite struct Antigravity {
        let request = TranslationRequest(text: "Hello world.", kind: .text, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        let endpoints = [URL(string: "https://daily.example.com")!, URL(string: "https://prod.example.com")!]

        func translator(_ replies: [StubURLProtocol.Reply], model: String = "gemini-3-flash") throws -> AntigravityTranslator {
            let session = StubURLProtocol.session(replies)
            let auth = OAuthSession(provider: .antigravity, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)
            return try AntigravityTranslator(auth: auth, model: model, session: session, endpoints: endpoints)
        }

        @Test func wrapsRequestForCloudCodeAssist() async throws {
            let translator = try translator([.init(status: 200, body: geminiReply([
                ["text": "thinking…", "thought": true],
                ["text": #"{"kind":"text","translation":"你好，世界。"}"#],
            ]))])

            let result = try await translator.translate(request)

            #expect(result.translation == "你好，世界。")
            let sent = try #require(StubURLProtocol.requests.first).request
            #expect(sent.url?.absoluteString == "https://daily.example.com/v1internal:generateContent")
            #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer at")
            #expect(sent.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/") == true)
            let body = try StubURLProtocol.bodyJSON(0)
            #expect(body["project"] as? String == "proj-1")
            #expect(body["model"] as? String == "gemini-3-flash")
            #expect(body["userAgent"] as? String == "antigravity")
            let inner = try #require(body["request"] as? [String: Any])
            let contents = try #require(inner["contents"] as? [[String: Any]])
            let parts = try #require(contents.first?["parts"] as? [[String: String]])
            #expect(contents.first?["role"] as? String == "user")
            #expect(parts.first?["text"]?.contains("<source>\nHello world.\n</source>") == true)
            let system = try #require(inner["systemInstruction"] as? [String: Any])
            let systemParts = try #require(system["parts"] as? [[String: String]])
            #expect(systemParts.contains { $0["text"]?.contains("professional translator") == true })
        }

        @Test func fallsBackToNextEndpointOnServerError() async throws {
            let translator = try translator([
                .init(status: 503, body: #"{"error":{"message":"unavailable"}}"#),
                .init(status: 200, body: geminiReply([["text": "你好"]])),
            ])

            #expect(try await translator.translate(request).translation == "你好")
            #expect(StubURLProtocol.requests.map { $0.request.url?.host } == ["daily.example.com", "prod.example.com"])
        }

        @Test func lastEndpointErrorIsReported() async throws {
            let translator = try translator([
                .init(status: 503, body: "{}"),
                .init(status: 429, body: #"{"error":{"message":"quota","status":"RESOURCE_EXHAUSTED"}}"#),
            ])
            await #expect(throws: TranslationError.rateLimited) { try await translator.translate(request) }
        }

        @Test func clientErrorsDoNotFallBack() async throws {
            let translator = try translator([.init(status: 400, body: #"{"error":{"message":"unknown model"}}"#)])
            await #expect(throws: TranslationError.http(status: 400, message: "unknown model")) { try await translator.translate(request) }
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func signInResolvesEmailAndProject() async throws {
            let session = StubURLProtocol.session([
                .init(status: 200, body: #"{"email":"me@gmail.com"}"#),
                .init(status: 200, body: #"{"cloudaicompanionProject":"proj-9","currentTier":{"id":"free-tier"}}"#),
            ])
            let response = OAuthTokenResponse(accessToken: "at", refreshToken: "rt", idToken: nil, expiresIn: 3600)

            let account = try await OAuthProvider.antigravity.resolveAccount(response, session)

            #expect(account.email == "me@gmail.com")
            #expect(account.projectID == "proj-9")
            #expect(StubURLProtocol.requests[1].request.url?.absoluteString.hasSuffix("/v1internal:loadCodeAssist") == true)
            #expect(StubURLProtocol.requests[1].request.value(forHTTPHeaderField: "Authorization") == "Bearer at")
        }

        @Test func signInOnboardsWhenNoProjectExists() async throws {
            let session = StubURLProtocol.session([
                .init(status: 200, body: #"{"email":"me@gmail.com"}"#),
                .init(status: 200, body: #"{"allowedTiers":[{"id":"legacy-tier"},{"id":"free-tier","isDefault":true}]}"#),
                .init(status: 200, body: #"{"done":true,"response":{"cloudaicompanionProject":{"id":"proj-new"}}}"#),
            ])
            let response = OAuthTokenResponse(accessToken: "at", refreshToken: "rt", idToken: nil, expiresIn: 3600)

            let account = try await OAuthProvider.antigravity.resolveAccount(response, session)

            #expect(account.projectID == "proj-new")
            #expect(try StubURLProtocol.bodyJSON(2)["tierId"] as? String == "free-tier")
        }
    }
}
