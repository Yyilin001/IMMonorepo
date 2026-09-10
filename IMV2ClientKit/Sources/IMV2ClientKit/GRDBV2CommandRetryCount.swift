import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    /// 把重试时间转换为可写入 SQLite 的 Unix 秒。
    ///
    /// - Parameter date: 待转换的重试时间。
    /// - Returns: 以秒为单位的 Unix 时间戳。
    /// - Throws: 时间无法表示（非有限值）时抛出 `commandConflict`。
    static func commandRetryTimestamp(_ date: Date) throws -> Double {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { throw V2ClientCommandError.commandConflict }
        return seconds
    }

    /// 从数据库行读取重试时间。
    ///
    /// 同时接受 REAL 与 INTEGER 存储形态，避免读取端依赖写入端的存储类别。
    ///
    /// - Parameter row: 含 `next_attempt_at` 列的数据库行。
    /// - Returns: 解码出的重试时间。
    /// - Throws: 存储类别不符或数值非有限时抛出 `commandConflict`。
    static func commandRetryDate(_ row: Row) throws -> Date {
        let value: DatabaseValue = row["next_attempt_at"]
        let seconds: Double
        switch value.storage {
        case .double(let stored): seconds = stored
        case .int64(let stored): seconds = Double(stored)
        default: throw V2ClientCommandError.commandConflict
        }
        guard seconds.isFinite else { throw V2ClientCommandError.commandConflict }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 从数据库行读取已重试次数。
    ///
    /// - Parameter row: 含 `attempt_count` 列的数据库行。
    /// - Returns: 非负的重试次数。
    /// - Throws: 数值非法或超出 `Int` 范围时抛出 `commandConflict`。
    static func commandAttemptCount(_ row: Row) throws -> Int {
        let value: DatabaseValue = row["attempt_count"]
        return try commandNonnegativeInteger(value)
    }

    /// 解码一个非负整数数据库值。
    ///
    /// - Parameter value: 待解码的数据库值。
    /// - Returns: 解码出的非负整数。
    /// - Throws: 不是位于 `Int` 范围内的非负整数时抛出 `commandConflict`。
    static func commandNonnegativeInteger(_ value: DatabaseValue) throws -> Int {
        guard case .int64(let stored) = value.storage, stored >= 0,
              let count = Int(exactly: stored)
        else { throw V2ClientCommandError.commandConflict }
        return count
    }

    // Table and key column are fixed by the typed command-store methods.
    // Read and write share their transaction; SQLite must never promote an
    // overflowing integer counter to REAL.
    /// 递增指定命令的重试次数并写入下一次尝试时间。
    ///
    /// 表名与键列由类型化的命令存储方法固定；读写共享同一事务，
    /// SQLite 绝不允许把溢出的整数计数器提升为 REAL。
    ///
    /// - Parameters:
    ///   - table: 命令所在表名。
    ///   - keyColumn: 命令键所在列名。
    ///   - key: 命令键值。
    ///   - nextAttemptAt: 下一次尝试时间。
    ///   - db: 参与当前事务的数据库连接。
    /// - Throws: 时间不可表示、记录缺失、计数溢出或写入失败时抛出 `commandConflict`。
    static func scheduleCommandRetry(table: String, keyColumn: String, key: String, nextAttemptAt: Date, db: Database) throws {
        guard nextAttemptAt.timeIntervalSince1970.isFinite else { throw V2ClientCommandError.commandConflict }
        guard let row = try Row.fetchOne(db, sql: "SELECT attempt_count FROM \(table) WHERE \(keyColumn) = ?", arguments: [key])
        else { throw V2ClientCommandError.commandConflict }
        let count = try commandAttemptCount(row)
        let (next, overflow) = count.addingReportingOverflow(1)
        guard !overflow, Int64(exactly: next) != nil else { throw V2ClientCommandError.commandConflict }
        try db.execute(sql: "UPDATE \(table) SET attempt_count = ?, next_attempt_at = ? WHERE \(keyColumn) = ?",
                       arguments: [next, nextAttemptAt.timeIntervalSince1970, key])
    }
}
