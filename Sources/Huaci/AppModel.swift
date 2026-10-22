import AppKit
import HuaciCore
import os

/// Wires settings, storage, selection capture and translation together.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let keychain = Keychain()
    let chatGPTAuth: OAuthSession
    let antigravityAuth: OAuthSession
    let store: HistoryStore?
    let speech = Speech()

    @Published private(set) var hotKeyError: String?
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    /// Bumped whenever history or favorites change so open windows reload.
    @Published private(set) var dataVersion = 0
    @Published private(set) var storeError: String?
    /// Signed-in OAuth accounts, for display.
    @Published private(set) var accounts: [TranslationService: OAuthTokens] = [:]
    /// Models fetched from each service this run, offered in settings.
    @Published private(set) var remoteModels: [TranslationService: [RemoteModel]] = [:]
    /// Bumped each time the popup shows a result; onboarding's practice step watches it.
    @Published private(set) var popupResultCount = 0

    private(set) var flow: TranslationFlow!
    private(set) var popup: PopupController!
    /// Typed-text translation, separate from the hotkey popup so neither cancels the other.
    private(set) var inputFlow: TranslationFlow!
    let inputTranslation = InputTranslationState()
    let mainWindow = MainWindowState()
    private let capturer = SelectionCapturer(environment: SystemSelectionEnvironment(), pasteboard: SystemPasteboard())
    private let logger = Logger(subsystem: "app.huaci.Huaci", category: "app")

    init() {
        chatGPTAuth = OAuthSession(provider: .chatGPT, store: KeychainCredentialStore(keychain: keychain, key: .chatGPTOAuth))
        antigravityAuth = OAuthSession(provider: .antigravity, store: KeychainCredentialStore(keychain: keychain, key: .antigravityOAuth))
        do {
            store = try HistoryStore(url: HistoryStore.defaultURL())
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
                return try self.makeTranslator()
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
                return try self.makeTranslator()
            },
            cache: store,
            onSuccess: { [weak self] result in self?.saveHistory(result) }
        )
        inputTranslation.isFavoriteResult = { [weak self] result in self?.isFavorite(result) ?? false }
        inputFlow.presenter = inputTranslation
        refreshAccounts()
    }

    // MARK: Translation

    func triggerTranslation() {
        refreshAccessibility()
        // An open result panel holds keyboard focus; hide it so a simulated
        // Command-C reaches the source app.
        popup.close()
        popup.prepare(anchor: NSEvent.mouseLocation)
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

    func makeTranslator() throws -> Translator {
        switch settings.activeService {
        case .personalAPI:
            let config = PersonalAPIConfig(
                baseURL: settings.personalBaseURL,
                apiKey: keychain.read(.personalAPIKey) ?? "",
                model: settings.personalModel
            )
            return try OpenAICompatibleTranslator(config: config)
        case .chatGPT:
            return try ChatGPTTranslator(auth: chatGPTAuth, model: settings.chatGPTModel)
        case .antigravity:
            return try AntigravityTranslator(auth: antigravityAuth, model: settings.antigravityModel)
        }
    }

    /// Translates a sample word with the active service.
    func testConnection() async -> (message: String, failed: Bool) {
        let request = TranslationRequest(text: "hello", kind: .word, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        do {
            let result = try await makeTranslator().translate(request)
            return ("连接正常 · hello → \(result.translation)", false)
        } catch {
            return ((error as? TranslationError)?.userMessage ?? error.localizedDescription, true)
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
        try await auth.signIn { url in
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        refreshAccounts()
        NSApp.activate(ignoringOtherApps: true)
    }

    func signOut(_ service: TranslationService) async {
        await auth(for: service)?.signOut()
        remoteModels[service] = nil
        refreshAccounts()
    }

    /// Asks the service which models it offers and keeps the list for settings.
    func fetchModels(for service: TranslationService) async throws {
        let models: [RemoteModel]
        switch service {
        case .personalAPI:
            models = try await ModelCatalog.personalAPI(baseURL: settings.personalBaseURL, apiKey: keychain.read(.personalAPIKey) ?? "")
        case .chatGPT:
            models = try await ModelCatalog.chatGPT(auth: chatGPTAuth)
        case .antigravity:
            models = try await ModelCatalog.antigravity(auth: antigravityAuth)
        }
        remoteModels[service] = models
    }

    private func refreshAccounts() {
        var accounts: [TranslationService: OAuthTokens] = [:]
        for service in TranslationService.allCases {
            if let tokens = auth(for: service)?.tokens { accounts[service] = tokens }
        }
        self.accounts = accounts
    }

    func retry() {
        flow.retry()
    }

    /// Translates the popup's text into another language, for this lookup only.
    func retargetPopup(_ targetLanguage: String) {
        flow.retarget(targetLanguage)
    }

    func cancelTranslation() {
        flow.cancel()
    }

    func didShowPopupResult() {
        popupResultCount += 1
    }

    func translateInput() {
        inputFlow.translate(text: inputTranslation.text, targetLanguage: inputTranslation.targetOverride)
    }

    /// Shows a popup result in the main window's translate tab for editing.
    func openInMainWindow(_ result: TranslationResult) {
        inputFlow.cancel()
        inputTranslation.text = result.sourceText
        inputTranslation.show(result: result, requestID: UUID())
        WindowRouter.shared.showMain(.translate)
    }

    /// Asks the model again for a stored lookup, bypassing the cache.
    func retranslate(_ result: TranslationResult) {
        inputTranslation.text = result.sourceText
        inputTranslation.targetOverride = result.targetLanguage
        WindowRouter.shared.showMain(.translate)
        inputFlow.translate(text: result.sourceText, targetLanguage: result.targetLanguage, useCache: false)
    }

    func retryInputTranslation() {
        inputFlow.retry()
    }

    func cancelInputTranslation() {
        inputFlow.cancel()
    }

    // MARK: History and favorites

    private func saveHistory(_ result: TranslationResult) {
        guard let store else { return }
        do {
            try store.addHistory(result)
            dataVersion += 1
        } catch {
            logger.error("Failed to save history: \(String(describing: error), privacy: .public)")
        }
    }

    func isFavorite(_ result: TranslationResult) -> Bool {
        guard let store, let word = result.word else { return false }
        return (try? store.isFavorite(headword: word.headword, targetLanguage: result.targetLanguage)) ?? false
    }

    /// Returns the new favorite state.
    @discardableResult
    func toggleFavorite(_ result: TranslationResult) -> Bool {
        guard let store, let word = result.word else { return false }
        do {
            if isFavorite(result) {
                try store.removeFavorite(headword: word.headword, targetLanguage: result.targetLanguage)
            } else {
                try store.addFavorite(result)
            }
            dataVersion += 1
        } catch {
            logger.error("Failed to update favorite: \(String(describing: error), privacy: .public)")
        }
        return isFavorite(result)
    }

    /// Drops stored translations so the next lookups ask the model again.
    func clearTranslationCache() {
        do {
            try store?.clearTranslationCache()
            dataVersion += 1
        } catch {
            logger.error("Failed to clear translation cache: \(String(describing: error), privacy: .public)")
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
