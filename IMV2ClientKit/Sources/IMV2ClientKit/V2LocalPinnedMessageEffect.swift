import Crypto
import Foundation
import IMV2Core

/// Pin order comes from the source room log, including a validated room
/// envelope for legacy payloads. A personal cursor cannot fill that field.
struct V2LocalPinnedMessageEffect {
    let sourceEventID: EventID
    let roomID: RoomID
    let messageID: MessageID
    let isPinned: Bool
    let updatedAtMilliseconds: Int64
    let roomSequence: Int64?
    let digest: Data

    init(record: V2ClientSyncRecord, expectedRoomSequence: UInt64? = nil, expectedRoomID: RoomID? = nil) throws {
        struct Wire: Decodable {
            let event_type: String; let room_id: String; let message_id: String
            let is_pinned: Bool; let server_created_at_ms: Int64
            let actor_user_id: String?; let room_sequence: Int64?
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: record.payload)
            guard record.projectionKind == "group_capability",
                  wire.event_type == "message.pinned_changed",
                  UUID(uuidString: wire.message_id) != nil,
                  UUID(uuidString: wire.room_id) != nil,
                  wire.actor_user_id.map({ UUID(uuidString: $0) != nil }) ?? true,
                  wire.server_created_at_ms >= 0,
                  wire.room_sequence.map({ $0 > 0 }) ?? true
            else { throw V2ClientProjectionError.invalidMessagePayload }
            if let expectedRoomSequence, let sequence = wire.room_sequence {
                guard UInt64(sequence) == expectedRoomSequence else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            sourceEventID = record.sourceEventID
            roomID = try .init(wire.room_id)
            guard expectedRoomID == nil || expectedRoomID == roomID else { throw V2ClientProjectionError.invalidMessagePayload }
            messageID = try .init(wire.message_id)
            isPinned = wire.is_pinned
            updatedAtMilliseconds = wire.server_created_at_ms
            if let expectedRoomSequence {
                guard expectedRoomSequence > 0, let source = Int64(exactly: expectedRoomSequence) else { throw V2ClientProjectionError.invalidMessagePayload }
                roomSequence = source
            } else {
                roomSequence = wire.room_sequence
            }
            struct Canonical: Encodable {
                let version = 1
                let room: String; let message: String; let isPinned: Bool
                let updatedAt: Int64; let actor: String?
            }
            let actor = try wire.actor_user_id.map(UserID.init)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            digest = Data(SHA256.hash(data: try encoder.encode(Canonical(
                room: roomID.rawValue, message: messageID.rawValue, isPinned: isPinned,
                updatedAt: updatedAtMilliseconds, actor: actor?.rawValue
            ))))
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
