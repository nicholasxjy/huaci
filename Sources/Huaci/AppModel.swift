import AppKit
import Combine
import HuaciCore
import os

/// Wires settings, storage, selection capture and translation together.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let keychain: Keychain
    let chatGPTAuth: OAuthSession
    let antigravityAuth: OAuthSession
    let store: HistoryStore?
    private let session: URLSession
    let speech = Speech()

    @Published private(set) var hotKeyError: String?
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    /// Bumped whenever history or favorites change so open windows reload.
    @Published private(set) var dataVersion = 0
    @Published private(set) var storeError: String?
    /// Signed-in OAuth accounts, for display.
    @Published private(set) var accounts: [TranslationService: OAuthTokens] = [:]
    let configuration: ConfigurationLifecycle
    private var configurationChanges: AnyCancellable?
    /// Bumped each time the popup shows a result; onboarding's practice step watches it.
    @Published private(set) var popupResultCount = 0

    private(set) var flow: TranslationFlow!
    private(set) var popup: PopupController!
    /// Typed-text translation, separate from the hotkey popup so neither cancels the other.
    private(set) var inputFlow: TranslationFlow!
    private var popupIdentity: ConfigurationLifecycle.Identity?
    private var inputIdentity: ConfigurationLifecycle.Identity?
    let inputTranslation = InputTranslationState()
    let mainWindow = MainWindowState()
    private let capturer = SelectionCapturer(environment: SystemSelectionEnvironment(), pasteboard: SystemPasteboard())
    private let logger = Logger(subsystem: "app.huaci.Huaci", category: "app")

    init(settings: AppSettings? = nil, keychain: Keychain = Keychain(), storeURL: URL? = nil, session: URLSession = .shared) {
        let settings = settings ?? AppSettings()
        self.settings = settings
        self.keychain = keychain
        self.session = session
        configuration = ConfigurationLifecycle(settings: settings)
        chatGPTAuth = OAuthSession(provider: .chatGPT, store: KeychainCredentialStore(keychain: keychain, key: .chatGPTOAuth), session: session)
        antigravityAuth = OAuthSession(provider: .antigravity, store: KeychainCredentialStore(keychain: keychain, key: .antigravityOAuth), session: session)
        do {
            let url = try storeURL ?? HistoryStore.defaultURL()
            store = try HistoryStore(url: url)
        } catch {
            store = nil
            storeError = "无法打开本地数据库：\(error)"
            logger.error("Failed to open store: \(String(describing: error), privacy: .public)")
        }
        flow = TranslationFlow(
            capture: { [weak self] pid in await self?.capture(pid: pid) ?? .failure(.cancelled) },
            rules: { [weak self] in self?.settings.languageRules ?? LanguageRules() },
            makeTranslator: { [weak self] in
                guard let self else { throw TranslationError.cancelled }
                return try self.makeTranslator(identity: self.popupIdentity)
            },
            cache: store,
            onSuccess: { [weak self] result in self?.saveHistory(result) }
        )
        popup = PopupController(model: self)
        flow.presenter = popup
        inputFlow = TranslationFlow(
            capture: { _ in .failure(.cancelled) },
            rules: { [weak self] in self?.settings.languageRules ?? LanguageRules() },
            makeTranslator: { [weak self] in
                guard let self else { throw TranslationError.cancelled }
                return try self.makeTranslator(identity: self.inputIdentity)
            },
            cache: store,
            onSuccess: { [weak self] result in self?.saveHistory(result) }
        )
        inputTranslation.isFavoriteResult = { [weak self] result in self?.isFavorite(result) ?? false }
        inputFlow.presenter = inputTranslation
        refreshAccounts()
        configurationChanges = configuration.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: Translation

    func triggerTranslation() {
        refreshAccessibility()
        // An open result panel holds keyboard focus; hide it so a simulated
        // Command-C reaches the source app.
        popup.close()
        popup.prepare(anchor: NSEvent.mouseLocation)
        popupIdentity = configuration.identity(for: settings.activeService)
        flow.trigger(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private func capture(pid: pid_t?) async -> CaptureOutcome {
        // Accessibility requests to our own process would block the main thread.
        if pid == ProcessInfo.processInfo.processIdentifier {
            if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
               let range = Range(textView.selectedRange(), in: textView.string), !range.isEmpty {
                return .success(text: String(textView.string[range]), method: .accessibility)
            }
            return .failure(.copyTimedOut)
        }
        return await capturer.capture(expectedPID: pid)
    }

    private func makeTranslator(identity: ConfigurationLifecycle.Identity?) throws -> Translator {
        guard let identity, configuration.identity(for: identity.service) == identity else {
            throw TranslationError.cancelled
        }
        return try makeTranslator(snapshot: snapshot(for: identity.service))
    }

    /// Translates a sample with the form's service and immutable configuration.
    func testConnection(for service: TranslationService, identity: ConfigurationLifecycle.Identity) async {
        guard configuration.identity(for: service) == identity else { return }
        let snapshot = snapshot(for: service)
        await configuration.testConnection(snapshot.identity, isCurrent: { self.isCurrent(snapshot) }) {
            let request = TranslationRequest(text: "hello", kind: .word, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
            let result = try await self.makeTranslator(snapshot: snapshot).translate(request)
            return "连接正常 · hello → \(result.translation)"
        }
    }

    // MARK: Services

    /// Model of the active service, as shown in the popup header.
    var activeModelName: String {
        switch settings.activeService {
        case .personalAPI: return settings.personalModel.isEmpty ? "未设置模型" : settings.personalModel
        case .chatGPT: return settings.chatGPTModel
        case .antigravity: return settings.antigravityModel
        }
    }

    /// "ChatGPT 账号 · gpt-6-luna"
    var serviceLine: String {
        "\(settings.activeService.shortName) · \(activeModelName)"
    }

    /// Problems that stop lookups from working, most blocking first; shown in
    /// the menu bar menu.
    var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        if !accessibilityTrusted { items.append(.accessibility) }
        if let hotKeyError { items.append(.shortcut(hotKeyError)) }
        if !isConfigured(settings.activeService) { items.append(.service(settings.activeService)) }
        return items
    }

    func auth(for service: TranslationService) -> OAuthSession? {
        switch service {
        case .personalAPI: return nil
        case .chatGPT: return chatGPTAuth
        case .antigravity: return antigravityAuth
        }
    }

    /// Whether the service has credentials; the menu marks the others.
    func isConfigured(_ service: TranslationService) -> Bool {
        switch service {
        case .personalAPI: return keychain.contains(.personalAPIKey) && !settings.personalModel.isEmpty
        case .chatGPT, .antigravity: return accounts[service] != nil
        }
    }

    /// Opens the provider's sign-in page in the browser and waits for the redirect.
    func signIn(_ service: TranslationService) async throws {
        guard let auth = auth(for: service) else { return }
        configuration.invalidate(service)
        try await auth.signIn { url in
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        refreshAccounts()
        try Task.checkCancellation()
        NSApp.activate(ignoringOtherApps: true)
    }

    func signOut(_ service: TranslationService) async {
        configuration.invalidate(service)
        await auth(for: service)?.signOut()
        refreshAccounts()
    }

    /// Asks the service which models it offers and keeps the list for settings.
    func fetchModels(for service: TranslationService, identity: ConfigurationLifecycle.Identity) async {
        guard configuration.catalogIdentity(for: service) == identity else { return }
        let snapshot = snapshot(for: service, catalog: true)
        await configuration.fetchModels(snapshot.identity, isCurrent: { self.isCurrent(snapshot, catalog: true) }) {
            switch service {
            case .personalAPI:
                return try await ModelCatalog.personalAPI(baseURL: snapshot.personal.baseURL, apiKey: snapshot.personal.apiKey, session: self.session)
            case .chatGPT:
                return try await ModelCatalog.chatGPT(auth: self.chatGPTAuth, session: self.session)
            case .antigravity:
                return try await ModelCatalog.antigravity(auth: self.antigravityAuth, session: self.session)
            }
        }
    }

    @discardableResult
    func saveAPIKey(_ value: String) -> Bool {
        configuration.invalidate(.personalAPI)
        guard keychain.write(value, for: .personalAPIKey) else { return false }
        dataChanged()
        return true
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        configuration.invalidate(.personalAPI)
        guard keychain.delete(.personalAPIKey) else { return false }
        dataChanged()
        return true
    }

    private struct ServiceSnapshot {
        let identity: ConfigurationLifecycle.Identity
        let personal: PersonalAPIConfig
        let model: String
        let account: AccountIdentity
    }

    /// Account routing survives ordinary token refreshes; secrets never enter UI IDs.
    struct AccountIdentity: Equatable {
        let signedIn: Bool
        let email: String?
        let accountID: String?
        let projectID: String?

        init(_ tokens: OAuthTokens?) {
            signedIn = tokens != nil
            email = tokens?.email
            accountID = tokens?.accountID
            projectID = tokens?.projectID
        }
    }

    private func snapshot(for service: TranslationService, catalog: Bool = false) -> ServiceSnapshot {
        ServiceSnapshot(
            identity: catalog ? configuration.catalogIdentity(for: service) : configuration.identity(for: service),
            personal: PersonalAPIConfig(baseURL: settings.personalBaseURL,
                                        apiKey: service == .personalAPI ? keychain.read(.personalAPIKey) ?? "" : "",
                                        model: settings.personalModel),
            model: service == .chatGPT ? settings.chatGPTModel : settings.antigravityModel,
            account: AccountIdentity(auth(for: service)?.tokens)
        )
    }

    private func makeTranslator(snapshot: ServiceSnapshot) throws -> Translator {
        switch snapshot.identity.service {
        case .personalAPI: return try OpenAICompatibleTranslator(config: snapshot.personal, session: session)
        case .chatGPT: return try ChatGPTTranslator(auth: chatGPTAuth, model: snapshot.model, session: session)
        case .antigravity: return try AntigravityTranslator(auth: antigravityAuth, model: snapshot.model, session: session)
        }
    }

    private func isCurrent(_ snapshot: ServiceSnapshot, catalog: Bool = false) -> Bool {
        let service = snapshot.identity.service
        let identity = catalog ? configuration.catalogIdentity(for: service) : configuration.identity(for: service)
        guard identity == snapshot.identity else { return false }
        let matches = service == .personalAPI
            ? (keychain.read(.personalAPIKey) ?? "") == snapshot.personal.apiKey
            : AccountIdentity(auth(for: service)?.tokens) == snapshot.account
        if !matches { configuration.invalidate(service) }
        return matches
    }

    private func refreshAccounts() {
        var accounts: [TranslationService: OAuthTokens] = [:]
        for service in TranslationService.allCases {
            if let tokens = auth(for: service)?.tokens { accounts[service] = tokens }
        }
        for service in TranslationService.allCases where AccountIdentity(self.accounts[service]) != AccountIdentity(accounts[service]) {
            configuration.invalidate(service)
        }
        self.accounts = accounts
    }

    func retry() {
        popupIdentity = configuration.identity(for: settings.activeService)
        flow.retry()
    }

    /// Translates the popup's text into another language, for this lookup only.
    func retargetPopup(_ targetLanguage: String) {
        popupIdentity = configuration.identity(for: settings.activeService)
        flow.retarget(targetLanguage)
    }

    func cancelTranslation() {
        popupIdentity = nil
        flow.cancel()
    }

    func didShowPopupResult() {
        popupResultCount += 1
    }

    func translateInput() {
        inputIdentity = configuration.identity(for: settings.activeService)
        inputFlow.translate(text: inputTranslation.text, targetLanguage: inputTranslation.targetOverride)
    }

    /// Shows a popup result in the main window's translate tab for editing.
    func openInMainWindow(_ result: TranslationResult) {
        cancelInputTranslation()
        inputTranslation.text = result.sourceText
        inputTranslation.targetOverride = result.targetLanguage
        inputTranslation.show(result: result, requestID: UUID())
        WindowRouter.shared.showMain(.translate)
    }

    /// Asks the model again for a stored lookup, bypassing the cache.
    func retranslate(_ result: TranslationResult) {
        inputTranslation.text = result.sourceText
        inputTranslation.targetOverride = result.targetLanguage
        WindowRouter.shared.showMain(.translate)
        inputIdentity = configuration.identity(for: settings.activeService)
        inputFlow.translate(text: result.sourceText, targetLanguage: result.targetLanguage, useCache: false)
    }

    func retryInputTranslation() {
        inputIdentity = configuration.identity(for: settings.activeService)
        inputFlow.retry()
    }

    func cancelInputTranslation() {
        inputIdentity = nil
        inputFlow.cancel()
    }

    // MARK: History and favorites

    private func saveHistory(_ result: TranslationResult) {
        guard let store else { return }
        do {
            try store.addHistory(result)
            storeError = nil
            dataVersion += 1
        } catch {
            let message = "译文已保留，但保存历史失败：\(error.localizedDescription)"
            storeError = message
            AccessibilityAnnouncement.post(message)
            logger.error("Failed to save history: \(String(describing: error), privacy: .public)")
        }
    }

    func isFavorite(_ result: TranslationResult) -> Bool {
        guard let store, let word = result.word else { return false }
        return (try? store.isFavorite(headword: word.headword, targetLanguage: result.targetLanguage)) ?? false
    }

    /// Returns nil on failure so presenters keep their last known favorite state.
    @discardableResult
    func toggleFavorite(_ result: TranslationResult) -> Bool? {
        guard let store, let word = result.word else { return nil }
        do {
            let wasFavorite = try store.isFavorite(headword: word.headword, targetLanguage: result.targetLanguage)
            if wasFavorite {
                try store.removeFavorite(headword: word.headword, targetLanguage: result.targetLanguage)
            } else {
                try store.addFavorite(result)
            }
            storeError = nil
            dataVersion += 1
            return !wasFavorite
        } catch {
            let message = "收藏未能更新：\(error.localizedDescription)"
            storeError = message
            AccessibilityAnnouncement.post(message)
            logger.error("Failed to update favorite: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func dataChanged() {
        dataVersion += 1
    }

    // MARK: Hotkey and permission

    @discardableResult
    func applyShortcut(_ shortcut: Shortcut) -> HotKeyError? {
        switch HotKeyCenter.shared.register(shortcut) {
        case .success:
            settings.shortcut = shortcut
            hotKeyError = nil
            return nil
        case .failure(let error):
            hotKeyError = error.message
            return error
        }
    }

    /// Registers the saved shortcut at launch; on failure the error is shown in
    /// the menu and settings.
    func registerSavedShortcut() {
        if case .failure(let error) = HotKeyCenter.shared.register(settings.shortcut) {
            hotKeyError = error.message
        }
    }

    func suspendHotKey() {
        HotKeyCenter.shared.unregister()
    }

    func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }
}

enum AttentionItem: Equatable {
    case accessibility
    case shortcut(String)
    case service(TranslationService)

    var title: String {
        switch self {
        case .accessibility: return "辅助功能权限未开启"
        case .shortcut: return "快捷键不可用"
        case .service(let service): return service.usesOAuth ? "\(service.shortName)未登录" : "翻译服务未配置"
        }
    }

    var message: String {
        switch self {
        case .accessibility: return "没有它无法读取选中的文字。"
        case .shortcut(let error): return error
        case .service(let service): return "\(service.shortName)还不能使用，翻译会失败。"
        }
    }

    var actionTitle: String {
        switch self {
        case .accessibility: return "开启权限…"
        case .shortcut: return "更改快捷键…"
        case .service(let service): return service.usesOAuth ? "去登录…" : "去设置…"
        }
    }

    @MainActor func perform() {
        switch self {
        case .accessibility:
            SystemSelectionEnvironment.requestAccessibilityPrompt()
            SystemSelectionEnvironment.openAccessibilitySettings()
        case .shortcut:
            WindowRouter.shared.showSettings(.general)
        case .service:
            WindowRouter.shared.showSettings(.service)
        }
    }
}

/// Owns configuration-bound UI work without opening storage or reading credentials.
@MainActor
final class ConfigurationLifecycle: ObservableObject {
    struct Identity: Hashable {
        let service: TranslationService
        fileprivate let revision = UUID()
    }

    enum Connection: Equatable {
        case testing
        case finished(message: String, failed: Bool)
    }

    @Published private(set) var identities = Dictionary(uniqueKeysWithValues: TranslationService.allCases.map { ($0, Identity(service: $0)) })
    @Published private(set) var catalogIdentities = Dictionary(uniqueKeysWithValues: TranslationService.allCases.map { ($0, Identity(service: $0)) })
    @Published private(set) var connections: [TranslationService: Connection] = [:]
    @Published private(set) var remoteModels: [TranslationService: [RemoteModel]] = [:]
    @Published private(set) var loadingModels: Set<TranslationService> = []
    @Published private(set) var catalogErrors: [TranslationService: String] = [:]
    private var connectionAttempts: [TranslationService: UUID] = [:]
    private var catalogAttempts: [TranslationService: UUID] = [:]
    private var settingsChanges: Set<AnyCancellable> = []

    init(settings: AppSettings) {
        settings.$personalBaseURL.dropFirst().sink { [weak self] _ in self?.invalidate(.personalAPI) }.store(in: &settingsChanges)
        settings.$personalModel.dropFirst().sink { [weak self] _ in self?.invalidate(.personalAPI, catalog: false) }.store(in: &settingsChanges)
        settings.$chatGPTModel.dropFirst().sink { [weak self] _ in self?.invalidate(.chatGPT, catalog: false) }.store(in: &settingsChanges)
        settings.$antigravityModel.dropFirst().sink { [weak self] _ in self?.invalidate(.antigravity, catalog: false) }.store(in: &settingsChanges)
        settings.$activeService.dropFirst().sink { [weak self] _ in
            for service in TranslationService.allCases { self?.invalidate(service) }
        }.store(in: &settingsChanges)
    }

    func identity(for service: TranslationService) -> Identity { identities[service]! }

    func catalogIdentity(for service: TranslationService) -> Identity { catalogIdentities[service]! }

    func invalidate(_ service: TranslationService, catalog: Bool = true) {
        identities[service] = Identity(service: service)
        connections[service] = nil
        connectionAttempts[service] = nil
        guard catalog else { return }
        catalogIdentities[service] = Identity(service: service)
        remoteModels[service] = nil
        loadingModels.remove(service)
        catalogErrors[service] = nil
        catalogAttempts[service] = nil
    }

    func testConnection(_ identity: Identity, isCurrent: () -> Bool = { true },
                        operation: () async throws -> String) async {
        let service = identity.service
        guard self.identity(for: service) == identity, !Task.isCancelled, isCurrent() else { return }
        let attempt = UUID()
        connectionAttempts[service] = attempt
        connections[service] = .testing
        let feedback: Connection
        do {
            feedback = .finished(message: try await operation(), failed: false)
        } catch {
            feedback = .finished(message: (error as? TranslationError)?.userMessage ?? error.localizedDescription, failed: true)
        }
        guard self.identity(for: service) == identity, connectionAttempts[service] == attempt, isCurrent() else { return }
        connectionAttempts[service] = nil
        connections[service] = Task.isCancelled ? nil : feedback
    }

    func fetchModels(_ identity: Identity, isCurrent: () -> Bool = { true },
                     operation: () async throws -> [RemoteModel]) async {
        let service = identity.service
        guard catalogIdentity(for: service) == identity, !Task.isCancelled, isCurrent() else { return }
        let attempt = UUID()
        catalogAttempts[service] = attempt
        loadingModels.insert(service)
        catalogErrors[service] = nil
        let result: Result<[RemoteModel], Error>
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        guard catalogIdentity(for: service) == identity, catalogAttempts[service] == attempt, isCurrent() else { return }
        catalogAttempts[service] = nil
        loadingModels.remove(service)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let models): remoteModels[service] = models
        case .failure(let error):
            if let error = error as? TranslationError, case .cancelled = error { return }
            if error is CancellationError { return }
            catalogErrors[service] = (error as? TranslationError)?.userMessage ?? error.localizedDescription
        }
    }
}
