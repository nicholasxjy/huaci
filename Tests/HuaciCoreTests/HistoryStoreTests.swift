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

    @Test func countsHistoryAndFavorites() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        #expect(try store.historyCount() == 0)
        #expect(try store.favoritesCount() == 0)

        try store.addHistory(word("a", "一"))
        try store.addHistory(text("Hi.", "嗨。"))
        try store.addFavorite(word("a", "一"))

        #expect(try store.historyCount() == 2)
        #expect(try store.favoritesCount() == 1)
    }

    @Test func favoritesCanBeSortedAlphabetically() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try store.addFavorite(word("banana", "香蕉"), at: Date(timeIntervalSince1970: 1))
        try store.addFavorite(word("Apple", "苹果"), at: Date(timeIntervalSince1970: 2))
        try store.addFavorite(word("cherry", "樱桃"), at: Date(timeIntervalSince1970: 3))

        #expect(try store.favorites().map(\.headword) == ["cherry", "Apple", "banana"])
        #expect(try store.favorites(order: .alphabetical).map(\.headword) == ["Apple", "banana", "cherry"])
        #expect(try store.favorites(search: "an", order: .alphabetical).map(\.headword) == ["banana"])
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

    @Test func embeddedNULCacheKeysRemainDistinct() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let embedded = request("ab\u{0000}cd")
        let prefix = request("ab")
        try store.cache(result(for: embedded, "embedded"), for: embedded)
        #expect(try store.cachedResult(for: prefix) == nil)
        try store.cache(result(for: prefix, "prefix"), for: prefix)
        #expect(try store.translationCacheCount() == 2)
        #expect(try store.cachedResult(for: embedded)?.translation == "embedded")
        #expect(try store.cachedResult(for: prefix)?.translation == "prefix")
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

    @Test func countsAndClearsCachedTranslations() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        #expect(try store.translationCacheCount() == 0)

        let bank = request("bank"), apple = request("apple"), sentence = request("Good morning.", kind: .text)
        try store.cache(result(for: bank, "银行"), for: bank)
        try store.cache(result(for: apple, "苹果"), for: apple)
        try store.cache(result(for: sentence, "早上好。"), for: sentence)
        // Re-caching replaces the entry instead of adding a second one.
        try store.cache(result(for: bank, "河岸"), for: bank)

        #expect(try store.translationCacheCount() == 3)
        #expect(try store.cachedResult(for: bank)?.translation == "河岸")

        try store.clearTranslationCache()
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

struct StorageBoundaryTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-boundary-\(UUID().uuidString).sqlite")

    func sql(_ statement: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK)
    }

    func result(_ text: String = "healthy") -> TranslationResult {
        TranslationResult(kind: .text, sourceText: text, sourceLanguage: "en", targetLanguage: "zh-Hans", translation: "健康", word: nil)
    }

    @Test func malformedRowsWarnWithoutLosingHealthyRowsOrChangingCounts() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try store.addHistory(result())
        let damagedID = try store.addHistory(result("damaged"))
        try store.addFavorite(result())
        try store.addFavorite(result("damaged"))
        // A NUL after valid JSON must not make the trailing damage invisible.
        try sql("UPDATE history SET payload = payload || char(0) || 'garbage' WHERE id = \(damagedID); UPDATE favorites SET payload = 'not JSON' WHERE headword = 'damaged';")
        let history = try store.historySnapshot()
        let favorites = try store.favoritesSnapshot()
        #expect(history.items.map(\.result.sourceText) == ["healthy"])
        #expect(favorites.items.map(\.result.sourceText) == ["healthy"])
        #expect(history.warnings.count == 1)
        #expect(history.warnings[0].contains("history #\(damagedID)"))
        #expect(favorites.warnings.count == 1)
        #expect(throws: StoreError.self) { try store.history() }
        #expect(throws: StoreError.self) { try store.favorites() }
        #expect(try store.historyCount() == 2)
        #expect(try store.favoritesCount() == 2)
        // Reads neither delete nor repair malformed records.
        #expect(try store.historySnapshot().warnings.count == 1)
        #expect(try store.favoritesSnapshot().warnings.count == 1)
    }

    @Test func invalidUTF8PayloadWarnsRatherThanChangingTheDecodedText() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try store.addHistory(result())
        try sql("UPDATE history SET payload = replace(payload, 'healthy', CAST(X'FF' AS TEXT))")
        let snapshot = try store.historySnapshot()
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.warnings.count == 1)
        #expect(snapshot.warnings[0].contains("Invalid UTF-8"))
        #expect(try store.historyCount() == 1)
    }

    @Test func malformedCacheIsAnErrorRatherThanAMiss() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let request = TranslationRequest(text: "healthy", kind: .text, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        try store.cache(result(), for: request)
        try sql("UPDATE translation_cache SET payload = 'invalid'")
        #expect(throws: DecodingError.self) { try store.cachedResult(for: request) }
        #expect(try store.translationCacheCount() == 1)
    }

    @Test func bindFailuresFinalizeStatementsAndKeepConnectionUsable() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let probe = try store.prepare("SELECT 1", [])
        let db = try #require(sqlite3_db_handle(probe))
        sqlite3_finalize(probe)
        for value: HistoryStore.Value in [.text("text"), .int(2), .real(3)] {
            #expect(throws: StoreError.self) {
                let unexpected = try store.prepare("SELECT ?", [.int(1), value])
                sqlite3_finalize(unexpected)
            }
            #expect(sqlite3_next_stmt(db, nil) == nil)
        }
        let oldLimit = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1024)
        #expect(throws: StoreError.self) {
            let unexpected = try store.prepare("SELECT ?", [.text(String(repeating: "界", count: 1024))])
            sqlite3_finalize(unexpected)
        }
        #expect(sqlite3_next_stmt(db, nil) == nil)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, oldLimit)
        try store.addHistory(result())
        #expect(try store.historyCount() == 1)
    }

    @Test func currentSchemaDoesNotRequireAWriterLockToOpen() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try HistoryStore(url: url)
            try store.addHistory(result())
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let reopened = try HistoryStore(url: url)
        #expect(try reopened.historyCount() == 1)
    }

    @Test func failedMigrationRollsBackSchemaAndVersion() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        // This table blocks creation of the history index after history is created.
        try sql("CREATE TABLE history_created_at (sentinel TEXT); INSERT INTO history_created_at VALUES ('keep');")
        #expect(throws: StoreError.self) { try HistoryStore(url: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 0)
        sqlite3_finalize(statement)
        #expect(sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE name = 'history'", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
        // Recover the conflicting schema and retry, retaining the original table/data.
        try sql("ALTER TABLE history_created_at RENAME TO preserved;")
        let reopened = try HistoryStore(url: url)
        try reopened.addHistory(result())
        #expect(try reopened.historyCount() == 1)
        #expect(sqlite3_prepare_v2(db, "SELECT sentinel FROM preserved", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "keep")
        sqlite3_finalize(statement)
    }

    @Test func favoriteIdentityPreservesUTF8NULAndOriginalSaveDate() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let original = result("界\u{0000}🙂")
        try store.addFavorite(original, at: Date(timeIntervalSince1970: 1))
        try store.addFavorite(result("界"), at: Date(timeIntervalSince1970: 2))
        try store.addFavorite(original, at: Date(timeIntervalSince1970: 3))
        #expect(try store.favoritesCount() == 2)
        #expect(try store.favorites().first(where: { $0.result == original })?.createdAt == Date(timeIntervalSince1970: 1))
        try store.removeFavorite(headword: "界", targetLanguage: "zh-Hans")
        #expect(try store.isFavorite(headword: original.sourceText, targetLanguage: "zh-Hans"))
        #expect(try !store.isFavorite(headword: "界", targetLanguage: "zh-Hans"))
    }
}
