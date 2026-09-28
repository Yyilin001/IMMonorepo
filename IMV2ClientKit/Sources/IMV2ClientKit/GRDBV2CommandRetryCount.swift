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

}
