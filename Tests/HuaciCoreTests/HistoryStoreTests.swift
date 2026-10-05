import Foundation
import SQLite3
import Testing
@testable import HuaciCore

struct HistoryStoreTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-\(UUID().uuidString).sqlite")

    func word(_ headword: String, _ translation: String, target: String = "zh-Hans") -> TranslationResult {
        TranslationResult(kind: .word, sourceText: headword, sourceLanguage: "en", targetLanguage: target, translation: translation,
                          word: WordEntry(headword: headword, phonetic: "/x/", senses: [WordSense(pos: "n.", meanings: [translation])], examples: []))
    }

    func text(_ source: String, _ translation: String) -> TranslationResult {
        TranslationResult(kind: .text, sourceText: source, sourceLanguage: "en", targetLanguage: "zh-Hans", translation: translation, word: nil)
    }

    @Test func historyPersistsAcrossReopen() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try HistoryStore(url: url)
            try store.addHistory(word("apple", "苹果"), at: Date(timeIntervalSince1970: 1))
            try store.addHistory(text("Good morning.", "早上好。"), at: Date(timeIntervalSince1970: 2))
        }
        let reopened = try HistoryStore(url: url)
        let items = try reopened.history()
        #expect(items.map(\.result.sourceText) == ["Good morning.", "apple"])
        #expect(items.last?.result == word("apple", "苹果"))
    }

    @Test func historySearchMatchesSourceAndTranslation() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try store.addHistory(word("apple", "苹果"))
        try store.addHistory(text("100% sure", "百分之百确定"))
        try store.addHistory(text("snake_case", "蛇形命名"))

        #expect(try store.history(search: "苹").map(\.result.sourceText) == ["apple"])
        #expect(try store.history(search: "APP").map(\.result.sourceText) == ["apple"])
        #expect(try store.history(search: "%").map(\.result.sourceText) == ["100% sure"])
        #expect(try store.history(search: "_").map(\.result.sourceText) == ["snake_case"])
        #expect(try store.history(search: "  ").count == 3)
    }

    @Test func historyDeleteAndClear() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let first = try store.addHistory(word("a", "一"))
        try store.addHistory(word("b", "二"))

        try store.deleteHistory(id: first)
        #expect(try store.history().map(\.result.sourceText) == ["b"])

        try store.clearHistory()
        #expect(try store.history().isEmpty)
    }

    @Test func favoritesUpsertSearchAndDelete() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try store.addFavorite(word("bank", "银行"), at: Date(timeIntervalSince1970: 1))
        try store.addFavorite(word("bank", "河岸"), at: Date(timeIntervalSince1970: 2))
        try store.addFavorite(word("bank", "Bank", target: "de"), at: Date(timeIntervalSince1970: 3))

        let all = try store.favorites()
        #expect(all.count == 2)
        #expect(try store.favorites(search: "河岸").first?.result.translation == "河岸")
        #expect(try store.isFavorite(headword: "bank", targetLanguage: "zh-Hans"))

        try store.removeFavorite(headword: "bank", targetLanguage: "zh-Hans")
        #expect(try !store.isFavorite(headword: "bank", targetLanguage: "zh-Hans"))
        #expect(try store.isFavorite(headword: "bank", targetLanguage: "de"))

        let remaining = try #require(try store.favorites().first)
        try store.deleteFavorite(id: remaining.id)
        #expect(try store.favorites().isEmpty)

        try store.addFavorite(word("x", "叉"))
        try store.clearFavorites()
        #expect(try store.favorites().isEmpty)
    }
}

struct TranslationCacheStoreTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-\(UUID().uuidString).sqlite")

    func request(_ text: String, kind: TranslationKind = .word, target: String = "zh-Hans") -> TranslationRequest {
        TranslationRequest(text: text, kind: kind, sourceLanguage: "en", targetLanguage: .named(target))
    }

    func result(for request: TranslationRequest, _ translation: String) -> TranslationResult {
        TranslationResult(kind: request.kind, sourceText: request.text, sourceLanguage: "en", targetLanguage: request.targetLanguage.code,
                          translation: translation, word: nil)
    }

    @Test func cachedResultMatchesTextKindAndTarget() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let bank = request("bank")
        try store.cache(result(for: bank, "银行"), for: bank)

        #expect(try store.cachedResult(for: request("bank")) == result(for: bank, "银行"))
        #expect(try store.cachedResult(for: request("Bank")) == nil)
        #expect(try store.cachedResult(for: request("bank", target: "ja")) == nil)
        #expect(try store.cachedResult(for: request("bank", kind: .text)) == nil)
    }

    @Test func cachingAgainReplacesAndPersists() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let bank = request("bank")
        do {
            let store = try HistoryStore(url: url)
            try store.cache(result(for: bank, "银行"), for: bank)
            try store.cache(result(for: bank, "河岸"), for: bank)
        }
        let reopened = try HistoryStore(url: url)
        #expect(try reopened.cachedResult(for: bank)?.translation == "河岸")
    }

    @Test func clearingCacheKeepsHistory() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let bank = request("bank")
        try store.cache(result(for: bank, "银行"), for: bank)
        try store.addHistory(result(for: bank, "银行"))

        try store.clearTranslationCache()
        #expect(try store.cachedResult(for: bank) == nil)
        #expect(try store.history().count == 1)

        try store.cache(result(for: bank, "银行"), for: bank)
        try store.clearHistory()
        #expect(try store.cachedResult(for: bank) != nil)
    }

    @Test func listsCachedTranslationsNewestFirst() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        #expect(try store.cachedTranslations().isEmpty)
        #expect(try store.translationCacheCount() == 0)

        let bank = request("bank"), apple = request("apple"), sentence = request("Good morning.", kind: .text)
        try store.cache(result(for: bank, "银行"), for: bank, at: Date(timeIntervalSince1970: 1))
        try store.cache(result(for: apple, "苹果"), for: apple, at: Date(timeIntervalSince1970: 2))
        try store.cache(result(for: sentence, "早上好。"), for: sentence, at: Date(timeIntervalSince1970: 3))
        // Re-caching moves an entry to the top instead of adding a second one.
        try store.cache(result(for: bank, "河岸"), for: bank, at: Date(timeIntervalSince1970: 4))

        let items = try store.cachedTranslations()
        #expect(items.map(\.result.translation) == ["河岸", "早上好。", "苹果"])
        #expect(items.first?.createdAt == Date(timeIntervalSince1970: 4))
        #expect(Set(items.map(\.id)).count == 3)
        #expect(try store.cachedTranslations(limit: 2).count == 2)
        #expect(try store.translationCacheCount() == 3)

        try store.clearTranslationCache()
        #expect(try store.cachedTranslations().isEmpty)
        #expect(try store.translationCacheCount() == 0)
    }

    @Test func upgradesVersionOneDatabaseKeepingHistory() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try HistoryStore(url: url)
            try store.addHistory(result(for: request("apple"), "苹果"))
        }
        // Roll the file back to the v1 schema, as shipped before the cache existed.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "DROP TABLE translation_cache; PRAGMA user_version = 1;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try HistoryStore(url: url)
        #expect(try store.history().map(\.result.sourceText) == ["apple"])
        let bank = request("bank")
        try store.cache(result(for: bank, "银行"), for: bank)
        #expect(try store.cachedResult(for: bank)?.translation == "银行")
    }
}
