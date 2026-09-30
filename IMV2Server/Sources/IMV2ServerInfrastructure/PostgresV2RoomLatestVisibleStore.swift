import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 有界 ID 读取。单个 SQL 快照同时绑定消息版本、成员关系、所有者和头部；
/// 只还原请求者在具体修订提交时有权查看的正文，不补发离群期间的编辑。
/// 编辑受众事实独立于可裁剪的房间日志保留，裁剪不会让摘要退回旧修订。
public struct PostgresV2RoomLatestVisibleStore: V2RoomLatestVisibleReading {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String = "im_v2") throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        self.database = database; self.schema = schema
    }

    /// 供执行计划集成测试复用，以便测量生产环境使用的查询。
    static func latestVisibleQuery(schema: String, ids: [UUID], actor: UUID) -> SQLQueryString {
        """
            SELECT room.room_id, room.owner_epoch, member.joined_revision, room.room_sequence AS head,
                   latest.message_id, latest.sender_user_id, latest.room_sequence AS message_sequence,
                   latest.message_revision, latest.preview, latest.created_at,
                   (SELECT count(*) FROM \(unsafeRaw: schema).message_media_references AS media
                    WHERE media.message_id = latest.message_id AND media.revoked_at IS NULL) AS media_count
            FROM \(unsafeRaw: schema).rooms AS room
            JOIN \(unsafeRaw: schema).room_memberships AS member
              ON member.room_id = room.room_id AND member.user_id = \(bind: actor)
             AND member.left_revision IS NULL AND member.joined_revision <= room.membership_revision
            LEFT JOIN LATERAL (
                WITH recent AS MATERIALIZED (
                    SELECT message.message_id, CASE message.accepted_event_storage
                        WHEN 'message_row' THEN message.accepted_membership_revision
                        WHEN 'room_event' THEN event.committed_membership_revision END AS accepted_revision
                    FROM \(unsafeRaw: schema).messages AS message
                    LEFT JOIN \(unsafeRaw: schema).room_events AS event
                      ON message.accepted_event_storage = 'room_event'
                     AND event.room_id = message.room_id AND event.room_sequence = message.room_sequence
                     AND event.event_type = 'message.accepted'
                     AND lower(event.payload->>'message_id') = message.message_id::text
                    WHERE message.room_id = room.room_id AND message.room_sequence <= room.room_sequence
                      AND message.withdrawn_at IS NULL
                    ORDER BY message.room_sequence DESC, message.message_id DESC LIMIT 1
                ), fast AS MATERIALIZED (
                    SELECT recent.message_id FROM recent
                    WHERE EXISTS (
                        SELECT 1 FROM \(unsafeRaw: schema).room_memberships AS history
                        WHERE history.room_id = room.room_id AND history.user_id = \(bind: actor)
                          AND history.joined_revision <= recent.accepted_revision
                          AND (history.left_revision IS NULL OR history.left_revision > recent.accepted_revision)
                    )
                ), chosen AS (
                    SELECT message_id FROM fast
                    UNION ALL
                    SELECT fallback.message_id FROM (
                        WITH authorized AS MATERIALIZED (
                            SELECT candidate.message_id, candidate.room_sequence
                            FROM \(unsafeRaw: schema).room_memberships AS history
                            CROSS JOIN LATERAL (
                                SELECT message.message_id, message.room_sequence
                                FROM \(unsafeRaw: schema).messages AS message
                                WHERE message.room_id = history.room_id
                                  AND message.accepted_event_storage = 'message_row'
                                  AND message.withdrawn_at IS NULL
                                  AND message.accepted_membership_revision >= history.joined_revision
                                  AND message.accepted_membership_revision <= COALESCE(history.left_revision - 1, 9223372036854775807)
                                  AND message.room_sequence <= room.room_sequence
                                UNION ALL
                                SELECT message.message_id, message.room_sequence
                                FROM \(unsafeRaw: schema).room_events AS event
                                JOIN \(unsafeRaw: schema).messages AS message
                                  ON message.room_id = event.room_id AND message.room_sequence = event.room_sequence
                                 AND lower(event.payload->>'message_id') = message.message_id::text
                                 AND message.accepted_event_storage = 'room_event'
                                 AND message.withdrawn_at IS NULL
                                WHERE event.room_id = history.room_id AND event.event_type = 'message.accepted'
                                  AND event.committed_membership_revision >= history.joined_revision
                                  AND event.committed_membership_revision <= COALESCE(history.left_revision - 1, 9223372036854775807)
                                  AND event.room_sequence <= room.room_sequence
                            ) AS candidate
                            WHERE history.room_id = room.room_id AND history.user_id = \(bind: actor)
                        ) SELECT message_id FROM authorized
                        ORDER BY room_sequence DESC, message_id DESC LIMIT 1
                    ) AS fallback WHERE NOT EXISTS (SELECT 1 FROM fast)
                )
                SELECT message.message_id, message.sender_user_id, message.room_sequence,
                       COALESCE(visible_edit.message_revision, 1) AS message_revision,
                       left(CASE WHEN message.content_revision = COALESCE(visible_edit.message_revision, 1)
                                 THEN message.text_body ELSE snapshot.text_body END, 128) AS preview,
                       message.created_at
                FROM chosen JOIN \(unsafeRaw: schema).messages AS message ON message.message_id = chosen.message_id
                LEFT JOIN LATERAL (
                    SELECT content_event.message_revision
                    FROM \(unsafeRaw: schema).message_edit_visibility AS content_event
                    WHERE message.content_revision > 1
                      AND content_event.room_id = message.room_id
                      AND content_event.message_id = message.message_id
                      AND content_event.room_sequence <= room.room_sequence
                      AND content_event.message_revision BETWEEN 2 AND message.content_revision
                      AND EXISTS (
                          SELECT 1 FROM \(unsafeRaw: schema).room_memberships AS content_membership
                          WHERE content_membership.room_id = message.room_id
                            AND content_membership.user_id = \(bind: actor)
                            AND content_membership.joined_revision <= content_event.committed_membership_revision
                            AND (content_membership.left_revision IS NULL
                                 OR content_membership.left_revision > content_event.committed_membership_revision)
                      )
                    ORDER BY content_event.room_sequence DESC LIMIT 1
                ) AS visible_edit ON TRUE
                LEFT JOIN \(unsafeRaw: schema).message_content_versions AS snapshot
                  ON snapshot.message_id = message.message_id
                 AND snapshot.message_revision = COALESCE(visible_edit.message_revision, 1)
            ) AS latest ON TRUE
            WHERE room.room_id = ANY(\(bind: ids)::uuid[])
            """
    }

    public func latestVisible(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomLatestVisibleResult] {
        guard !roomIDs.isEmpty, roomIDs.count <= 100, let actor = actorUserID.uuidValue,
              roomIDs.allSatisfy({ $0.uuidValue != nil }) else { throw V2RoomRecoveryReadError.invalidRequest }
        guard let sql = database as? any SQLDatabase else { throw V2RoomRecoveryReadError.corruptPersistence }
        let ids = Array(Set(roomIDs.compactMap(\.uuidValue)))
        let rows = try await sql.raw(Self.latestVisibleQuery(schema: schema, ids: ids, actor: actor)).all(decoding: LatestVisibleRow.self)
        var result = Dictionary(uniqueKeysWithValues: Set(roomIDs).map { ($0, V2RoomLatestVisibleResult.unavailable) })
        for row in rows {
            guard row.ownerEpoch >= 0, row.joinedRevision > 0, row.head >= 0, row.mediaCount >= 0 else {
                throw V2RoomRecoveryReadError.corruptPersistence
            }
            let room = RoomID(uuid: row.roomID)
            let message: V2RoomLatestVisible.Message?
            if let id = row.messageID {
                guard let sender = row.senderUserID, let sequence = row.messageSequence, sequence > 0,
                      let revision = row.messageRevision, revision > 0, let preview = row.preview, let date = row.createdAt else {
                    throw V2RoomRecoveryReadError.corruptPersistence
                }
                message = try .init(id: .init(uuid: id), senderID: .init(uuid: sender), sequence: UInt64(sequence),
                    revision: UInt64(revision), preview: preview, mediaCount: row.mediaCount, createdAt: date)
            } else { message = nil }
            result[room] = .snapshot(try .init(roomID: room, ownerEpoch: UInt64(row.ownerEpoch),
                membershipRevision: UInt64(row.joinedRevision), head: UInt64(row.head), latest: message))
        }
        return result
    }
}

private struct LatestVisibleRow: Decodable {
    let roomID: UUID, ownerEpoch: Int64, joinedRevision: Int64, head: Int64
    let messageID: UUID?, senderUserID: UUID?, messageSequence: Int64?, messageRevision: Int64?
    let preview: String?, createdAt: Date?, mediaCount: Int
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", ownerEpoch = "owner_epoch", joinedRevision = "joined_revision", head
        case messageID = "message_id", senderUserID = "sender_user_id", messageSequence = "message_sequence"
        case messageRevision = "message_revision", preview, createdAt = "created_at", mediaCount = "media_count"
    }
}
