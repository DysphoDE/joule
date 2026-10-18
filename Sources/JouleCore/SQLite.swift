import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public var description: String
}

/// Minimal SQLite wrapper. Not thread-safe by itself; `Store` serialises access.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            throw SQLiteError(description: "Datenbank lässt sich nicht öffnen: \(path)")
        }
        sqlite3_busy_timeout(handle, 3000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unbekannt"
            sqlite3_free(error)
            throw SQLiteError(description: message)
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
        }
        statements[sql] = statement
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ values: [Any?]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, index)
            case let v as Double: sqlite3_bind_double(statement, index, v)
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as Bool: sqlite3_bind_int64(statement, index, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case let v as Date: sqlite3_bind_double(statement, index, v.timeIntervalSince1970)
            default: sqlite3_bind_text(statement, index, "\(value!)", -1, SQLITE_TRANSIENT)
            }
        }
    }

    func run(_ sql: String, _ values: Any?...) throws {
        let statement = try prepare(sql)
        bind(statement, values)
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func query(_ sql: String, _ values: Any?..., row: (Row) -> Void) throws {
        let statement = try prepare(sql)
        bind(statement, values)
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(description: String(cString: sqlite3_errmsg(handle))) }
            row(Row(statement: statement))
        }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    struct Row {
        let statement: OpaquePointer
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
        func string(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        func optionalString(_ i: Int32) -> String? { sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : string(i) }
        func optionalDouble(_ i: Int32) -> Double? { sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : double(i) }
        func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: double(i)) }
    }
}
