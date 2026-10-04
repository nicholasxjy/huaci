import Foundation
import Testing
@testable import HuaciCore

extension TranslatorTests {
    @Suite struct Models {
        @Test func personalAPIListsModelsFromBaseURL() async throws {
            let session = StubURLProtocol.session([.init(status: 200, body: #"{"object":"list","data":[{"id":"gpt-b"},{"id":"gpt-a"}]}"#)])

            let models = try await ModelCatalog.personalAPI(baseURL: "https://api.example.com/v1/", apiKey: " sk-1 ", session: session)

            #expect(models.map(\.id) == ["gpt-a", "gpt-b"])
            let sent = try #require(StubURLProtocol.requests.first).request
            #expect(sent.httpMethod == "GET")
            #expect(sent.url?.absoluteString == "https://api.example.com/v1/models")
            #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        }

        @Test func personalAPIAcceptsFullCompletionsURL() async throws {
            let session = StubURLProtocol.session([.init(status: 200, body: #"{"data":[{"id":"m"}]}"#)])

            _ = try await ModelCatalog.personalAPI(baseURL: "https://host/openai/v1/chat/completions", apiKey: "k", session: session)

            #expect(StubURLProtocol.requests.first?.request.url?.absoluteString == "https://host/openai/v1/models")
        }

        @Test func personalAPIErrors() async throws {
            let session = StubURLProtocol.session([.init(status: 401, body: "")])
            await #expect(throws: TranslationError.unauthorized) {
                try await ModelCatalog.personalAPI(baseURL: "https://api.example.com/v1", apiKey: "k", session: session)
            }
            await #expect(throws: TranslationError.self) {
                try await ModelCatalog.personalAPI(baseURL: "not a url", apiKey: "k", session: session)
            }
            await #expect(throws: TranslationError.self) {
                try await ModelCatalog.personalAPI(baseURL: "https://api.example.com/v1", apiKey: " ", session: session)
            }
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func chatGPTListsVisibleModelsByPriority() async throws {
            let session = StubURLProtocol.session([.init(status: 200, body: """
            {"models":[
              {"slug":"gpt-b","display_name":"GPT-B","visibility":"list","priority":5},
              {"slug":"hidden","display_name":"Hidden","visibility":"hide","priority":1},
              {"slug":"gpt-a","display_name":"GPT-A","visibility":"list","priority":2}
            ]}
            """)])
            let auth = OAuthSession(provider: .chatGPT, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)

            let models = try await ModelCatalog.chatGPT(auth: auth, session: session)

            #expect(models == [RemoteModel(id: "gpt-a", displayName: "GPT-A"), RemoteModel(id: "gpt-b", displayName: "GPT-B")])
            let sent = try #require(StubURLProtocol.requests.first).request
            let components = try #require(sent.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            #expect(components.host == "chatgpt.com")
            #expect(components.path == "/backend-api/codex/models")
            #expect(components.queryItems?.first { $0.name == "client_version" }?.value?.isEmpty == false)
            #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer at")
            #expect(sent.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
        }

        @Test func antigravityListsModelsForProject() async throws {
            let session = StubURLProtocol.session([
                .init(status: 503, body: ""),
                .init(status: 200, body: """
                {"models":{
                  "gemini-3-flash":{"displayName":"Gemini 3 Flash"},
                  "claude-sonnet-4-6":{"displayName":"Claude Sonnet 4.6"},
                  "chat_20706":{}
                }}
                """),
            ])
            let auth = OAuthSession(provider: .antigravity, store: MemoryCredentialStore(TranslatorTests.freshTokens), session: session)
            let endpoints = [URL(string: "https://daily.example.com")!, URL(string: "https://prod.example.com")!]

            let models = try await ModelCatalog.antigravity(auth: auth, session: session, endpoints: endpoints)

            #expect(models == [
                RemoteModel(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
                RemoteModel(id: "gemini-3-flash", displayName: "Gemini 3 Flash"),
            ])
            let sent = StubURLProtocol.requests.map(\.request)
            #expect(sent.map { $0.url?.absoluteString } == [
                "https://daily.example.com/v1internal:fetchAvailableModels",
                "https://prod.example.com/v1internal:fetchAvailableModels",
            ])
            #expect(sent.last?.httpMethod == "POST")
            #expect(try StubURLProtocol.bodyJSON(1)["project"] as? String == "proj-1")
        }
    }
}
