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
        let plain = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try extractJSONObject(plain) {
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)),
                  let result = makeResult(payload, for: request) else { throw TranslationError.invalidResponse }
            return result
        }
        // Plain prose may contain braces, but an attempted JSON reply must decode.
        guard !plain.isEmpty, !plain.hasPrefix("```json") else { throw TranslationError.invalidResponse }
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

    /// Extracts one balanced object, respecting braces and escapes inside strings.
    static func extractJSONObject(_ content: String) throws -> String? {
        guard let start = jsonStart(in: content[...]) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in content[start...].indices {
            let character = content[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let tail = content[content.index(after: index)...]
                    guard jsonStart(in: tail) == nil else { throw TranslationError.invalidResponse }
                    return String(content[start...index])
                }
            }
        }
        throw TranslationError.invalidResponse
    }

    private static func jsonStart(in content: Substring) -> String.Index? {
        for index in content.indices where content[index] == "{" {
            let rest = content[content.index(after: index)...].drop(while: { $0.isWhitespace })
            if index == content.startIndex || rest.isEmpty || rest.first == "\"" || rest.first == "}" {
                return index
            }
        }
        return nil
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
