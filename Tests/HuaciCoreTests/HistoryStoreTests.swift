import Foundation
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
