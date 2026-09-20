import Foundation
import NIOCore
import PostgresNIO

/// 入群申请分页游标。
///
/// 游标中的比较键不可变，锚点记录被审核或删除后仍然可用。版本 2 保留 PostgreSQL 的完整有限
/// 范围与精确微秒；版本 1 仅用于继续读取此前签发的文本游标。
struct V2GroupJoinPageCursor: Codable {
    /// 载荷结构版本。
    var version = 2
    /// 过滤条件标识，固定为待处理或审批中。
    var filter = "pending"
    /// 目标房间。
    let roomID: UUID
    /// 版本 1 使用的文本时间戳。
    let createdAt: String?
    /// 版本 2 使用的微秒时间戳。
    let createdAtMicroseconds: Int64?
    /// 锚点申请标识。
    let requestID: UUID

    /// 以微秒时间戳构造版本 2 游标。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - timestamp: 锚点时间戳。
    ///   - requestID: 锚点申请标识。
    init(roomID: UUID, timestamp: V2GroupJoinCursorTimestamp, requestID: UUID) {
        self.roomID = roomID
        createdAt = nil
        createdAtMicroseconds = timestamp.microseconds
        self.requestID = requestID
    }

    /// 编码为可对外返回的游标字符串。
    ///
    /// - Returns: Base64 编码的 JSON 游标。
    /// - Throws: 微秒时间戳缺失或超出可编码范围时抛出
    ///   ``V2GroupInvitationServiceError/corruptPersistenceState``。
    func encoded() throws -> String {
        guard let createdAtMicroseconds,
              v2PostgresTimestampMicrosecondsCanEncode(createdAtMicroseconds)
        else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        return try JSONEncoder().encode(self).base64EncodedString()
    }

    /// 解码并校验游标。
    ///
    /// 长度、Base64 解码、过滤条件与房间一致性任一不符即拒绝；随后按版本校验字段组合，
    /// 版本 1 还会校验文本时间戳的精确格式。
    ///
    /// - Parameters:
    ///   - value: 客户端提交的游标字符串。
    ///   - roomID: 本次请求的目标房间。
    /// - Returns: 解码后的游标。
    /// - Throws: 游标超长、无法解码、房间不符、版本未知或字段组合非法时抛出
    ///   ``V2GroupInvitationServiceError/invalidRequest``。
    static func decode(_ value: String, roomID: UUID) throws -> Self {
        guard value.utf8.count <= 1_024,
              let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.filter == "pending", cursor.roomID == roomID
        else { throw V2GroupInvitationServiceError.invalidRequest }
        switch cursor.version {
        case 2:
            guard cursor.createdAt == nil, let microseconds = cursor.createdAtMicroseconds,
                  v2PostgresTimestampMicrosecondsCanEncode(microseconds)
            else { throw V2GroupInvitationServiceError.invalidRequest }
        case 1:
            guard cursor.createdAtMicroseconds == nil, let createdAt = cursor.createdAt,
                  createdAt.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$"#, options: .regularExpression) != nil
            else { throw V2GroupInvitationServiceError.invalidRequest }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
            formatter.isLenient = false
            guard formatter.date(from: createdAt) != nil else { throw V2GroupInvitationServiceError.invalidRequest }
        default: throw V2GroupInvitationServiceError.invalidRequest
        }
        return cursor
    }

    /// 生成与游标版本匹配的时间戳绑定值。
    ///
    /// - Returns: 版本 2 返回二进制微秒时间戳，版本 1 返回原文本时间戳。
    /// - Throws: 版本与时间戳字段不匹配时抛出
    ///   ``V2GroupInvitationServiceError/invalidRequest``。
    func timestampBinding() throws -> any Encodable & Sendable {
        if version == 2, let createdAtMicroseconds {
            return V2GroupJoinCursorTimestamp(microseconds: createdAtMicroseconds)
        }
        if version == 1, let createdAt { return createdAt }
        throw V2GroupInvitationServiceError.invalidRequest
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
