import Foundation
import IMV2Core

/// Current client-visible room-control state. The safety-service audit reason
/// intentionally never crosses this boundary.
public struct V2ClientRoomControlProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let actorUserID: UserID
    public let isFrozen: Bool
    public let createdAt: Date

    init(sourceEventID: EventID, roomID: RoomID, roomSequence: UInt64, actorUserID: UserID, isFrozen: Bool, createdAt: Date) throws {
        guard roomSequence > 0, createdAt.timeIntervalSince1970 >= 0 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.actorUserID = actorUserID
        self.isFrozen = isFrozen
        self.createdAt = createdAt
    }

    init(snapshotProjection: V2SnapshotRoomControlProjection) throws {
        try self.init(sourceEventID: snapshotProjection.sourceEventID, roomID: snapshotProjection.roomID, roomSequence: snapshotProjection.roomSequence, actorUserID: snapshotProjection.actorUserID, isFrozen: snapshotProjection.isFrozen, createdAt: snapshotProjection.createdAt)
    }

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String
            let roomID: String
            let roomSequence: UInt64
            let actorUserID: String
            let serverCreatedAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"
                case roomID = "room_id"
                case roomSequence = "room_sequence"
                case actorUserID = "actor_user_id"
                case serverCreatedAtMilliseconds = "server_created_at_ms"
            }
        }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard record.projectionKind == "moderation",
              payload.eventType == "room.frozen" || payload.eventType == "room.unfrozen",
              payload.roomSequence > 0, payload.serverCreatedAtMilliseconds >= 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            try self.init(sourceEventID: record.sourceEventID, roomID: .init(payload.roomID), roomSequence: payload.roomSequence, actorUserID: .init(payload.actorUserID), isFrozen: payload.eventType == "room.frozen", createdAt: Date(timeIntervalSince1970: TimeInterval(payload.serverCreatedAtMilliseconds) / 1_000))
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}
