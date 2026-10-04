import Foundation
import HuaciCore

/// Non-secret preferences in UserDefaults. The API key and OAuth tokens live in
/// the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var activeService: TranslationService { didSet { defaults.set(activeService.rawValue, forKey: Keys.activeService) } }
    @Published var personalBaseURL: String { didSet { defaults.set(personalBaseURL, forKey: Keys.personalBaseURL) } }
    @Published var personalModel: String { didSet { defaults.set(personalModel, forKey: Keys.personalModel) } }
    @Published var chatGPTModel: String { didSet { defaults.set(chatGPTModel, forKey: Keys.chatGPTModel) } }
    @Published var antigravityModel: String { didSet { defaults.set(antigravityModel, forKey: Keys.antigravityModel) } }
    @Published var foreignTarget: String { didSet { defaults.set(foreignTarget, forKey: Keys.foreignTarget) } }
    @Published var chineseTarget: String { didSet { defaults.set(chineseTarget, forKey: Keys.chineseTarget) } }
    @Published var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) } }
    @Published var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: Keys.shortcut) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeService = defaults.string(forKey: Keys.activeService).flatMap(TranslationService.init(rawValue:)) ?? .personalAPI
        personalBaseURL = defaults.string(forKey: Keys.personalBaseURL) ?? "https://api.openai.com/v1"
        personalModel = defaults.string(forKey: Keys.personalModel) ?? ""
        chatGPTModel = defaults.string(forKey: Keys.chatGPTModel) ?? TranslationService.chatGPT.suggestedModels[0]
        antigravityModel = defaults.string(forKey: Keys.antigravityModel) ?? TranslationService.antigravity.suggestedModels[0]
        foreignTarget = defaults.string(forKey: Keys.foreignTarget) ?? "zh-Hans"
        chineseTarget = defaults.string(forKey: Keys.chineseTarget) ?? "en"
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        shortcut = defaults.data(forKey: Keys.shortcut).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            ?? .defaultShortcut
    }

    var languageRules: LanguageRules {
        LanguageRules(foreignTarget: foreignTarget, chineseTarget: chineseTarget)
    }

    private enum Keys {
        static let activeService = "activeService"
        static let chatGPTModel = "chatGPTModel"
        static let antigravityModel = "antigravityModel"
        static let personalBaseURL = "personalBaseURL"
        static let personalModel = "personalModel"
        static let foreignTarget = "foreignTarget"
        static let chineseTarget = "chineseTarget"
        static let onboardingCompleted = "onboardingCompleted"
        static let shortcut = "shortcut"
    }
}
