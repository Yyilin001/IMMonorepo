import Foundation
import NIOCore
import PostgresNIO

/// The immutable comparison key survives review/deletion of its anchor.
/// Version 2 preserves PostgreSQL's full finite range and exact microseconds;
/// version 1 remains readable for previously issued text cursors.
struct V2GroupJoinPageCursor: Codable {
    var version = 2
    var filter = "pending-or-approving"
    let roomID: UUID
    let createdAt: String?
    let createdAtMicroseconds: Int64?
    let requestID: UUID

    init(roomID: UUID, timestamp: V2GroupJoinCursorTimestamp, requestID: UUID) {
        self.roomID = roomID
        createdAt = nil
        createdAtMicroseconds = timestamp.microseconds
        self.requestID = requestID
    }

    func encoded() throws -> String {
        guard let createdAtMicroseconds,
              v2PostgresTimestampMicrosecondsCanEncode(createdAtMicroseconds)
        else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        return try JSONEncoder().encode(self).base64EncodedString()
    }

    static func decode(_ value: String, roomID: UUID) throws -> Self {
        guard value.utf8.count <= 1_024,
              let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.filter == "pending-or-approving", cursor.roomID == roomID
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

    func timestampBinding() throws -> any Encodable & Sendable {
        if version == 2, let createdAtMicroseconds {
            return V2GroupJoinCursorTimestamp(microseconds: createdAtMicroseconds)
        }
        if version == 1, let createdAt { return createdAt }
        throw V2GroupInvitationServiceError.invalidRequest
    }
}

/// Binding the raw binary timestamp avoids both calendar/era formatting and
/// the loss of microseconds caused by a Date round trip at distant epochs.
struct V2GroupJoinCursorTimestamp: Codable, Sendable, PostgresNonThrowingEncodable, PostgresDecodable {
    let microseconds: Int64
    static var psqlType: PostgresDataType { .timestamptz }
    static var psqlFormat: PostgresFormat { .binary }

    init(microseconds: Int64) { self.microseconds = microseconds }

    init<Decoder: PostgresJSONDecoder>(from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat, context: PostgresDecodingContext<Decoder>) throws {
        guard type == .timestamptz, format == .binary,
              buffer.readableBytes == 8, let value = buffer.readInteger(as: Int64.self)
        else { throw PostgresDecodingError.Code.failure }
        microseconds = value
    }

    func encode<Encoder: PostgresJSONEncoder>(into buffer: inout ByteBuffer, context: PostgresEncodingContext<Encoder>) {
        buffer.writeInteger(microseconds)
    }
}
