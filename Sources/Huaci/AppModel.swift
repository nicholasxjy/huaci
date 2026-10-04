import AppKit
import HuaciCore
import os

/// Wires settings, storage, selection capture and translation together.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let keychain = Keychain()
    let store: HistoryStore?
    let speech = Speech()

    @Published private(set) var hotKeyError: String?
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    /// Bumped whenever history or favorites change so open windows reload.
    @Published private(set) var dataVersion = 0
    @Published private(set) var storeError: String?

    private(set) var flow: TranslationFlow!
    private(set) var popup: PopupController!
    private let capturer = SelectionCapturer(environment: SystemSelectionEnvironment(), pasteboard: SystemPasteboard())
    private let logger = Logger(subsystem: "app.huaci.Huaci", category: "app")

    init() {
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
        let config = PersonalAPIConfig(
            baseURL: settings.personalBaseURL,
            apiKey: keychain.read(.personalAPIKey) ?? "",
            model: settings.personalModel
        )
        return try OpenAICompatibleTranslator(config: config)
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
