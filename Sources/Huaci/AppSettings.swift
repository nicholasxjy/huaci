import Foundation
import HuaciCore

/// Non-secret preferences in UserDefaults. The API key lives in the Keychain
/// and is accessed through `Keychain` directly.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var personalBaseURL: String { didSet { defaults.set(personalBaseURL, forKey: Keys.personalBaseURL) } }
    @Published var personalModel: String { didSet { defaults.set(personalModel, forKey: Keys.personalModel) } }
    @Published var foreignTarget: String { didSet { defaults.set(foreignTarget, forKey: Keys.foreignTarget) } }
    @Published var chineseTarget: String { didSet { defaults.set(chineseTarget, forKey: Keys.chineseTarget) } }
    @Published var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) } }
    @Published var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: Keys.shortcut) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        personalBaseURL = defaults.string(forKey: Keys.personalBaseURL) ?? "https://api.openai.com/v1"
        personalModel = defaults.string(forKey: Keys.personalModel) ?? ""
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
        static let personalBaseURL = "personalBaseURL"
        static let personalModel = "personalModel"
        static let foreignTarget = "foreignTarget"
        static let chineseTarget = "chineseTarget"
        static let onboardingCompleted = "onboardingCompleted"
        static let shortcut = "shortcut"
    }
}
