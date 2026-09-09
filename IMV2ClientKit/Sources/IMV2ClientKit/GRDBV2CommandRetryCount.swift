import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    static func commandRetryTimestamp(_ date: Date) throws -> Double {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { throw V2ClientCommandError.commandConflict }
        return seconds
    }

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

    static func commandAttemptCount(_ row: Row) throws -> Int {
        let value: DatabaseValue = row["attempt_count"]
        return try commandNonnegativeInteger(value)
    }

    static func commandNonnegativeInteger(_ value: DatabaseValue) throws -> Int {
        guard case .int64(let stored) = value.storage, stored >= 0,
              let count = Int(exactly: stored)
        else { throw V2ClientCommandError.commandConflict }
        return count
    }

    // Table and key column are fixed by the typed command-store methods.
    // Read and write share their transaction; SQLite must never promote an
    // overflowing integer counter to REAL.
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
