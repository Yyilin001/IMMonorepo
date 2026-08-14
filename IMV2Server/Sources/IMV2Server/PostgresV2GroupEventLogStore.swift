import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct PostgresV2GroupEventLogStore: V2GroupEventLogStore {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

    public func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        guard let sql = database as? any SQLDatabase,
              let roomUUID = UUID(uuidString: roomID.rawValue),
              let actorUUID = UUID(uuidString: actorUserID.rawValue),
              afterRoomSequence <= UInt64(Int64.max)
        else { throw V2GroupEventLogError.corruptPersistenceState }
        _ = try await authorizedGroupRoom(roomID: roomID, actorUserID: actorUserID, sql: sql)

        let rows = try await sql.raw("""
            SELECT event_id, room_sequence, event_type, payload::text AS payload_json
            FROM im_v2.room_events AS event
            WHERE event.room_id = \(bind: roomUUID)
              AND event.room_sequence > \(bind: Int64(afterRoomSequence))
              AND EXISTS (
                  SELECT 1 FROM im_v2.room_memberships AS membership
                  WHERE membership.room_id = event.room_id
                    AND membership.user_id = \(bind: actorUUID)
                    AND membership.joined_revision <= event.committed_membership_revision
                    AND (membership.left_revision IS NULL OR membership.left_revision > event.committed_membership_revision)
              )
            ORDER BY event.room_sequence
            LIMIT \(bind: pageSize + 1)
            """).all(decoding: GroupEventLogRow.self)
        let hasMore = rows.count > pageSize
        let pageRows = hasMore ? Array(rows.prefix(pageSize)) : rows
        let entries: [V2GroupEventLogEntry] = try pageRows.map { row in
            guard let payload = row.payloadJSON.data(using: .utf8) else { throw V2GroupEventLogError.corruptPersistenceState }
            return V2GroupEventLogEntry(
                sourceEventID: try EventID(row.eventID.uuidString),
                roomSequence: try groupEventUnsigned(row.roomSequence),
                projectionKind: groupEventProjectionKind(for: row.eventType),
                payload: payload
            )
        }
        let next = entries.last?.roomSequence ?? afterRoomSequence
        return V2GroupEventLogPage(roomID: roomID, events: entries, nextRoomSequence: next, hasMore: hasMore)
    }

    public func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        guard let sql = database as? any SQLDatabase else {
            throw V2GroupEventLogError.corruptPersistenceState
        }
        let room = try await authorizedGroupRoom(roomID: roomID, actorUserID: actorUserID, sql: sql)
        return .init(roomID: roomID, highWatermark: try groupEventUnsigned(room.roomSequence))
    }

    /// Both immutable group modes can make a foreground room-event read. A
    /// standard group's read is only an online preview; reliable fan-out and
    /// its per-user acknowledgement remain authoritative. Membership is
    /// rechecked on every pull, so a stale hint never reveals payload data.
    private func authorizedGroupRoom(
        roomID: RoomID,
        actorUserID: UserID,
        sql: any SQLDatabase
    ) async throws -> GroupEventLogRoomRow {
        guard let roomUUID = UUID(uuidString: roomID.rawValue),
              let actorUUID = UUID(uuidString: actorUserID.rawValue)
        else { throw V2GroupEventLogError.corruptPersistenceState }
        guard let room = try await sql.raw("""
            SELECT room_sequence, room_kind,
                   EXISTS (
                       SELECT 1 FROM im_v2.room_memberships AS membership
                       WHERE membership.room_id = rooms.room_id
                         AND membership.user_id = \(bind: actorUUID)
                         AND membership.joined_revision <= rooms.membership_revision
                         AND (membership.left_revision IS NULL OR membership.left_revision > rooms.membership_revision)
                   ) AS actor_is_active_member
            FROM im_v2.rooms AS rooms
            WHERE rooms.room_id = \(bind: roomUUID)
            """).first(decoding: GroupEventLogRoomRow.self)
        else { throw V2GroupEventLogError.roomNotFound }
        guard room.roomKind == "group" else { throw V2GroupEventLogError.roomNotFound }
        guard room.actorIsActiveMember else { throw V2GroupEventLogError.actorNotMember }
        return room
    }
}

private struct GroupEventLogRoomRow: Decodable {
    let roomSequence: Int64
    let roomKind: String
    let actorIsActiveMember: Bool
    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case roomKind = "room_kind"
        case actorIsActiveMember = "actor_is_active_member"
    }
}

private struct GroupEventLogRow: Decodable {
    let eventID: UUID
    let roomSequence: Int64
    let eventType: String
    let payloadJSON: String
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case roomSequence = "room_sequence"
        case eventType = "event_type"
        case payloadJSON = "payload_json"
    }
}

private func groupEventUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2GroupEventLogError.corruptPersistenceState }
    return UInt64(value)
}

private func groupEventProjectionKind(for eventType: String) -> String {
    switch eventType {
    case "room.created": "room"
    case "membership_changed": "membership"
    case "member.muted", "room.frozen", "room.unfrozen": "moderation"
    case "message.reaction_changed": "message_reaction"
    case "message.pinned_changed", "group.announcement_changed", "group.role_permissions_changed", "group.member_role_changed": "group_capability"
    default: "message"
    }
}
