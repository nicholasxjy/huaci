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

/// Code Assist's server-sent events: one `{response}` chunk per element.
func geminiStream(_ chunks: [[[String: Any]]]) -> String {
    chunks.map { parts in
        let body: [String: Any] = ["response": ["candidates": [["content": ["role": "model", "parts": parts]]]]]
        return "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self) + "\r\n\r\n"
    }.joined()
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
        static let backend = AntigravityBackend(base: URL(string: "https://daily.example.com")!,
                                                loadBase: URL(string: "https://prod.example.com")!,
                                                version: { "9.9.9" })

        func translator(_ replies: [StubURLProtocol.Reply], model: String = "gemini-3-flash",
                        tokens: OAuthTokens = TranslatorTests.freshTokens) throws -> AntigravityTranslator {
            let session = StubURLProtocol.session(replies)
            let auth = OAuthSession(provider: .antigravity, store: MemoryCredentialStore(tokens), session: session)
            return try AntigravityTranslator(auth: auth, model: model, session: session, backend: Self.backend)
        }

        @Test func streamsRequestAsAntigravityDoes() async throws {
            let translator = try translator([.init(status: 200, body: geminiStream([
                [["text": "thinking…", "thought": true]],
                [["text": #"{"kind":"text","#]],
                [["text": #""translation":"你好，世界。"}"#]],
            ]))])

            let result = try await translator.translate(request)

            #expect(result.translation == "你好，世界。")
            let sent = try #require(StubURLProtocol.requests.first).request
            #expect(sent.url?.absoluteString == "https://daily.example.com/v1internal:streamGenerateContent?alt=sse")
            #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer at")
            #expect(sent.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/hub/9.9.9 darwin/") == true)
            let body = try StubURLProtocol.bodyJSON(0)
            #expect(body["project"] as? String == "proj-1")
            #expect(body["model"] as? String == "gemini-3-flash")
            #expect(body["userAgent"] as? String == "antigravity")
            #expect(body["requestType"] as? String == "agent")
            #expect((body["requestId"] as? String)?.hasPrefix("agent-") == true)
            let inner = try #require(body["request"] as? [String: Any])
            #expect((inner["sessionId"] as? String)?.hasPrefix("-") == true)
            let contents = try #require(inner["contents"] as? [[String: Any]])
            let parts = try #require(contents.first?["parts"] as? [[String: String]])
            #expect(contents.first?["role"] as? String == "user")
            #expect(parts.first?["text"]?.contains("<source>\nHello world.\n</source>") == true)
            let system = try #require(inner["systemInstruction"] as? [String: Any])
            let systemText = try #require(system["parts"] as? [[String: String]]).compactMap { $0["text"] }.joined()
            #expect(systemText.contains("professional translator"))
            #expect(!systemText.contains("You are Antigravity"))
        }

        @Test func sessionIDFollowsFirstMessage() {
            #expect(AntigravityTranslator.sessionID(for: "a") == AntigravityTranslator.sessionID(for: "a"))
            #expect(AntigravityTranslator.sessionID(for: "a") != AntigravityTranslator.sessionID(for: "b"))
            let id = AntigravityTranslator.sessionID(for: "a")
            #expect(id.count > 1 && id.dropFirst().allSatisfy { $0.isNumber })
        }

        @Test func errorsAreMapped() async throws {
            let limited = try translator([.init(status: 429, body: #"{"error":{"message":"quota","status":"RESOURCE_EXHAUSTED"}}"#)])
            await #expect(throws: TranslationError.rateLimited) { try await limited.translate(request) }

            let rejected = try translator([.init(status: 400, body: #"{"error":{"message":"unknown model"}}"#)])
            await #expect(throws: TranslationError.http(status: 400, message: "unknown model")) { try await rejected.translate(request) }
            #expect(StubURLProtocol.requests.count == 1)

            let streamed = try translator([.init(status: 200, body: "data: {\"error\":{\"message\":\"overloaded\"}}\n\n")])
            await #expect(throws: TranslationError.rejected("overloaded")) { try await streamed.translate(request) }
        }

        @Test func findsProjectWhenSignInHadNone() async throws {
            var tokens = TranslatorTests.freshTokens
            tokens.projectID = nil
            let translator = try translator([
                .init(status: 200, body: #"{"cloudaicompanionProject":{"id":"proj-9"},"currentTier":{"id":"free-tier"}}"#),
                .init(status: 200, body: geminiStream([[["text": #"{"kind":"text","translation":"你好"}"#]]])),
            ], tokens: tokens)

            #expect(try await translator.translate(request).translation == "你好")
            #expect(StubURLProtocol.requests[0].request.url?.absoluteString == "https://prod.example.com/v1internal:loadCodeAssist")
            #expect(try StubURLProtocol.bodyJSON(1)["project"] as? String == "proj-9")
        }

        @Test func accountWithoutProjectGetsGooglesReason() async throws {
            var tokens = TranslatorTests.freshTokens
            tokens.projectID = nil
            let translator = try translator([
                .init(status: 200, body: #"{"allowedTiers":[{"id":"free-tier","isDefault":true}],"ineligibleTiers":[{"reasonMessage":"Not available in your region"}]}"#),
                .init(status: 200, body: #"{"done":true,"response":{}}"#),
            ], tokens: tokens)

            await #expect {
                try await translator.translate(request)
            } throws: { error in
                guard case TranslationError.notConfigured(let message) = error else { return false }
                return message.contains("Not available in your region")
            }
            #expect(StubURLProtocol.requests.count == 2)
        }

        @Test func signInResolvesEmailAndProject() async throws {
            let session = StubURLProtocol.session([
                .init(status: 200, body: #"{"email":"me@gmail.com"}"#),
                .init(status: 200, body: #"{"cloudaicompanionProject":"proj-9","currentTier":{"id":"free-tier"}}"#),
            ])
            let response = OAuthTokenResponse(accessToken: "at", refreshToken: "rt", idToken: nil, expiresIn: 3600)

            let account = try await AntigravityAuth.resolveAccount(response, session: session, backend: Self.backend)

            #expect(account.email == "me@gmail.com")
            #expect(account.projectID == "proj-9")
            let load = StubURLProtocol.requests[1].request
            #expect(load.url?.absoluteString == "https://prod.example.com/v1internal:loadCodeAssist")
            #expect(load.value(forHTTPHeaderField: "Authorization") == "Bearer at")
            #expect(try StubURLProtocol.bodyJSON(1)["metadata"] as? [String: String] == ["ideType": "ANTIGRAVITY"])
        }

        @Test func signInOnboardsWhenNoProjectExists() async throws {
            let session = StubURLProtocol.session([
                .init(status: 200, body: #"{"email":"me@gmail.com"}"#),
                .init(status: 200, body: #"{"allowedTiers":[{"id":"legacy-tier"},{"id":"free-tier","isDefault":true}]}"#),
                .init(status: 200, body: #"{"done":true,"response":{"cloudaicompanionProject":{"id":"proj-new"}}}"#),
            ])
            let response = OAuthTokenResponse(accessToken: "at", refreshToken: "rt", idToken: nil, expiresIn: 3600)

            let account = try await AntigravityAuth.resolveAccount(response, session: session, backend: Self.backend)

            #expect(account.projectID == "proj-new")
            let onboard = StubURLProtocol.requests[2].request
            #expect(onboard.url?.absoluteString == "https://daily.example.com/v1internal:onboardUser")
            #expect(onboard.value(forHTTPHeaderField: "X-Goog-Api-Client") != nil)
            let body = try StubURLProtocol.bodyJSON(2)
            #expect(body["tier_id"] as? String == "free-tier")
            #expect(body["metadata"] as? [String: String] == ["ide_type": "ANTIGRAVITY", "ide_version": "9.9.9", "ide_name": "antigravity"])
        }

        @Test func versionComesFromUpdaterManifest() async throws {
            #expect(AntigravityVersion.parse("version: 2.10.3\nfiles:\n  - url: x\n") == "2.10.3")
            #expect(AntigravityVersion.parse("version: '3.0.1'\n") == "3.0.1")
            #expect(AntigravityVersion.parse("version: beta\n") == nil)

            let live = AntigravityVersion(session: StubURLProtocol.session([.init(status: 200, body: "version: 2.10.3\n")]))
            #expect(await live.current() == "2.10.3")
            #expect(StubURLProtocol.requests.first?.request.value(forHTTPHeaderField: "User-Agent") == "electron-builder")

            let offline = AntigravityVersion(session: StubURLProtocol.session([.init(status: 500, body: "")]))
            #expect(await offline.current() == AntigravityVersion.fallback)
        }
    }
}
