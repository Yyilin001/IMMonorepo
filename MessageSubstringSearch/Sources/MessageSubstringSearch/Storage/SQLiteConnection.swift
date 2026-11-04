import Foundation
import CSQLite

enum SQLValue {
    case text(String), blob(Data), integer(Int64), null
}

/// 连接及语句只允许其所属数据库 actor 使用，不声明 Sendable。
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var control: OperationControl?
    private var cachedStatements: [String: OpaquePointer] = [:]
    private let cacheCapacity: Int
    init(path: String, readOnly: Bool = false, cacheCapacity: Int = 64) throws {
        self.cacheCapacity = cacheCapacity
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let error = failure(code); sqlite3_close(handle); handle = nil; throw error
        }
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 100)
        try registerSearchTokens()
        try execute("PRAGMA foreign_keys=ON")
        if readOnly { try execute("PRAGMA query_only=ON") }
    }
    deinit {
        for statement in cachedStatements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }
    func close() throws {
        guard let handle else { return }
        for statement in cachedStatements.values { sqlite3_finalize(statement) }
        cachedStatements.removeAll()
        try check(sqlite3_close(handle)); self.handle = nil
    }
    func failure(_ code: Int32) -> Error {
        if code & 0xff == SQLITE_INTERRUPT, let control {
            do { try control.check() } catch { return error }
        }
        return SearchIndexError.sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }
    func check(_ code: Int32) throws {
        guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE else { throw failure(code) }
    }
    func execute(_ sql: String) throws {
        guard let handle else { throw SearchIndexError.closed }
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }
    func statement<T>(_ sql: String, values: [SQLValue] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let handle else { throw SearchIndexError.closed }
        // 取出即独占，嵌套调用同一 SQL 不会复用正在执行的语句。
        var statement = cachedStatements.removeValue(forKey: sql)
        if statement == nil {
            let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            if code != SQLITE_OK { sqlite3_finalize(statement); throw failure(code) }
        }
        guard let statement else { throw SearchIndexError.invalidArgument("empty SQL") }
        defer {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            // 不保留文本绑定；缓存大小有界，关闭前全部 finalize。
            if cachedStatements.count < cacheCapacity && cachedStatements[sql] == nil {
                cachedStatements[sql] = statement
            } else { sqlite3_finalize(statement) }
        }
        for (index, value) in values.enumerated() { try bind(value, to: statement, at: Int32(index + 1)) }
        return try body(statement)
    }
    func bind(_ value: SQLValue, to statement: OpaquePointer, at index: Int32) throws {
        switch value {
        case .integer(let number): try check(sqlite3_bind_int64(statement, index, number))
        case .null: try check(sqlite3_bind_null(statement, index))
        case .blob(let data):
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            if data.isEmpty { try check(sqlite3_bind_zeroblob(statement, index, 0)) }
            else { try data.withUnsafeBytes { try check(sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)) } }
        case .text(let text):
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try text.utf8CString.withUnsafeBufferPointer {
                try check(sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient))
            }
        }
    }
    func step(_ statement: OpaquePointer) throws -> Bool { let code = sqlite3_step(statement); try check(code); return code == SQLITE_ROW }
    func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    func int(_ statement: OpaquePointer, _ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func run(_ sql: String, _ values: [SQLValue] = []) throws { try statement(sql, values: values) { _ = try step($0) } }
    func integer(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        try statement(sql, values: values) { try step($0) ? int($0, 0) : 0 }
    }
    func string(_ sql: String, _ values: [SQLValue] = []) throws -> String {
        try statement(sql, values: values) { try step($0) ? text($0, 0) : "" }
    }
    func blob(_ sql: String, _ values: [SQLValue] = []) throws -> Data {
        try statement(sql, values: values) {
            guard try step($0), let bytes = sqlite3_column_blob($0, 0) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes($0, 0)))
        }
    }
    /// external-content 视图按块重建 token；原文只存一份，绝不把派生编码落盘。
    private func registerSearchTokens() throws {
        try check(sqlite3_create_function_v2(handle, "search_tokens", 4, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            Unmanaged.passUnretained(self).toOpaque(), { context, _, args in
                guard let owner = sqlite3_user_data(context) else { return }
                let connection = Unmanaged<SQLiteConnection>.fromOpaque(owner).takeUnretainedValue()
                guard let args, let raw = sqlite3_value_text(args[0]), let modeRaw = sqlite3_value_text(args[3]),
                      let mode = SearchTextMode(rawValue: String(cString: modeRaw)) else {
                    sqlite3_result_error(context, "invalid token source", -1); return
                }
                let total = Int64(sqlite3_value_bytes(args[0]))
                let start = sqlite3_value_int64(args[1]), count = sqlite3_value_int64(args[2])
                guard start >= 0, count >= 0, start <= total, count <= total - start else {
                    sqlite3_result_error(context, "invalid token range", -1); return
                }
                let buffer = UnsafeBufferPointer(start: raw.advanced(by: Int(start)), count: Int(count))
                guard let text = String(bytes: buffer, encoding: .utf8) else {
                    sqlite3_result_error(context, "invalid token UTF-8 boundary", -1); return
                }
                do {
                    let tokenized = try CharacterTokenizer.tokenize(text, mode: mode, byteLimit: Int(count), check: { try connection.control?.check() })
                    let encoded = tokenized.encoded(tokenized.tokens.indices)
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    encoded.utf8CString.withUnsafeBufferPointer {
                        sqlite3_result_text(context, $0.baseAddress, Int32($0.count - 1), transient)
                    }
                } catch {
                    // C 回调内的取消仍映射为 SQLITE_INTERRUPT，不能被消费器当成数据失败持久化。
                    if error is CancellationError || error as? SearchIndexError == .timeout {
                        sqlite3_result_error_code(context, SQLITE_INTERRUPT)
                    } else { sqlite3_result_error(context, "token reconstruction failed", -1) }
                }
            }, nil, nil, nil))
    }
    func meta(_ key: String) throws -> String { try string("SELECT value FROM meta WHERE key=?", [.text(key)]) }
    func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT INTO meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }
    func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
        try execute(readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func controlled<T>(_ control: OperationControl, _ body: () throws -> T) throws -> T {
        // 同一快照和操作可同时用于首屏候选与正文。外层负责恢复 SQLite 的进度回调。
        if self.control === control { try control.check(); return try body() }
        guard let handle else { throw SearchIndexError.closed }
        self.control = control
        let pointer = Unmanaged.passUnretained(control).toOpaque()
        sqlite3_progress_handler(handle, 1000, { raw in
            guard let raw else { return 0 }
            return Unmanaged<OperationControl>.fromOpaque(raw).takeUnretainedValue().interrupted ? 1 : 0
        }, pointer)
        defer { sqlite3_progress_handler(handle, 0, nil, nil); self.control = nil }
        try control.check()
        return try body()
    }
    func capabilities() throws -> SQLiteCapabilities {
        var options: [String] = []
        try statement("PRAGMA compile_options") { while try step($0) { options.append(text($0, 0)) } }
        return SQLiteCapabilities(version: String(cString: sqlite3_libversion()), sourceID: String(cString: sqlite3_sourceid()),
                                  compileOptions: options, fts5: true)
    }
}
