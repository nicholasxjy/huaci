import Foundation

public enum TranslationKind: String, Codable, Sendable {
    /// Single word, short phrase or idiom: shown as a dictionary entry.
    case word
    /// Sentence or paragraph: shown as a translation.
    case text
}

public struct LanguageOption: Hashable, Identifiable, Sendable {
    /// BCP-47 code, e.g. "zh-Hans".
    public let code: String
    /// Name shown in the UI.
    public let displayName: String
    /// Name used in prompts.
    public let englishName: String

    public var id: String { code }

    public init(code: String, displayName: String, englishName: String) {
        self.code = code
        self.displayName = displayName
        self.englishName = englishName
    }

    public static let all: [LanguageOption] = [
        .init(code: "zh-Hans", displayName: "简体中文", englishName: "Simplified Chinese"),
        .init(code: "zh-Hant", displayName: "繁體中文", englishName: "Traditional Chinese"),
        .init(code: "en", displayName: "English", englishName: "English"),
        .init(code: "ja", displayName: "日本語", englishName: "Japanese"),
        .init(code: "ko", displayName: "한국어", englishName: "Korean"),
        .init(code: "fr", displayName: "Français", englishName: "French"),
        .init(code: "de", displayName: "Deutsch", englishName: "German"),
        .init(code: "es", displayName: "Español", englishName: "Spanish"),
        .init(code: "it", displayName: "Italiano", englishName: "Italian"),
        .init(code: "pt", displayName: "Português", englishName: "Portuguese"),
        .init(code: "ru", displayName: "Русский", englishName: "Russian"),
    ]

    public static func named(_ code: String) -> LanguageOption {
        all.first { $0.code == code }
            ?? LanguageOption(code: code, displayName: code, englishName: code)
    }
}

public struct TranslationRequest: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let kind: TranslationKind
    /// Detected source language code, if known.
    public let sourceLanguage: String?
    public let targetLanguage: LanguageOption

    public init(id: UUID = UUID(), text: String, kind: TranslationKind, sourceLanguage: String?, targetLanguage: LanguageOption) {
        self.id = id
        self.text = text
        self.kind = kind
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public struct WordSense: Codable, Equatable, Sendable {
    public var pos: String?
    public var meanings: [String]

    public init(pos: String?, meanings: [String]) {
        self.pos = pos
        self.meanings = meanings
    }
}

public struct WordExample: Codable, Equatable, Sendable {
    public var source: String
    public var translation: String?

    public init(source: String, translation: String?) {
        self.source = source
        self.translation = translation
    }
}

public struct WordEntry: Codable, Equatable, Sendable {
    public var headword: String
    public var phonetic: String?
    public var senses: [WordSense]
    public var examples: [WordExample]

    public init(headword: String, phonetic: String?, senses: [WordSense], examples: [WordExample]) {
        self.headword = headword
        self.phonetic = phonetic
        self.senses = senses
        self.examples = examples
    }
}

public struct TranslationResult: Codable, Equatable, Sendable {
    public var kind: TranslationKind
    public var sourceText: String
    public var sourceLanguage: String?
    public var targetLanguage: String
    /// Main translation; for words, the short primary meaning.
    public var translation: String
    /// Present when `kind == .word`.
    public var word: WordEntry?

    public init(kind: TranslationKind, sourceText: String, sourceLanguage: String?, targetLanguage: String, translation: String, word: WordEntry?) {
        self.kind = kind
        self.sourceText = sourceText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.translation = translation
        self.word = word
    }
}

/// Where translations are sent. Each service keeps its own credentials, so
/// switching does not require signing in again.
public enum TranslationService: String, CaseIterable, Identifiable, Sendable {
    case personalAPI
    case chatGPT
    case antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .personalAPI: return "个人 API（OpenAI 兼容）"
        case .chatGPT: return "ChatGPT 账号"
        case .antigravity: return "Antigravity（Google 账号）"
        }
    }

    /// Suggested models; the first is the default.
    public var suggestedModels: [String] {
        switch self {
        case .personalAPI: return []
        case .chatGPT: return ["gpt-5.4-mini", "gpt-5.4", "gpt-5.5"]
        case .antigravity: return ["gemini-3-flash", "gemini-3.1-pro-low", "claude-sonnet-4-6"]
        }
    }
}
