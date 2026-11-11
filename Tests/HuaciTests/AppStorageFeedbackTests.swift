import Foundation
import HuaciCore
import SQLite3
import Testing
@testable import Huaci

@Suite(.serialized)
@MainActor
struct AppStorageFeedbackTests {
    @MainActor
    private final class Fixture {
        let suite = "app.huaci.storage-feedback.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-feedback-\(UUID().uuidString)")
        let defaults: UserDefaults
        let model: AppModel

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = AppModel(settings: AppSettings(defaults: defaults), keychain: Keychain(service: suite),
                             storeURL: directory.appendingPathComponent("test.sqlite"))
        }

        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        func sql(_ statement: String) throws {
            let url = try #require(model.store?.url)
            var db: OpaquePointer?
            #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK)
        }
    }

    @Test func favoriteWriteFailureDoesNotClaimAnUpdatedState() throws {
        let fixture = try Fixture()
        let result = TranslationResult(kind: .word, sourceText: "hello", sourceLanguage: "en", targetLanguage: "zh-Hans",
                                       translation: "你好", word: WordEntry(headword: "hello", phonetic: nil, senses: [], examples: []))
        try fixture.sql("CREATE TRIGGER fail_favorite BEFORE INSERT ON favorites BEGIN SELECT RAISE(ABORT, 'favorite locked'); END")

        #expect((fixture.model.toggleFavorite(result) as Bool?) == nil)
        #expect(fixture.model.storeError?.contains("favorite locked") == true)
        #expect(try fixture.model.store?.favoritesCount() == 0)

        try fixture.sql("DROP TRIGGER fail_favorite")
        #expect(fixture.model.toggleFavorite(result) == true)
        #expect(fixture.model.storeError == nil)
        #expect(try fixture.model.store?.favoritesCount() == 1)
    }

    @Test func historyWriteFailureKeepsTranslationAndReportsUnsavedHistory() async throws {
        let fixture = try Fixture()
        let result = TranslationResult(kind: .text, sourceText: "A complete translation.", sourceLanguage: "en",
                                       targetLanguage: "zh-Hans", translation: "完整的翻译。", word: nil)
        let request = TranslationRequest(text: result.sourceText, kind: .text, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        try fixture.model.store?.cache(result, for: request)
        try fixture.sql("CREATE TRIGGER fail_history BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT, 'history locked'); END")
        fixture.model.inputTranslation.text = result.sourceText

        fixture.model.translateInput()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(fixture.model.inputTranslation.result == result)
        #expect(fixture.model.storeError?.contains("history locked") == true)
        #expect(try fixture.model.store?.historyCount() == 0)
    }
}
