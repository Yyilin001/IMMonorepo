import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 按身份索引的恢复读取；两个入口都不读取全局活动排名。
public struct PostgresV2RoomRecoveryStore: V2RoomStateReading, V2UserRoomDirectoryReading {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String = "im_v2") throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        self.database = database
        self.schema = schema
    }

    public func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        guard !roomIDs.isEmpty, roomIDs.count <= 100, let actor = actorUserID.uuidValue,
              roomIDs.allSatisfy({ $0.uuidValue != nil }) else { throw V2RoomRecoveryReadError.invalidRequest }
        guard let sql = database as? any SQLDatabase else { throw V2RoomRecoveryReadError.corruptPersistence }
        let ids = Array(Set(roomIDs.compactMap(\.uuidValue)))
        // 单条语句快照绑定授权、所有者、日志头和计数器。
        // 横向查询中的 OFFSET 0 使成员关系查询仍按每个请求房间参数化。
        // 它保留全部匹配，使重复项在解码校验时报错，
        // 而非被 LIMIT 1 悄然隐藏。
        let rows = try await sql.raw("""
            SELECT room.room_id, room.owner_epoch, member.joined_revision,
                   room.room_sequence AS head, room.log_trimmed_through_room_sequence AS trimmed,
                   COALESCE(receipt.read_through_room_sequence, 0) AS read_through,
                   COALESCE(own.room_sequence, 0) AS own_sequence
            FROM \(unsafeRaw: schema).rooms AS room
            JOIN LATERAL (
                SELECT member.joined_revision
                FROM \(unsafeRaw: schema).room_memberships AS member
                WHERE member.room_id = room.room_id AND member.user_id = \(bind: actor)
                  AND member.left_revision IS NULL AND member.joined_revision <= room.membership_revision
                OFFSET 0
            ) AS member ON TRUE
            LEFT JOIN \(unsafeRaw: schema).room_read_receipts AS receipt
              ON receipt.room_id = room.room_id AND receipt.user_id = \(bind: actor)
            LEFT JOIN LATERAL (
                SELECT message.room_sequence FROM \(unsafeRaw: schema).messages AS message
                WHERE message.room_id = room.room_id AND message.sender_user_id = \(bind: actor)
                ORDER BY message.room_sequence DESC LIMIT 1
            ) AS own ON TRUE
            WHERE room.room_id = ANY(\(bind: ids)::uuid[])
            """).all(decoding: RecoveryStateRow.self)
        var result = Dictionary(uniqueKeysWithValues: Set(roomIDs).map { ($0, V2RoomStateReadResult.unavailable) })
        var seen: Set<RoomID> = []
        for row in rows {
            let id = RoomID(uuid: row.roomID)
            guard seen.insert(id).inserted,
                  [row.ownerEpoch, row.joinedRevision, row.head, row.trimmed, row.readThrough, row.ownSequence].allSatisfy({ $0 >= 0 })
            else { throw V2RoomRecoveryReadError.corruptPersistence }
            let state = try V2RoomSynchronizationState(roomID: id, ownerEpoch: UInt64(row.ownerEpoch),
                viewerMembershipRevision: UInt64(row.joinedRevision), head: UInt64(row.head),
                trimmedThrough: UInt64(row.trimmed), readThrough: UInt64(row.readThrough),
                latestOwnMessageSequence: UInt64(row.ownSequence))
            result[id] = .state(state)
        }
        return result
    }

    public func rooms(actorUserID: UserID, after: RoomID?, limit: Int) async throws -> V2UserRoomDirectorySlice {
        guard limit > 0, limit <= 100, let actor = actorUserID.uuidValue,
              after == nil || after?.uuidValue != nil else { throw V2RoomRecoveryReadError.invalidRequest }
        guard let sql = database as? any SQLDatabase else { throw V2RoomRecoveryReadError.corruptPersistence }
        let predicate: SQLQueryString = if let after { "member.room_id > \(bind: after.uuidValue!)" } else { "TRUE" }
        let rows = try await sql.raw("""
            WITH candidates AS MATERIALIZED (
                SELECT member.room_id, member.joined_revision
                FROM \(unsafeRaw: schema).room_memberships AS member
                WHERE member.user_id = \(bind: actor) AND member.left_revision IS NULL AND \(predicate)
                ORDER BY member.room_id LIMIT \(bind: limit + 1)
            )
            SELECT candidate.room_id, candidate.joined_revision, room.room_kind, room.owner_epoch,
                   room.membership_revision
            FROM candidates AS candidate
            LEFT JOIN LATERAL (
                SELECT room_kind, owner_epoch, membership_revision
                FROM \(unsafeRaw: schema).rooms WHERE room_id = candidate.room_id LIMIT 1
            ) AS room ON TRUE
            ORDER BY candidate.room_id
            """).all(decoding: RecoveryDirectoryRow.self)
        let hasMore = rows.count > limit
        let scanned = Array(rows.prefix(limit))
        var seen: Set<UUID> = []
        var entries: [V2UserRoomDirectoryEntry] = []
        for row in scanned {
            guard seen.insert(row.roomID).inserted else { throw V2RoomRecoveryReadError.corruptPersistence }
            guard let kind = row.roomKind, let epoch = row.ownerEpoch, let revision = row.membershipRevision else { continue }
            guard let kind = V2RoomKind(rawValue: kind), epoch >= 0, row.joinedRevision > 0 else {
                throw V2RoomRecoveryReadError.corruptPersistence
            }
            guard row.joinedRevision <= revision else { continue }
            entries.append(try .init(roomID: .init(uuid: row.roomID), roomKind: kind,
                viewerMembershipRevision: UInt64(row.joinedRevision), ownerEpoch: UInt64(epoch)))
        }
        return .init(entries: entries, scannedThrough: scanned.last.map { .init(uuid: $0.roomID) }, hasMore: hasMore)
    }
}

private struct RecoveryStateRow: Decodable {
    let roomID: UUID
    let ownerEpoch: Int64
    let joinedRevision: Int64
    let head: Int64
    let trimmed: Int64
    let readThrough: Int64
    let ownSequence: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", ownerEpoch = "owner_epoch", joinedRevision = "joined_revision"
        case head, trimmed, readThrough = "read_through", ownSequence = "own_sequence"
    }
}

private struct RecoveryDirectoryRow: Decodable {
    let roomID: UUID
    let joinedRevision: Int64
    let roomKind: String?
    let ownerEpoch: Int64?
    let membershipRevision: Int64?
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", joinedRevision = "joined_revision", roomKind = "room_kind"
        case ownerEpoch = "owner_epoch", membershipRevision = "membership_revision"
    }
}
