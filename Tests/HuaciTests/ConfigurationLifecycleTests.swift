import Foundation
import HuaciCore
import Testing
@testable import Huaci

@Suite("Configuration lifecycle")
@MainActor
struct ConfigurationLifecycleTests {
    @MainActor
    private final class Preferences {
        let defaults: UserDefaults
        let suite = "Huaci-ConfigurationLifecycleTests-\(UUID())"
        let settings: AppSettings

        init() {
            defaults = UserDefaults(suiteName: suite)!
            settings = AppSettings(defaults: defaults)
        }

        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    /// A deliberately cancellation-insensitive provider, released explicitly by each test.
    @MainActor
    private final class Reply<Value> {
        private var continuation: CheckedContinuation<Value, Error>?
        private var started: CheckedContinuation<Void, Never>?

        func call() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if continuation != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(_ result: Result<Value, Error>) {
            continuation!.resume(with: result)
            continuation = nil
        }
    }

    @Test(arguments: [false, true])
    func endpointChangeRejectsLateConnectionFeedback(fails: Bool) async {
        let preferences = Preferences()
        let settings = preferences.settings
        let owner = ConfigurationLifecycle(settings: settings)
        let reply = Reply<String>()
        let oldIdentity = owner.identity(for: .personalAPI)
        let task = Task { await owner.testConnection(oldIdentity) { try await reply.call() } }
        await reply.waitUntilStarted()
        #expect(owner.connections[.personalAPI] == .testing)
        settings.personalBaseURL = "https://replacement.invalid/v1"
        #expect(owner.identity(for: .personalAPI) != oldIdentity)
        reply.finish(fails ? .failure(TranslationError.network("old endpoint")) : .success("old endpoint"))
        await task.value
        #expect(owner.connections[.personalAPI] == nil)
    }

    @Test
    func returningToOldEndpointDoesNotReviveItsAttempt() async {
        let preferences = Preferences()
        let settings = preferences.settings
        let owner = ConfigurationLifecycle(settings: settings)
        let originalURL = settings.personalBaseURL
        let reply = Reply<String>()
        let identity = owner.identity(for: .personalAPI)
        let task = Task { await owner.testConnection(identity) { try await reply.call() } }
        await reply.waitUntilStarted()
        settings.personalBaseURL = "https://replacement.invalid"
        settings.personalBaseURL = originalURL
        reply.finish(.success("stale"))
        await task.value
        #expect(owner.connections[.personalAPI] == nil)
    }

    @Test
    func newerConnectionRetainsItsFeedbackWhenOldAttemptFinishes() async {
        let preferences = Preferences()
        let settings = preferences.settings
        let owner = ConfigurationLifecycle(settings: settings)
        let reply = Reply<String>()
        let identity = owner.identity(for: .chatGPT)
        let old = Task { await owner.testConnection(identity) { try await reply.call() } }
        await reply.waitUntilStarted()
        await owner.testConnection(identity) { "new" }
        reply.finish(.failure(TranslationError.network("old")))
        await old.value
        #expect(owner.connections[.chatGPT] == .finished(message: "new", failed: false))
    }

    @Test
    func cancelledConnectionCannotPublishUncooperativeReply() async {
        let preferences = Preferences()
        let settings = preferences.settings
        let owner = ConfigurationLifecycle(settings: settings)
        let reply = Reply<String>()
        let task = Task { await owner.testConnection(owner.identity(for: .personalAPI)) { try await reply.call() } }
        await reply.waitUntilStarted()
        task.cancel()
        reply.finish(.success("cancelled"))
        await task.value
        #expect(owner.connections[.personalAPI] == nil)
    }

    @Test(arguments: TranslationService.allCases)
    func credentialChangeInvalidatesCatalogAndRejectsLateReply(service: TranslationService) async {
        let preferences = Preferences()
        let settings = preferences.settings
        let owner = ConfigurationLifecycle(settings: settings)
        await owner.fetchModels(owner.catalogIdentity(for: service)) { [RemoteModel(id: "old")] }
        #expect(owner.remoteModels[service]?.first?.id == "old")
        let reply = Reply<[RemoteModel]>()
        let identity = owner.catalogIdentity(for: service)
        let old = Task { await owner.fetchModels(identity) { try await reply.call() } }
        await reply.waitUntilStarted()
        owner.invalidate(service) // The same boundary used for API-key saves/deletes and OAuth account changes.
        #expect(owner.remoteModels[service] == nil)
        await owner.fetchModels(owner.catalogIdentity(for: service)) { [RemoteModel(id: "new")] }
        reply.finish(.success([RemoteModel(id: "stale")]))
        await old.value
        #expect(owner.remoteModels[service]?.map(\.id) == ["new"])
        #expect(!owner.loadingModels.contains(service))
    }

    @Test
    func oldCatalogFailureCannotClearReplacementLoadingState() async {
        let preferences = Preferences()
        let settings = preferences.settings
        let owner = ConfigurationLifecycle(settings: settings)
        let first = Reply<[RemoteModel]>()
        let second = Reply<[RemoteModel]>()
        let identity = owner.catalogIdentity(for: .personalAPI)
        let old = Task { await owner.fetchModels(identity) { try await first.call() } }
        await first.waitUntilStarted()
        let new = Task { await owner.fetchModels(identity) { try await second.call() } }
        await second.waitUntilStarted()
        first.finish(.failure(TranslationError.network("old")))
        await old.value
        #expect(owner.loadingModels.contains(.personalAPI))
        #expect(owner.catalogErrors[.personalAPI] == nil)
        second.finish(.success([RemoteModel(id: "new")]))
        await new.value
        #expect(owner.remoteModels[.personalAPI]?.first?.id == "new")
        #expect(!owner.loadingModels.contains(.personalAPI))
    }

    @Test
    func modelChangesClearFeedbackButKeepModelIndependentCatalog() async {
        let preferences = Preferences()
        let settings = preferences.settings
        let owner = ConfigurationLifecycle(settings: settings)
        for service in TranslationService.allCases {
            await owner.testConnection(owner.identity(for: service)) { "ok" }
            await owner.fetchModels(owner.catalogIdentity(for: service)) { [RemoteModel(id: "available")] }
        }
        let catalogs = owner.catalogIdentities
        settings.personalModel = "another-personal-model"
        settings.chatGPTModel = "another-chatgpt-model"
        settings.antigravityModel = "another-antigravity-model"
        #expect(owner.connections.isEmpty)
        #expect(owner.catalogIdentities == catalogs)
        #expect(owner.remoteModels.count == TranslationService.allCases.count)
    }

    @Test
    func serviceSwitchClearsFeedbackAndCatalogOwnership() async {
        let preferences = Preferences()
        let settings = preferences.settings
        let owner = ConfigurationLifecycle(settings: settings)
        let reply = Reply<[RemoteModel]>()
        let identity = owner.catalogIdentity(for: .personalAPI)
        let old = Task { await owner.fetchModels(identity) { try await reply.call() } }
        await reply.waitUntilStarted()
        await owner.testConnection(owner.identity(for: .personalAPI)) { "ok" }
        settings.activeService = .chatGPT
        #expect(owner.connections.isEmpty)
        reply.finish(.success([RemoteModel(id: "stale")]))
        await old.value
        #expect(owner.remoteModels.isEmpty)
    }

    @Test
    func externalCredentialCheckCanRejectSuccessAndInvalidateCatalog() async {
        let preferences = Preferences()
        let settings = preferences.settings
        let owner = ConfigurationLifecycle(settings: settings)
        let reply = Reply<[RemoteModel]>()
        var credentialMatches = true
        let identity = owner.catalogIdentity(for: .chatGPT)
        let task = Task {
            await owner.fetchModels(identity, isCurrent: {
                if !credentialMatches { owner.invalidate(.chatGPT) }
                return credentialMatches
            }) { try await reply.call() }
        }
        await reply.waitUntilStarted()
        credentialMatches = false
        reply.finish(.success([RemoteModel(id: "stale")]))
        await task.value
        #expect(owner.remoteModels[.chatGPT] == nil)
        #expect(!owner.loadingModels.contains(.chatGPT))
        #expect(owner.catalogIdentity(for: .chatGPT) != identity)
    }

    @Test
    func tokenRefreshKeepsAccountIdentityButAccountRoutingChangesDoNot() {
        let tokens = OAuthTokens(accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                                 expiresAt: .distantPast, email: "test@example.invalid",
                                 accountID: "test-account", projectID: "test-project")
        let identity = AppModel.AccountIdentity(tokens)
        var refreshed = tokens
        refreshed.accessToken = "synthetic-refreshed-access"
        refreshed.refreshToken = "synthetic-rotated-refresh"
        refreshed.expiresAt = .distantFuture
        #expect(AppModel.AccountIdentity(refreshed) == identity)
        #expect(AppModel.AccountIdentity(nil) != identity)
        var replacement = refreshed
        replacement.accountID = "another-account"
        #expect(AppModel.AccountIdentity(replacement) != identity)
        replacement = refreshed
        replacement.email = "another@example.invalid"
        #expect(AppModel.AccountIdentity(replacement) != identity)
        replacement = refreshed
        replacement.projectID = "another-project"
        #expect(AppModel.AccountIdentity(replacement) != identity)
    }
}
