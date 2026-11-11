import AppKit
import HuaciCore
import SwiftUI
import Testing
@testable import Huaci

private final class CatalogRecordingProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func session() -> URLSession {
        lock.withLock { recorded = [] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogRecordingProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"test-model"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct CatalogPrivacyTests {
    @MainActor
    private final class Fixture {
        let suite = "app.huaci.catalog-privacy.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-catalog-\(UUID().uuidString)")
        let defaults: UserDefaults
        let keychain: Keychain
        let model: AppModel

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            keychain = Keychain(service: suite)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settings = AppSettings(defaults: defaults)
            settings.personalBaseURL = "https://proxy.example.com/v1"
            settings.personalModel = "test-model"
            #expect(keychain.write("synthetic-catalog-key", for: .personalAPIKey))
            model = AppModel(settings: settings, keychain: keychain, storeURL: directory.appendingPathComponent("test.sqlite"),
                             session: CatalogRecordingProtocol.session())
        }

        deinit {
            keychain.delete(.personalAPIKey)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func editingHostsNeverAutomaticallySendsSavedKey() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        let content = Form {
            ModelPicker(service: .personalAPI, model: .constant("test-model"), prompt: "model", canFetch: true)
        }.environmentObject(fixture.model)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        await settle()
        #expect(CatalogRecordingProtocol.requests.isEmpty)

        for url in ["https://proxy.example.co/v1", "https://proxy.example.c/v1", "https://proxy.example.net/v1"] {
            fixture.model.settings.personalBaseURL = url
            await settle()
            #expect(CatalogRecordingProtocol.requests.isEmpty, "Editing a hostname must not send the saved credential")
        }
    }

    @Test func submittedTranslationCannotSendSavedKeyToAnEditedHost() async throws {
        let fixture = try Fixture()
        fixture.model.inputTranslation.text = "A complete translation."

        fixture.model.translateInput()
        let requestID = try #require(fixture.model.inputFlow.currentRequestID)
        fixture.model.settings.personalBaseURL = "https://proxy.example.co/v1"
        await settle()

        #expect(CatalogRecordingProtocol.requests.isEmpty)
        #expect(fixture.model.inputTranslation.result == nil)
        #expect(fixture.model.inputFlow.state == .failed(requestID, .translation(.cancelled)))
    }

    @Test func explicitRequestsCannotUseAnEditedHostRevision() async throws {
        let fixture = try Fixture()
        let oldCatalog = fixture.model.configuration.catalogIdentity(for: .personalAPI)
        fixture.model.settings.personalBaseURL = "https://proxy.example.net/v1"

        await fixture.model.fetchModels(for: .personalAPI, identity: oldCatalog)
        #expect(CatalogRecordingProtocol.requests.isEmpty)

        let current = fixture.model.configuration.catalogIdentity(for: .personalAPI)
        await fixture.model.fetchModels(for: .personalAPI, identity: current)
        let requests = CatalogRecordingProtocol.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "proxy.example.net")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-catalog-key")
        #expect(fixture.model.configuration.remoteModels[.personalAPI]?.map(\.id) == ["test-model"])

        let oldConnection = fixture.model.configuration.identity(for: .personalAPI)
        fixture.model.settings.personalBaseURL = "https://different.example.com/v1"
        await fixture.model.testConnection(for: .personalAPI, identity: oldConnection)
        #expect(CatalogRecordingProtocol.requests.count == 1)
        #expect(fixture.model.configuration.connections[.personalAPI] == nil)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }
}
