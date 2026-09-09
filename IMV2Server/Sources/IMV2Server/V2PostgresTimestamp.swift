import Foundation
import NIOCore
import PostgresNIO

/// An exact database timestamp for copying persisted rows. Foundation Date
/// is an approximation and must not sit between database decode and encode.
struct V2PostgresTimestamp: Codable, Equatable, Sendable, PostgresNonThrowingEncodable, PostgresDecodable {
    let microseconds: Int64
    static var psqlType: PostgresDataType { .timestamptz }
    static var psqlFormat: PostgresFormat { .binary }

    init(date: Date) throws {
        let epoch = Date(timeIntervalSince1970: 946_684_800)
        guard let value = Int64(exactly: (date.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)),
              v2PostgresTimestampMicrosecondsCanEncode(value) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        microseconds = value
    }

    var date: Date {
        Date(timeInterval: Double(microseconds) / 1_000_000,
             since: Date(timeIntervalSince1970: 946_684_800))
    }

    init<Decoder: PostgresJSONDecoder>(from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat, context: PostgresDecodingContext<Decoder>) throws {
        guard type == .timestamptz, format == .binary, buffer.readableBytes == 8,
              let value = buffer.readInteger(as: Int64.self),
              v2PostgresTimestampMicrosecondsCanEncode(value) else {
            throw PostgresDecodingError.Code.failure
        }
        microseconds = value
    }

    func encode<Encoder: PostgresJSONEncoder>(into buffer: inout ByteBuffer, context: PostgresEncodingContext<Encoder>) {
        buffer.writeInteger(microseconds)
    }
}
