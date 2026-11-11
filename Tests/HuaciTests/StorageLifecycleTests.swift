import AppKit
import Foundation
import HuaciCore
import SQLite3
import SwiftUI
import Testing
@testable import Huaci

@Suite(.serialized)
@MainActor
struct StorageLifecycleTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-ui-storage-\(UUID().uuidString).sqlite")

    func result(_ text: String) -> TranslationResult {
        TranslationResult(kind: .text, sourceText: text, sourceLanguage: "en", targetLanguage: "zh-Hans", translation: "译文", word: nil)
    }

    func sql(_ statement: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK)
    }

    @Test func failedHistoryReadPreservesRowsAndSelectionUntilRecovery() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try store.addHistory(result("one"))
        var state = LibraryListState<HistoryItem>()
        state.reload { try store.historySnapshot() }
        let selected = try #require(state.selection)
        try sql("ALTER TABLE history RENAME TO unavailable_history")
        state.reload { try store.historySnapshot() }
        #expect(state.items.count == 1)
        #expect(state.selection == selected)
        #expect(state.error?.contains("读取失败") == true)
        try sql("ALTER TABLE unavailable_history RENAME TO history")
        state.reload { try store.historySnapshot() }
        #expect(state.error == nil)
        #expect(state.selection == selected)
    }

    @Test func firstReadFailureAndMissingStoreAreNotSuccessfulEmptyReads() throws {
        var state = LibraryListState<FavoriteItem>()
        state.reload { try requireStore(nil).favoritesSnapshot() }
        #expect(state.items.isEmpty)
        #expect(state.error != nil)
        let clearedMissingFavorites = state.clear { try requireStore(nil).clearFavorites() }
        #expect(!clearedMissingFavorites)
        #expect(state.error?.contains("清空失败") == true)
        var data = StorageDataState()
        data.reload(store: nil)
        #expect(data.counts == nil)
        #expect(data.error != nil)
        let clearedMissingStore = data.clear(.cache, store: nil)
        #expect(!clearedMissingStore)
    }

    @Test func historyDeleteAndClearFailuresDoNotMoveSelectionOrDiscardRows() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try store.addHistory(result("older"), at: Date(timeIntervalSince1970: 1))
        let id = try store.addHistory(result("newer"), at: Date(timeIntervalSince1970: 2))
        var state = LibraryListState<HistoryItem>()
        state.reload { try store.historySnapshot() }
        #expect(state.selection == id)
        try sql("CREATE TRIGGER reject_history_delete BEFORE DELETE ON history BEGIN SELECT RAISE(ABORT, 'history locked'); END")
        let rejectedDelete = state.delete(id) { try store.deleteHistory(id: id) }
        #expect(!rejectedDelete)
        #expect(state.selection == id)
        #expect(state.items.count == 2)
        #expect(state.error?.contains("history locked") == true)
        let rejectedClear = state.clear { try store.clearHistory() }
        #expect(!rejectedClear)
        #expect(state.selection == id)
        #expect(state.items.count == 2)
        #expect(try store.historyCount() == 2)
        try sql("DROP TRIGGER reject_history_delete")
        let deleted = state.delete(id) { try store.deleteHistory(id: id) }
        #expect(deleted)
        #expect(state.selection == state.items.first?.id)
        #expect(state.selection != id)
        #expect(state.items.count == 1)
        #expect(state.error == nil)
        let cleared = state.clear { try store.clearHistory() }
        #expect(cleared)
        #expect(state.items.isEmpty)
        #expect(state.selection == nil)
    }

    @Test func favoriteDeleteFailureAndCorruptRowWarningsPreserveHealthyData() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try store.addFavorite(result("healthy"))
        try store.addFavorite(result("damaged"))
        try sql("UPDATE favorites SET payload = 'invalid' WHERE headword = 'damaged'; CREATE TRIGGER reject_favorite_delete BEFORE DELETE ON favorites BEGIN SELECT RAISE(ABORT, 'favorites locked'); END")
        var state = LibraryListState<FavoriteItem>()
        state.reload { try store.favoritesSnapshot() }
        let id = try #require(state.selection)
        #expect(state.items.map(\.headword) == ["healthy"])
        #expect(state.warnings.count == 1)
        #expect(state.error == nil)
        let deleted = state.delete(id) { try store.deleteFavorite(id: id) }
        #expect(!deleted)
        #expect(state.selection == id)
        #expect(state.items.count == 1)
        #expect(state.warnings.count == 1)
        #expect(state.error?.contains("favorites locked") == true)
        #expect(try store.favoritesCount() == 2)
    }

    @Test func settingsCountFailureShowsUnknownAndClearFailuresAreReportedForEveryTarget() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let value = result("saved")
        try store.addHistory(value)
        try store.addFavorite(value)
        let request = TranslationRequest(text: "saved", kind: .text, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        try store.cache(value, for: request)
        var state = StorageDataState()
        state.reload(store: store)
        #expect(state.counts?.history == 1)
        #expect(state.counts?.favorites == 1)
        #expect(state.counts?.cache == 1)
        try sql("ALTER TABLE favorites RENAME TO unavailable_favorites")
        state.reload(store: store)
        #expect(state.counts == nil)
        #expect(state.error != nil)
        try sql("ALTER TABLE unavailable_favorites RENAME TO favorites")
        for (target, table): (DataSettings.ClearTarget, String) in [(.history, "history"), (.favorites, "favorites"), (.cache, "translation_cache")] {
            try sql("CREATE TRIGGER reject_delete BEFORE DELETE ON \(table) BEGIN SELECT RAISE(ABORT, 'cannot clear'); END")
            let cleared = state.clear(target, store: store)
            #expect(!cleared)
            #expect(state.error?.contains("cannot clear") == true)
            try sql("DROP TRIGGER reject_delete")
        }
        #expect(try store.historyCount() == 1)
        #expect(try store.favoritesCount() == 1)
        #expect(try store.translationCacheCount() == 1)
        let clearedHistory = state.clear(.history, store: store)
        #expect(clearedHistory)
        state.reload(store: store)
        #expect(state.error == nil)
        #expect(state.counts?.history == 0)
        #expect(state.counts?.favorites == 1)
        #expect(state.counts?.cache == 1)
    }

    @Test func historyScopeAndSearchBoundaryAt501Rows() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        for index in 0...500 {
            try store.addHistory(result("entry \(index)"), at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(HistoryView.resultLimit == 500)
        let visible = try store.historySnapshot(limit: HistoryView.resultLimit)
        #expect(visible.items.count == 500)
        #expect(visible.items.first?.result.sourceText == "entry 500")
        #expect(visible.items.last?.result.sourceText == "entry 1")
        #expect(try store.historyCount() == 501)
        // Search runs over the entire database, including the oldest hidden entry.
        let search = try store.historySnapshot(search: "entry 0", limit: HistoryView.resultLimit)
        #expect(search.items.map(\.result.sourceText) == ["entry 0"])
    }

    @Test func nativeStorageWarningsAndQueryErrorsRenderWithIsolatedData() async throws {
        _ = NSApplication.shared
        let suite = "app.huaci.storage-render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, keychain: Keychain(service: suite), storeURL: url)
        let store = try #require(model.store)
        #expect(store.url == url)
        #expect(model.accounts.isEmpty)
        try store.addHistory(result("healthy"))
        try store.addHistory(result("damaged"))
        try store.addFavorite(result("healthy"))
        try store.addFavorite(result("damaged"))
        try sql("UPDATE history SET payload = 'invalid' WHERE source_text = 'damaged'; UPDATE favorites SET payload = 'invalid' WHERE headword = 'damaged';")
        try await renderStorage(HistoryView().environmentObject(model), size: CGSize(width: 1040, height: 700), name: "storage-history-warning")
        try await renderStorage(VocabularyView().environmentObject(model), size: CGSize(width: 1040, height: 700), name: "storage-vocabulary-warning")
        #expect(try store.historySnapshot().items.count == 1)
        #expect(try store.favoritesSnapshot().items.count == 1)
        #expect(try store.historyCount() == 2)
        #expect(try store.favoritesCount() == 2)
        try sql("ALTER TABLE history RENAME TO unavailable_history")
        try await renderStorage(HistoryView().environmentObject(model), size: CGSize(width: 1040, height: 700), name: "storage-history-query-error")
        try await renderStorage(DataSettings().environmentObject(model), size: CGSize(width: 680, height: 560), name: "storage-settings-count-error")
        try sql("ALTER TABLE unavailable_history RENAME TO history")
        #expect(try store.historyCount() == 2)
    }

    private func renderStorage<Content: View>(_ content: Content, size: CGSize, name: String) async throws {
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).tint(Theme.accent))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        defer { window.close() }
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(host.bounds.size == size)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let path = ProcessInfo.processInfo.environment["HUACI_UI_TEST_ARTIFACTS"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }

}
