import Foundation

/// 在持久化记录复制时保留 PostgreSQL 原始微秒偏移的时间戳。
///
/// 数据库二进制解码与编码直接传递 `Int64`，避免经 `Date` 的浮点秒数中转而丢失微秒精度。
/// 数据库入口仅接受有限范围内的 `timestamptz`；新日期应通过 `init(date:)` 校验。
/// `Codable` 使用合成实现，不执行数据库解码入口的范围检查；不要将不可信的通用解码结果
/// 直接视为已通过数据库范围验证的时间戳。
package struct V2PersistenceTimestamp: Codable, Equatable, Sendable {
    /// 相对 2000-01-01 UTC 的有符号微秒偏移，保留数据库原始整数精度。
    package let microseconds: Int64

    /// Validates a precise persisted offset without converting through Date.
    package init(microseconds: Int64) throws {
        guard v2PostgresTimestampMicrosecondsCanEncode(microseconds) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        self.microseconds = microseconds
    }

    /// 从新生成的日期创建可持久化时间戳。
    ///
    /// - Parameter date: 待写入的绝对日期；相对数据库纪元的微秒数按向零截断转换。
    /// - Throws: 日期非有限、整数转换溢出或超出数据库有限范围时，抛出
    ///   `V2RoomWriteStoreError.corruptPersistenceState`。
    package init(date: Date) throws {
        let epoch = Date(timeIntervalSince1970: 946_684_800)
        guard let value = Int64(exactly: (date.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)),
              v2PostgresTimestampMicrosecondsCanEncode(value) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        microseconds = value
    }

    /// Preserve a protocol timestamp without a floating-point Date round trip.
    package init(unixMilliseconds: UInt64) throws {
        guard let value = Int64(exactly: unixMilliseconds) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let offset = value - 946_684_800_000
        let (micros, overflow) = offset.multipliedReportingOverflow(by: 1_000)
        guard !overflow, v2PostgresTimestampMicrosecondsCanEncode(micros) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        microseconds = micros
    }

    /// 转换为供业务层使用的近似绝对日期。
    ///
    /// 大幅偏离纪元的微秒值可能在 `Double` 转换中失去精度。需要精确保留持久化值时，
    /// 应直接编码当前对象，避免先取此属性再调用日期初始化器。
    package var date: Date {
        Date(timeInterval: Double(microseconds) / 1_000_000,
             since: Date(timeIntervalSince1970: 946_684_800))
    }

}
