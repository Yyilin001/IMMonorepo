import Crypto
import Foundation
import IMV2Core

/// The announcement revision orders its value. Older payloads legitimately
/// lack source room sequence; a recipient cursor cannot fill that field.
struct V2LocalAnnouncementEffect {
    let sourceEventID: EventID
    let roomID: RoomID
    let revision: Int64
    let body: String
    let updatedAtMilliseconds: Int64
    let roomSequence: Int64?
    let digest: Data

    init(record: V2ClientSyncRecord, expectedRoomSequence: UInt64? = nil, expectedRoomID: RoomID? = nil) throws {
        struct Wire: Decodable {
            let event_type: String; let room_id: String; let revision: Int64
            let body: String; let server_created_at_ms: Int64
            let actor_user_id: String?; let room_sequence: Int64?
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: record.payload)
            guard record.projectionKind == "group_capability",
                  wire.event_type == "group.announcement_changed", wire.revision > 0,
                  UUID(uuidString: wire.room_id) != nil,
                  wire.actor_user_id.map({ UUID(uuidString: $0) != nil }) ?? true,
                  wire.server_created_at_ms >= 0,
                  wire.body.utf8.count <= V2GroupAnnouncementCommand.maximumUTF8Bytes,
                  wire.room_sequence.map({ $0 > 0 }) ?? true
            else { throw V2ClientProjectionError.invalidMessagePayload }
            if let expectedRoomSequence, let sequence = wire.room_sequence {
                guard UInt64(sequence) == expectedRoomSequence else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            sourceEventID = record.sourceEventID
            roomID = try .init(wire.room_id)
            guard expectedRoomID == nil || expectedRoomID == roomID else { throw V2ClientProjectionError.invalidMessagePayload }
            revision = wire.revision
            body = wire.body
            updatedAtMilliseconds = wire.server_created_at_ms
            roomSequence = wire.room_sequence
            struct Canonical: Encodable {
                let version = 1
                let room: String; let revision: Int64; let body: String
                let updatedAt: Int64; let actor: String?
            }
            let actor = try wire.actor_user_id.map(UserID.init)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            digest = Data(SHA256.hash(data: try encoder.encode(Canonical(
                room: roomID.rawValue, revision: revision, body: body,
                updatedAt: updatedAtMilliseconds, actor: actor?.rawValue
            ))))
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
