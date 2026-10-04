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

public enum StoreError: Error, Equatable {
    case sqlite(String)
}

/// Local SQLite store for query history and saved words. Data stays on this Mac.
public final class HistoryStore: @unchecked Sendable {
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
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw StoreError.sqlite(message)
        }
        try migrate()
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
        var sql = "SELECT id, payload, created_at FROM history"
        var params: [Value] = []
        if let pattern = Self.likePattern(search) {
            sql += " WHERE source_text LIKE ? ESCAPE '\\' OR translation LIKE ? ESCAPE '\\'"
            params = [.text(pattern), .text(pattern)]
        }
        sql += " ORDER BY created_at DESC, id DESC LIMIT ?"
        params.append(.int(Int64(limit)))
        return try query(sql, params) { row in
            guard let result = try? self.decode(row.text(1)) else { return nil }
            return HistoryItem(id: row.int(0), result: result, createdAt: Date(timeIntervalSince1970: row.real(2)))
        }
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

    public func favorites(search: String? = nil) throws -> [FavoriteItem] {
        var sql = "SELECT id, payload, created_at FROM favorites"
        var params: [Value] = []
        if let pattern = Self.likePattern(search) {
            sql += " WHERE headword LIKE ? ESCAPE '\\' OR translation LIKE ? ESCAPE '\\'"
            params = [.text(pattern), .text(pattern)]
        }
        sql += " ORDER BY created_at DESC, id DESC"
        return try query(sql, params) { row in
            guard let result = try? self.decode(row.text(1)) else { return nil }
            return FavoriteItem(id: row.int(0), result: result, createdAt: Date(timeIntervalSince1970: row.real(2)))
        }
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
        func text(_ index: Int32) -> String {
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
    }

    private func migrate() throws {
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

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            }
        }
        return statement
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
