import Foundation
import NaturalLanguage

/// Which language selected text is translated into, by source language.
public struct LanguageRules: Equatable, Sendable {
    /// Target for any non-Chinese source.
    public var foreignTarget: String
    /// Target for Chinese source.
    public var chineseTarget: String

    public init(foreignTarget: String = "zh-Hans", chineseTarget: String = "en") {
        self.foreignTarget = foreignTarget
        self.chineseTarget = chineseTarget
    }
}

public struct TextAnalysis: Equatable, Sendable {
    public var text: String
    public var kind: TranslationKind
    public var sourceLanguage: String?
    public var isChinese: Bool
    public var targetLanguage: String
}

public enum TextAnalyzer {
    /// Longest input still treated as a dictionary lookup.
    public static let maxWordLength = 48
    /// Most whitespace-separated tokens still treated as a phrase.
    public static let maxPhraseTokens = 3
    /// Most Chinese characters still treated as a word.
    public static let maxChineseWordCharacters = 6

    /// Returns nil when the text has nothing translatable (empty, whitespace,
    /// digits or punctuation only).
    public static func analyze(_ raw: String, rules: LanguageRules) -> TextAnalysis? {
        let text = normalize(raw)
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }

        let isChinese = isMostlyChinese(text)
        let language = isChinese ? "zh" : detectLanguage(text)
        var target = isChinese ? rules.chineseTarget : rules.foreignTarget
        // Same-language rule (e.g. Japanese source with Japanese target) would be
        // a no-op; fall back to the Chinese default instead.
        if let language, !isChinese, target.hasPrefix(language) {
            target = target.hasPrefix("zh") ? "en" : "zh-Hans"
        }

        return TextAnalysis(
            text: text,
            kind: classify(text, isChinese: isChinese),
            sourceLanguage: language,
            isChinese: isChinese,
            targetLanguage: target
        )
    }

    /// Trims surrounding whitespace and unifies line breaks while keeping
    /// paragraph structure.
    public static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Chinese when Han characters outnumber words in other scripts and no kana is
    /// present. Counting Latin text by words keeps mixed text such as
    /// "我今天用了 React hooks" on the Chinese side.
    public static func isMostlyChinese(_ text: String) -> Bool {
        var han = 0
        var kana = 0
        var otherWords = 0
        var inOtherWord = false
        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                han += 1
                inOtherWord = false
            } else if isKana(scalar) {
                kana += 1
                inOtherWord = false
            } else if CharacterSet.letters.contains(scalar) {
                if !inOtherWord { otherWords += 1 }
                inOtherWord = true
            } else if scalar == "'" || scalar == "-" || scalar == "’" {
                continue
            } else {
                inOtherWord = false
            }
        }
        return han > 0 && kana == 0 && han >= otherWords
    }

    public static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// Classifies by structure rather than length alone: sentence punctuation or
    /// line breaks mean text; few tokens mean a word or phrase.
    public static func classify(_ text: String, isChinese: Bool) -> TranslationKind {
        guard text.count <= maxWordLength, !text.contains("\n") else { return .text }
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        // A single spaced token such as "U.S." or "e.g." is still a lookup.
        if !isChinese, tokens.count == 1, !containsNonSpacedScript(text) { return .word }
        if text.unicodeScalars.contains(where: { sentencePunctuation.contains($0) }) { return .text }

        if isChinese {
            let han = text.unicodeScalars.filter(isHan).count
            return han <= maxChineseWordCharacters && !text.contains(" ") ? .word : .text
        }
        if containsNonSpacedScript(text) {
            return chineseLikeTokenCount(text) <= 2 ? .word : .text
        }
        return tokens.count <= maxPhraseTokens ? .word : .text
    }

    // MARK: - Helpers

    private static let sentencePunctuation = CharacterSet(charactersIn: ".!?;:,。！？；：，、…")

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
    }

    private static func containsNonSpacedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            isHan(scalar) || isKana(scalar) || (0x0E00...0x0E7F).contains(scalar.value)
        }
    }

    private static func chineseLikeTokenCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).count
    }
}
