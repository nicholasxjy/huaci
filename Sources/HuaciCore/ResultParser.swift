import Foundation

/// Turns model output into a `TranslationResult`. Lenient by design: models may
/// wrap JSON in fences, omit fields or ignore the format entirely.
public enum ResultParser {
    /// Shape shared by model replies and the built-in service's `result` field.
    public struct Payload: Codable, Equatable, Sendable {
        public var kind: String?
        public var headword: String?
        public var phonetic: String?
        public var translation: String?
        public var senses: [Sense]?
        public var examples: [Example]?

        public struct Sense: Codable, Equatable, Sendable {
            public var pos: String?
            public var meanings: [String]?
        }

        public struct Example: Codable, Equatable, Sendable {
            public var source: String?
            public var translation: String?
        }
    }

    public static func parse(_ content: String, for request: TranslationRequest) throws -> TranslationResult {
        if let json = extractJSONObject(content),
           let data = json.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           let result = makeResult(payload, for: request) {
            return result
        }
        // Model ignored the JSON format: show its plain reply as the translation.
        let plain = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, extractJSONObject(plain) == nil else { throw TranslationError.invalidResponse }
        return TranslationResult(
            kind: .text,
            sourceText: request.text,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage.code,
            translation: plain,
            word: nil
        )
    }

    public static func makeResult(_ payload: Payload, for request: TranslationRequest) -> TranslationResult? {
        let senses = (payload.senses ?? []).compactMap { sense -> WordSense? in
            let meanings = (sense.meanings ?? []).map(clean).filter { !$0.isEmpty }
            return meanings.isEmpty ? nil : WordSense(pos: nonEmpty(sense.pos), meanings: meanings)
        }
        let examples = (payload.examples ?? []).compactMap { example -> WordExample? in
            guard let source = nonEmpty(example.source) else { return nil }
            return WordExample(source: source, translation: nonEmpty(example.translation))
        }

        let isWord = payload.kind == "word" || (payload.kind == nil && !senses.isEmpty)
        let translation = nonEmpty(payload.translation)
            ?? senses.first.map { $0.meanings.prefix(2).joined(separator: "；") }

        guard let translation else { return nil }
        guard isWord else {
            return TranslationResult(
                kind: .text,
                sourceText: request.text,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage.code,
                translation: translation,
                word: nil
            )
        }
        let entry = WordEntry(
            headword: nonEmpty(payload.headword) ?? request.text,
            phonetic: nonEmpty(payload.phonetic),
            senses: senses,
            examples: examples
        )
        return TranslationResult(
            kind: .word,
            sourceText: request.text,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage.code,
            translation: translation,
            word: entry
        )
    }

    /// Returns the outermost `{...}` block, dropping markdown fences or prose.
    static func extractJSONObject(_ content: String) -> String? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(content[start...end])
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = clean(value)
        return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
    }
}
