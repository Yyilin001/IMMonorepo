import Crypto
import Foundation
import IMV2Core

/// A durable invalidation floor, never nickname content or an authorization lease.
struct V2LocalGroupNicknameEffect {
    let sourceEventID: EventID
    let roomID: RoomID
    let userID: UserID
    let revision: Int64
    let roomSequence: Int64
    let updatedAtMilliseconds: Int64
    let digest: Data

    init(record: V2ClientSyncRecord, expectedRoomSequence: UInt64? = nil, expectedRoomID: RoomID? = nil) throws {
        struct Wire: Decodable {
            let event_type: String; let room_id: String; let target_user_id: String; let revision: Int64
            let room_sequence: Int64; let server_created_at_ms: Int64
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: record.payload) as? [String: Any],
                  Set(object.keys) == ["event_type", "room_id", "target_user_id", "revision", "room_sequence", "server_created_at_ms"]
            else { throw V2ClientProjectionError.invalidMessagePayload }
            let wire = try JSONDecoder().decode(Wire.self, from: record.payload)
            guard record.projectionKind == "group_capability", wire.event_type == "group.nickname_changed",
                  expectedRoomSequence == nil || expectedRoomSequence == UInt64(exactly: wire.room_sequence)
            else { throw V2ClientProjectionError.invalidMessagePayload }
            try self.init(sourceEventID: record.sourceEventID, roomID: .init(wire.room_id), userID: .init(wire.target_user_id), revision: wire.revision,
                roomSequence: wire.room_sequence, updatedAtMilliseconds: wire.server_created_at_ms)
            guard expectedRoomID == nil || expectedRoomID == roomID else { throw V2ClientProjectionError.invalidMessagePayload }
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }

    init(sourceEventID: EventID, roomID: RoomID, userID: UserID, revision: Int64, roomSequence: Int64, updatedAtMilliseconds: Int64) throws {
        guard roomID.uuidValue != nil, userID.uuidValue != nil, revision > 0, roomSequence > 0, updatedAtMilliseconds >= 0 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        self.sourceEventID = sourceEventID; self.roomID = roomID; self.userID = userID; self.revision = revision
        self.roomSequence = roomSequence; self.updatedAtMilliseconds = updatedAtMilliseconds
        struct Canonical: Encodable {
            let version = 1
            let room: String; let user: String; let revision: Int64; let sequence: Int64; let updatedAt: Int64
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        digest = Data(SHA256.hash(data: try encoder.encode(Canonical(room: roomID.rawValue, user: userID.rawValue,
            revision: revision, sequence: roomSequence, updatedAt: updatedAtMilliseconds))))
    }
}

extension GRDBV2LocalSyncStore {
    static let groupNicknameInvalidationSchemaSQL = """
        CREATE TABLE v2_group_nickname_invalidations (
            room_id TEXT NOT NULL, user_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
            room_sequence INTEGER NOT NULL CHECK(typeof(room_sequence)='integer' AND room_sequence>0),
            updated_at_ms INTEGER NOT NULL CHECK(typeof(updated_at_ms)='integer' AND updated_at_ms>=0),
            source_event_id TEXT NOT NULL,
            canonical_digest BLOB NOT NULL CHECK(length(canonical_digest)=32),
            PRIMARY KEY(room_id,user_id)
        );
        CREATE INDEX v2_group_nickname_room_sequence ON v2_group_nickname_invalidations(room_id,room_sequence);
        CREATE INDEX v2_group_nickname_invalid_sequence ON v2_group_nickname_invalidations(room_id)
            WHERE typeof(room_sequence)<>'integer' OR room_sequence<1;
        CREATE TABLE v2_group_nickname_effects (
            source_event_id TEXT NOT NULL, room_id TEXT NOT NULL, user_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
            room_sequence INTEGER NOT NULL CHECK(typeof(room_sequence)='integer' AND room_sequence>0),
            updated_at_ms INTEGER NOT NULL CHECK(typeof(updated_at_ms)='integer' AND updated_at_ms>=0),
            canonical_digest BLOB NOT NULL CHECK(length(canonical_digest)=32),
            PRIMARY KEY(source_event_id,room_id), UNIQUE(room_id,user_id,revision), UNIQUE(room_id,room_sequence)
        );
        """
}
