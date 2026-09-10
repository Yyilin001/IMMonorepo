import Foundation
import NIOCore
import PostgresNIO

/// 在持久化记录复制时保留 PostgreSQL 原始微秒偏移的时间戳。
///
/// 数据库二进制解码与编码直接传递 `Int64`，避免经 `Date` 的浮点秒数中转而丢失微秒精度。
/// 数据库入口仅接受有限范围内的 `timestamptz`；新日期应通过 `init(date:)` 校验。
/// `Codable` 使用合成实现，不执行数据库解码入口的范围检查；不要将不可信的通用解码结果
/// 直接视为已通过数据库范围验证的时间戳。
struct V2PostgresTimestamp: Codable, Equatable, Sendable, PostgresNonThrowingEncodable, PostgresDecodable {
    /// 相对 2000-01-01 UTC 的有符号微秒偏移，保留数据库原始整数精度。
    let microseconds: Int64
    /// PostgreSQL 参数类型为带时区时间戳。
    static var psqlType: PostgresDataType { .timestamptz }
    /// 使用固定八字节整数的二进制传输格式。
    static var psqlFormat: PostgresFormat { .binary }

    /// 从新生成的日期创建可持久化时间戳。
    ///
    /// - Parameter date: 待写入的绝对日期；相对数据库纪元的微秒数按向零截断转换。
    /// - Throws: 日期非有限、整数转换溢出或超出数据库有限范围时，抛出
    ///   `V2RoomWriteStoreError.corruptPersistenceState`。
    init(date: Date) throws {
        let epoch = Date(timeIntervalSince1970: 946_684_800)
        guard let value = Int64(exactly: (date.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)),
              v2PostgresTimestampMicrosecondsCanEncode(value) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        microseconds = value
    }

    /// 转换为供业务层使用的近似绝对日期。
    ///
    /// 大幅偏离纪元的微秒值可能在 `Double` 转换中失去精度。需要精确保留持久化值时，
    /// 应直接编码当前对象，避免先取此属性再调用日期初始化器。
    var date: Date {
        Date(timeInterval: Double(microseconds) / 1_000_000,
             since: Date(timeIntervalSince1970: 946_684_800))
    }

    /// 从 PostgreSQL 二进制字段读取一个有限时间戳。
    ///
    /// - Parameters:
    ///   - buffer: 恰好包含八字节微秒整数的字段缓冲区；读取整数后读指针会推进。
    ///   - type: 必须是 `timestamptz`，不接受无时区时间戳或其他字段类型。
    ///   - format: 必须是二进制格式。
    ///   - context: 驱动提供的解码上下文；此实现不使用 JSON 解码器。
    /// - Throws: 类型、格式、字节长度或时间范围不满足要求时抛出
    ///   `PostgresDecodingError.Code.failure`。范围校验失败时不会回退已推进的读指针。
    init<Decoder: PostgresJSONDecoder>(from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat, context: PostgresDecodingContext<Decoder>) throws {
        guard type == .timestamptz, format == .binary, buffer.readableBytes == 8,
              let value = buffer.readInteger(as: Int64.self),
              v2PostgresTimestampMicrosecondsCanEncode(value) else {
            throw PostgresDecodingError.Code.failure
        }
        microseconds = value
    }

    /// 将保存的微秒整数原样追加到 PostgreSQL 参数缓冲区。
    ///
    /// - Parameters:
    ///   - buffer: 接收八字节整数的输出缓冲区。
    ///   - context: 驱动提供的编码上下文；此实现不使用 JSON 编码器。
    ///
    /// 本方法不重新校验范围；调用方应使用经日期或数据库解码入口验证的实例。
    func encode<Encoder: PostgresJSONEncoder>(into buffer: inout ByteBuffer, context: PostgresEncodingContext<Encoder>) {
        buffer.writeInteger(microseconds)
    }
}
