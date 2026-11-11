import Foundation
import SQLite3

public struct HistoryItem: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let result: TranslationResult
    public let createdAt: Date
}

public struct FavoriteItem: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let result: TranslationResult
    public let createdAt: Date

    public var headword: String { result.word?.headword ?? result.sourceText }
}

public enum FavoriteOrder: String, CaseIterable, Sendable {
    /// Most recently saved first.
    case recent
    case alphabetical
}

public enum StoreError: Error, Equatable, LocalizedError {
    case sqlite(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message), .decoding(let message): return message
        }
    }
}

/// Healthy rows remain available; warnings identify unreadable rows left untouched on disk.
public struct StoreReadResult<Item> {
    public let items: [Item]
    public let warnings: [String]

    public init(items: [Item], warnings: [String] = []) {
        self.items = items
        self.warnings = warnings
    }

    fileprivate func validated() throws -> [Item] {
        guard warnings.isEmpty else { throw StoreError.decoding(warnings.joined(separator: "\n")) }
        return items
    }
}

/// Local SQLite store for query history, saved words and cached translations.
/// Data stays on this Mac.
public final class HistoryStore: @unchecked Sendable {
    /// The database file; history, favorites and the translation cache share it.
    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Huaci", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("huaci.sqlite")
    }

    public init(url: URL) throws {
        self.url = url
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw StoreError.sqlite(message)
        }
        do {
            try migrate()
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: History

    @discardableResult
    public func addHistory(_ result: TranslationResult, at date: Date = Date()) throws -> Int64 {
        try write(
            "INSERT INTO history (source_text, translation, kind, payload, created_at) VALUES (?, ?, ?, ?, ?)",
            [.text(result.sourceText), .text(result.translation), .text(result.kind.rawValue),
             .text(try encode(result)), .real(date.timeIntervalSince1970)]
        )
    }

    public func history(search: String? = nil, limit: Int = 500) throws -> [HistoryItem] {
        try historySnapshot(search: search, limit: limit).validated()
    }

    public func historySnapshot(search: String? = nil, limit: Int = 500) throws -> StoreReadResult<HistoryItem> {
        var sql = "SELECT id, payload, created_at FROM history"
        var params: [Value] = []
        if let pattern = Self.likePattern(search) {
            sql += " WHERE source_text LIKE ? ESCAPE '\\' OR translation LIKE ? ESCAPE '\\'"
            params = [.text(pattern), .text(pattern)]
        }
        sql += " ORDER BY created_at DESC, id DESC LIMIT ?"
        params.append(.int(Int64(limit)))
        return try readRecords(sql, params, table: "history") { row, result in
            HistoryItem(id: row.int(0), result: result, createdAt: Date(timeIntervalSince1970: row.real(2)))
        }
    }

    public func historyCount() throws -> Int {
        Int(try query("SELECT COUNT(*) FROM history", []) { $0.int(0) }.first ?? 0)
    }

    public func deleteHistory(id: Int64) throws {
        try write("DELETE FROM history WHERE id = ?", [.int(id)])
    }

    public func clearHistory() throws {
        try write("DELETE FROM history", [])
    }

    // MARK: Favorites

    /// Saves a word; saving the same headword and target language again updates it.
    public func addFavorite(_ result: TranslationResult, at date: Date = Date()) throws {
        let headword = result.word?.headword ?? result.sourceText
        try write(
            """
            INSERT INTO favorites (headword, target_language, translation, payload, created_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(headword, target_language) DO UPDATE SET translation = excluded.translation, payload = excluded.payload
            """,
            [.text(headword), .text(result.targetLanguage), .text(result.translation), .text(try encode(result)),
             .real(date.timeIntervalSince1970)]
        )
    }

    public func removeFavorite(headword: String, targetLanguage: String) throws {
        try write("DELETE FROM favorites WHERE headword = ? AND target_language = ?", [.text(headword), .text(targetLanguage)])
    }

    public func deleteFavorite(id: Int64) throws {
        try write("DELETE FROM favorites WHERE id = ?", [.int(id)])
    }

    public func clearFavorites() throws {
        try write("DELETE FROM favorites", [])
    }

    public func isFavorite(headword: String, targetLanguage: String) throws -> Bool {
        try !query("SELECT 1 FROM favorites WHERE headword = ? AND target_language = ?", [.text(headword), .text(targetLanguage)]) { _ in true }.isEmpty
    }

    public func favoritesCount() throws -> Int {
        Int(try query("SELECT COUNT(*) FROM favorites", []) { $0.int(0) }.first ?? 0)
    }

    public func favorites(search: String? = nil, order: FavoriteOrder = .recent) throws -> [FavoriteItem] {
        try favoritesSnapshot(search: search, order: order).validated()
    }

    public func favoritesSnapshot(search: String? = nil, order: FavoriteOrder = .recent) throws -> StoreReadResult<FavoriteItem> {
        var sql = "SELECT id, payload, created_at FROM favorites"
        var params: [Value] = []
        if let pattern = Self.likePattern(search) {
            sql += " WHERE headword LIKE ? ESCAPE '\\' OR translation LIKE ? ESCAPE '\\'"
            params = [.text(pattern), .text(pattern)]
        }
        switch order {
        case .recent: sql += " ORDER BY created_at DESC, id DESC"
        case .alphabetical: sql += " ORDER BY headword COLLATE NOCASE, id"
        }
        return try readRecords(sql, params, table: "favorites") { row, result in
            FavoriteItem(id: row.int(0), result: result, createdAt: Date(timeIntervalSince1970: row.real(2)))
        }
    }

    // MARK: Translation cache

    /// Translations keyed by the exact request text, kind and target language,
    /// so a repeated lookup does not call the model again.
    /// Unreadable entries throw; optional-cache callers can fetch a fresh result and replace them.
    public func cachedResult(for request: TranslationRequest) throws -> TranslationResult? {
        try query(
            "SELECT payload FROM translation_cache WHERE source_text = ? AND kind = ? AND target_language = ?",
            [.text(request.text), .text(request.kind.rawValue), .text(request.targetLanguage.code)]
        ) { row in try self.decode(row.text(0)) }.first
    }

    public func cache(_ result: TranslationResult, for request: TranslationRequest, at date: Date = Date()) throws {
        try write(
            """
            INSERT INTO translation_cache (source_text, kind, target_language, payload, created_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source_text, kind, target_language) DO UPDATE SET payload = excluded.payload, created_at = excluded.created_at
            """,
            [.text(request.text), .text(request.kind.rawValue), .text(request.targetLanguage.code), .text(try encode(result)),
             .real(date.timeIntervalSince1970)]
        )
    }

    public func translationCacheCount() throws -> Int {
        Int(try query("SELECT COUNT(*) FROM translation_cache", []) { $0.int(0) }.first ?? 0)
    }

    public func clearTranslationCache() throws {
        try write("DELETE FROM translation_cache", [])
    }

    // MARK: - SQLite plumbing

    enum Value {
        case text(String)
        case int(Int64)
        case real(Double)
    }

    struct Row {
        let statement: OpaquePointer
        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func real(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func text(_ index: Int32) throws -> String {
            guard let bytes = sqlite3_column_text(statement, index) else {
                throw StoreError.decoding("Missing text in column \(index)")
            }
            let buffer = UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index)))
            guard let value = String(bytes: buffer, encoding: .utf8) else {
                throw StoreError.decoding("Invalid UTF-8 in column \(index)")
            }
            return value
        }
    }

    private func migrate() throws {
        let version = try query("PRAGMA user_version", []) { $0.int(0) }.first ?? 0
        guard version < 2 else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try migrateSchema()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func migrateSchema() throws {
        let version = try query("PRAGMA user_version", []) { $0.int(0) }.first ?? 0
        if version < 1 {
            try exec("""
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_text TEXT NOT NULL,
                translation TEXT NOT NULL,
                kind TEXT NOT NULL,
                payload TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS history_created_at ON history(created_at);
            CREATE TABLE IF NOT EXISTS favorites (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                headword TEXT NOT NULL,
                target_language TEXT NOT NULL,
                translation TEXT NOT NULL,
                payload TEXT NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE(headword, target_language)
            );
            PRAGMA user_version = 1;
            """)
        }
        if version < 2 {
            try exec("""
            CREATE TABLE IF NOT EXISTS translation_cache (
                source_text TEXT NOT NULL,
                kind TEXT NOT NULL,
                target_language TEXT NOT NULL,
                payload TEXT NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY (source_text, kind, target_language)
            );
            PRAGMA user_version = 2;
            """)
        }
    }

    private func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    @discardableResult
    private func write(_ sql: String, _ params: [Value]) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        return sqlite3_last_insert_rowid(db)
    }

    private func query<T>(_ sql: String, _ params: [Value], map: (Row) throws -> T?) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw lastError() }
            if let value = try map(Row(statement: statement)) { rows.append(value) }
        }
        return rows
    }

    func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let error = lastError()
            sqlite3_finalize(statement)
            throw error
        }
        var prepared = false
        defer { if !prepared { sqlite3_finalize(statement) } }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch param {
            case .text(let value):
                let bytes = value.utf8CString
                guard let length = Int32(exactly: bytes.count - 1) else {
                    throw StoreError.sqlite("Text exceeds SQLite's supported byte length")
                }
                status = bytes.withUnsafeBufferPointer {
                    sqlite3_bind_text(statement, index, $0.baseAddress, length, transient)
                }
            case .int(let value): status = sqlite3_bind_int64(statement, index, value)
            case .real(let value): status = sqlite3_bind_double(statement, index, value)
            }
            guard status == SQLITE_OK else { throw lastError() }
        }
        prepared = true
        return statement
    }

    private func readRecords<Item>(_ sql: String, _ params: [Value], table: String,
                                   make: (Row, TranslationResult) -> Item) throws -> StoreReadResult<Item> {
        var warnings: [String] = []
        let items: [Item] = try query(sql, params) { row in
            let result: TranslationResult
            do {
                result = try self.decode(row.text(1))
            } catch {
                warnings.append("\(table) #\(row.int(0)): \(error.localizedDescription)")
                return nil
            }
            return make(row, result)
        }
        return StoreReadResult(items: items, warnings: warnings)
    }

    private func lastError() -> StoreError {
        StoreError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }

    private func encode(_ result: TranslationResult) throws -> String {
        String(decoding: try encoder.encode(result), as: UTF8.self)
    }

    private func decode(_ payload: String) throws -> TranslationResult {
        try decoder.decode(TranslationResult.self, from: Data(payload.utf8))
    }

    private static func likePattern(_ search: String?) -> String? {
        guard let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty else { return nil }
        let escaped = search
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}

extension HistoryStore: TranslationCache {}
