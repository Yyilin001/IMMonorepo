import IMV2ServerContracts
import Foundation

/// Immutable PostgreSQL microsecond anchors survive review or deletion of their rows.
/// Only the current cursor shape is accepted; retired text timestamps are rejected.
package struct V2GroupJoinPageCursor: Codable {
    package let version: Int
    package let filter: String
    package let roomID: UUID
    package let createdAtMicroseconds: Int64
    package let requestID: UUID
    private enum CodingKeys: String, CodingKey {
        case version, filter, roomID, createdAtMicroseconds, requestID, createdAt
    }
    package init(roomID: UUID, timestampMicroseconds: Int64, requestID: UUID) {
        self.version = 2; self.filter = "pending"; self.roomID = roomID
        self.createdAtMicroseconds = timestampMicroseconds; self.requestID = requestID
    }
    package init(from decoder: any Decoder) throws {
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
    package func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(filter, forKey: .filter)
        try values.encode(roomID, forKey: .roomID); try values.encode(createdAtMicroseconds, forKey: .createdAtMicroseconds)
        try values.encode(requestID, forKey: .requestID)
    }
    package func encoded() throws -> String {
        guard v2PostgresTimestampMicrosecondsCanEncode(createdAtMicroseconds)
        else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        return try JSONEncoder().encode(self).base64EncodedString()
    }
    package static func decode(_ value: String, roomID: UUID) throws -> Self {
        guard value.utf8.count <= 1_024, let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.roomID == roomID
        else { throw V2GroupInvitationServiceError.invalidRequest }
        return cursor
    }
}
