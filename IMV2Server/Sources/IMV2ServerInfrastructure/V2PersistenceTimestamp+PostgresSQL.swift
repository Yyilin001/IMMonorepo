import IMV2ServerContracts
import Foundation
import NIOCore
import PostgresNIO

extension V2PersistenceTimestamp: PostgresNonThrowingEncodable, PostgresDecodable {
    package static var psqlType: PostgresDataType { .timestamptz }
    package static var psqlFormat: PostgresFormat { .binary }
    /// 从 PostgreSQL 二进制字段读取一个有限时间戳。
    ///
    /// - Parameters:
    ///   - buffer: 恰好包含八字节微秒整数的字段缓冲区；读取整数后读指针会推进。
    ///   - type: 必须是 `timestamptz`，不接受无时区时间戳或其他字段类型。
    ///   - format: 必须是二进制格式。
    ///   - context: 驱动提供的解码上下文；此实现不使用 JSON 解码器。
    /// - Throws: 类型、格式、字节长度或时间范围不满足要求时抛出
    ///   `PostgresDecodingError.Code.failure`。范围校验失败时不会回退已推进的读指针。
    package init<Decoder: PostgresJSONDecoder>(from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat, context: PostgresDecodingContext<Decoder>) throws {
        guard type == .timestamptz, format == .binary, buffer.readableBytes == 8,
              let value = buffer.readInteger(as: Int64.self),
              v2PostgresTimestampMicrosecondsCanEncode(value) else {
            throw PostgresDecodingError.Code.failure
        }
        try self.init(microseconds: value)
    }

    /// 将保存的微秒整数原样追加到 PostgreSQL 参数缓冲区。
    ///
    /// - Parameters:
    ///   - buffer: 接收八字节整数的输出缓冲区。
    ///   - context: 驱动提供的编码上下文；此实现不使用 JSON 编码器。
    ///
    /// 本方法不重新校验范围；调用方应使用经日期或数据库解码入口验证的实例。
    package func encode<Encoder: PostgresJSONEncoder>(into buffer: inout ByteBuffer, context: PostgresEncodingContext<Encoder>) {
        buffer.writeInteger(microseconds)
    }
}
