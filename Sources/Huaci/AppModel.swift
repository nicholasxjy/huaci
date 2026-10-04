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

    private(set) var flow: TranslationFlow!
    private(set) var popup: PopupController!
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
            onSuccess: { [weak self] result in self?.saveHistory(result) }
        )
        popup = PopupController(model: self)
        flow.presenter = popup
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
            return ("连接成功：hello → \(result.translation)", false)
        } catch {
            return ((error as? TranslationError)?.userMessage ?? error.localizedDescription, true)
        }
    }

    // MARK: Services

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
        case .personalAPI: return keychain.read(.personalAPIKey) != nil && !settings.personalModel.isEmpty
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
        refreshAccounts()
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

    func cancelTranslation() {
        flow.cancel()
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
        accessibilityTrusted = AXIsProcessTrusted()
    }
}
