import Foundation
import NIOCore
import PostgresNIO

/// Immutable PostgreSQL microsecond anchors survive review or deletion of their rows.
/// Only the current cursor shape is accepted; retired text timestamps are rejected.
struct V2GroupJoinPageCursor: Codable {
    let version: Int
    let filter: String
    let roomID: UUID
    let createdAtMicroseconds: Int64
    let requestID: UUID
    private enum CodingKeys: String, CodingKey {
        case version, filter, roomID, createdAtMicroseconds, requestID, createdAt
    }
    init(roomID: UUID, timestamp: V2GroupJoinCursorTimestamp, requestID: UUID) {
        self.version = 2; self.filter = "pending"; self.roomID = roomID
        self.createdAtMicroseconds = timestamp.microseconds; self.requestID = requestID
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard !values.contains(.createdAt) else { throw V2GroupInvitationServiceError.invalidRequest }
        version = try values.decode(Int.self, forKey: .version)
        filter = try values.decode(String.self, forKey: .filter)
        roomID = try values.decode(UUID.self, forKey: .roomID)
        createdAtMicroseconds = try values.decode(Int64.self, forKey: .createdAtMicroseconds)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        guard version == 2, filter == "pending", v2PostgresTimestampMicrosecondsCanEncode(createdAtMicroseconds)
        else { throw V2GroupInvitationServiceError.invalidRequest }
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(filter, forKey: .filter)
        try values.encode(roomID, forKey: .roomID); try values.encode(createdAtMicroseconds, forKey: .createdAtMicroseconds)
        try values.encode(requestID, forKey: .requestID)
    }
    func encoded() throws -> String {
        guard v2PostgresTimestampMicrosecondsCanEncode(createdAtMicroseconds)
        else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        return try JSONEncoder().encode(self).base64EncodedString()
    }
    static func decode(_ value: String, roomID: UUID) throws -> Self {
        guard value.utf8.count <= 1_024, let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.roomID == roomID
        else { throw V2GroupInvitationServiceError.invalidRequest }
        return cursor
    }
    func timestampBinding() throws -> V2GroupJoinCursorTimestamp {
        guard v2PostgresTimestampMicrosecondsCanEncode(createdAtMicroseconds)
        else { throw V2GroupInvitationServiceError.invalidRequest }
        return .init(microseconds: createdAtMicroseconds)
    }
}

/// 直接绑定二进制时间戳的游标时间类型。
///
/// 使用二进制绑定可同时避开历法/纪元格式化，以及在远离当前纪元时 `Date` 往返造成的微秒丢失。
struct V2GroupJoinCursorTimestamp: Codable, Sendable, PostgresNonThrowingEncodable, PostgresDecodable {
    /// 自纪元起的微秒数。
    let microseconds: Int64
    /// PostgreSQL 类型，固定为带时区时间戳。
    static var psqlType: PostgresDataType { .timestamptz }
    /// 绑定格式，固定为二进制。
    static var psqlFormat: PostgresFormat { .binary }

    /// 以微秒数构造。
    ///
    /// - Parameter microseconds: 自纪元起的微秒数。
    init(microseconds: Int64) { self.microseconds = microseconds }

    /// 从二进制缓冲区读取微秒数。
    ///
    /// - Parameters:
    ///   - buffer: 待读取的缓冲区。
    ///   - type: 声明类型，必须为带时区时间戳。
    ///   - format: 声明格式，必须为二进制。
    ///   - context: 解码上下文。
    /// - Throws: 类型或格式不符、长度不是 8 字节、整数读取失败时抛出
    ///   `PostgresDecodingError.Code.failure`。
    init<Decoder: PostgresJSONDecoder>(from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat, context: PostgresDecodingContext<Decoder>) throws {
        guard type == .timestamptz, format == .binary,
              buffer.readableBytes == 8, let value = buffer.readInteger(as: Int64.self)
        else { throw PostgresDecodingError.Code.failure }
        microseconds = value
    }

    /// 以二进制形式写出微秒数。
    ///
    /// - Parameters:
    ///   - buffer: 待写入的缓冲区。
    ///   - context: 编码上下文。
    func encode<Encoder: PostgresJSONEncoder>(into buffer: inout ByteBuffer, context: PostgresEncodingContext<Encoder>) {
        buffer.writeInteger(microseconds)
    }
}
