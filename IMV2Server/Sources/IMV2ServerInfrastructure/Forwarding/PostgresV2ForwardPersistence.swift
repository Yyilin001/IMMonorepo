import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

package struct PostgresV2ForwardPersistence: V2ForwardPersistence {
    let database: any Database
    let makeUUID: @Sendable () -> UUID
    let now: @Sendable () -> Date

    init(database: any Database, makeUUID: @escaping @Sendable () -> UUID,
         now: @escaping @Sendable () -> Date) {
        self.database = database
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 在事务内校验本次涉及房间的归属。
    ///
    /// 未携带归属集合时为空操作，供非路由调用方复用同一实现。
    ///
    /// - Parameters:
    ///   - rooms: 本次涉及的房间。
    ///   - readOnly: 是否只加共享锁。
    ///   - sql: 当前事务使用的数据库连接。
    /// - Throws: 缺少归属或归属已变更时抛出 ``V2RoomOwnerFenceError/ownerChanged``。
    private func requireOwners(_ rooms: [RoomID], ownerRoutes: [RoomID: V2RoomShardRoute]?,
                               readOnly: Bool = false, sql: any SQLDatabase) async throws {
        guard let ownerRoutes else { return }
        var routes: [UUID: V2RoomShardRoute] = [:]
        for room in rooms {
            guard let id = room.uuidValue, let route = ownerRoutes[room] else { throw V2RoomOwnerFenceError.ownerChanged }
            routes[id] = route
        }
        try await v2RequireForwardOwners(routes, readOnly: readOnly, sql: sql)
    }

    package func readSources(
        references: [V2ForwardMessageReference],
        actorUserID: UserID, ownerRoutes: [RoomID: V2RoomShardRoute]?
    ) async throws -> [ForwardSource] {
        guard let sql = database as? any SQLDatabase,
              let actor = UUID(uuidString: actorUserID.rawValue)
        else { throw V2ForwardStoreError.corrupt }
        let encodedInputs = String(
            decoding: try JSONEncoder().encode(references.enumerated().map {
                ForwardSourceLookupInput(ordinal: $0.offset, messageID: $0.element.messageID.rawValue, roomID: $0.element.roomID.rawValue)
            }),
            as: UTF8.self
        )
        @Sendable func query(_ sql: any SQLDatabase) async throws -> [ForwardSourceBatchRow] {
            return try await sql.raw("""
                WITH requested AS (
                    SELECT ordinal, message_id, room_id
                    FROM jsonb_to_recordset(\(bind: encodedInputs)::jsonb)
                        AS input(ordinal integer, message_id uuid, room_id uuid)
                )
                SELECT requested.ordinal, message.sender_user_id, message.text_body, message.content_revision,
                       message.rich_entities::text AS entities_json,
                       COALESCE(
                           jsonb_agg(media.media_id ORDER BY media.ordinal)
                               FILTER (WHERE media.media_id IS NOT NULL AND media.revoked_at IS NULL),
                           '[]'::jsonb
                       )::text AS media_json
                FROM requested
                LEFT JOIN (
                    im_v2.messages AS message
                    INNER JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                ) ON message.message_id = requested.message_id
                   AND message.room_id = requested.room_id
                   AND message.withdrawn_at IS NULL
                   AND NOT EXISTS (
                       SELECT 1 FROM im_v2.message_media_references AS revoked_reference
                       WHERE revoked_reference.message_id = message.message_id
                         AND revoked_reference.revoked_at IS NOT NULL
                   )
                   AND (\(v2ForwardSourceVisibility(actorID: actor)))
                LEFT JOIN im_v2.message_media_references AS media
                  ON media.message_id = message.message_id
                GROUP BY requested.ordinal, message.sender_user_id,
                         message.text_body, message.rich_entities, message.content_revision
                ORDER BY requested.ordinal
                """).all(decoding: ForwardSourceBatchRow.self)
        }
        let rows: [ForwardSourceBatchRow]
        do {
            if ownerRoutes != nil {
                rows = try await database.transaction { transaction in
                    guard let scopedSQL = transaction as? any SQLDatabase else { throw V2ForwardStoreError.corrupt }
                    try await requireOwners(references.map(\.roomID), ownerRoutes: ownerRoutes, readOnly: true, sql: scopedSQL)
                    return try await query(scopedSQL)
                }
            } else { rows = try await query(sql) }

        } catch V2RoomOwnerFenceError.ownerChanged {
            throw V2RoomOwnerFenceError.ownerChanged
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return references.map { .init(reference: $0, outcome: .unavailable("UNAVAILABLE")) }
        }
        guard rows.count == references.count else {
            return references.map { .init(reference: $0, outcome: .unavailable("UNAVAILABLE")) }
        }
        return rows.enumerated().map { expectedOrdinal, row in
            let reference = references[expectedOrdinal]
            guard row.ordinal == expectedOrdinal else {
                return .init(reference: reference, outcome: .unavailable("UNAVAILABLE"))
            }
            guard let senderUserID = row.senderUserID,
                  let contentRevision = row.contentRevision, contentRevision > 0,
                  let text = row.text,
                  let entitiesJSON = row.entitiesJSON
            else {
                return .init(reference: reference, outcome: .unavailable("NOT_FOUND"))
            }
            guard contentRevision == reference.revision.signedValue else {
                return .init(reference: reference, outcome: .unavailable("SOURCE_CHANGED"))
            }
            do {
                let entities = try JSONDecoder().decode([V2MessageEntity].self, from: Data(entitiesJSON.utf8))
                let mediaIDs = try JSONDecoder().decode([UUID].self, from: Data(row.mediaJSON.utf8))
                let content = try ForwardSourceContent(
                    senderUserID: .init(senderUserID.uuidString),
                    sourceRevision: .init(UInt64(contentRevision)),
                    text: text,
                    media: mediaIDs.map { try .init(mediaID: .init($0.uuidString)) },
                    entities: entities
                )
                return .init(reference: reference, outcome: .content(content))
            } catch {
                return .init(reference: reference, outcome: .unavailable("UNAVAILABLE"))
            }
        }
    }

    package func clientMessageID(actor: UserID, operation: MessageForwardOperationID, source: MessageID, target: RoomID, sourceRoomID: RoomID, sourceRevision: V2MessageRevision, ownerRoutes: [RoomID: V2RoomShardRoute]?) async throws -> ClientMessageID {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase, let actor = UUID(uuidString: actor.rawValue), let operation = UUID(uuidString: operation.rawValue), let source = UUID(uuidString: source.rawValue), let target = UUID(uuidString: target.rawValue), let sourceRoom = UUID(uuidString: sourceRoomID.rawValue) else { throw V2ForwardStoreError.corrupt }
            // 两个副本可能并发重试同一房间对。串行化查找／创建边界，
            // 使两者取得同一个持久客户端 ID，避免把唯一约束错误暴露为 UNAVAILABLE。
            let lockKey = "v2-forward-pair:\(actor):\(operation):\(source):\(target)"
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            try await requireOwners([.init(uuid: sourceRoom), .init(uuid: target)], ownerRoutes: ownerRoutes, sql: sql)
            if let prior = try await sql.raw("SELECT target_client_message_id, source_content_revision, source_room_id FROM im_v2.message_forward_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) AND source_message_id = \(bind: source) AND target_room_id = \(bind: target)").first(decoding: ForwardOperationRow.self) {
                guard prior.sourceContentRevision == sourceRevision.signedValue, prior.sourceRoomID == sourceRoom else {
                    throw V2ForwardStoreError.sourceRevisionConflict
                }
                return try .init(prior.clientMessageID.uuidString)
            }
            let createdAt = now()
            guard v2PostgresTimestampCanEncode(createdAt) else { throw V2ForwardStoreError.corrupt }
            let client = makeUUID()
            try await sql.raw("INSERT INTO im_v2.message_forward_operations (actor_user_id, operation_id, source_message_id, target_room_id, target_client_message_id, source_content_revision, source_room_id, created_at) VALUES (\(bind: actor), \(bind: operation), \(bind: source), \(bind: target), \(bind: client), \(bind: sourceRevision.signedValue), \(bind: sourceRoom), \(bind: createdAt))").run()
            return try .init(client.uuidString)
        }
    }

    /// 读取既有转发结果以支持幂等重放。
    ///
    /// 已成功的组合是不可变的，即使来源消息后来被编辑、撤回或对发起者不可见。
    /// 第二个连接条件还能修复「消息已接受但尚未记录结果消息标识」时的崩溃：
    /// 持久化的目标客户端标识就是接受栅栏。
    ///
    /// - Parameters:
    ///   - actor: 发起转发的用户。
    ///   - operation: 转发操作标识。
    ///   - sources: 源消息引用列表。
    ///   - targets: 目标房间列表。
    /// - Returns: 与源消息和目标房间组合对应的既有结果。
    /// - Throws: 查询失败或记录状态异常时抛出。
    package func replayedResults(
        actor: UserID,
        operation: MessageForwardOperationID,
        sources: [V2ForwardMessageReference],
        targets: [RoomID], ownerRoutes: [RoomID: V2RoomShardRoute]?
    ) async throws -> [ForwardPairKey: V2ForwardMessageResult] {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let actorID = UUID(uuidString: actor.rawValue),
                  let operationID = UUID(uuidString: operation.rawValue)
            else { throw V2ForwardStoreError.corrupt }
            try await requireOwners(sources.map(\.roomID) + targets, ownerRoutes: ownerRoutes, sql: sql)
            let sourceValues = try JSONEncoder().encode(sources.map { $0.messageID.rawValue })
            let targetValues = try JSONEncoder().encode(targets.map(\.rawValue))
            guard let sourceJSON = String(data: sourceValues, encoding: .utf8),
                  let targetJSON = String(data: targetValues, encoding: .utf8)
            else { throw V2ForwardStoreError.corrupt }
            let rows = try await sql.raw("""
                SELECT operation.result_message_id,
                       operation.source_message_id, operation.source_room_id, operation.source_content_revision,
                       operation.target_room_id,
                       COALESCE(result_message.message_id, recovered_message.message_id) AS message_id,
                       COALESCE(result_message.room_id, recovered_message.room_id) AS room_id,
                       COALESCE(result_message.room_sequence, recovered_message.room_sequence) AS room_sequence
                FROM im_v2.message_forward_operations AS operation
                LEFT JOIN im_v2.messages AS result_message
                  ON result_message.message_id = operation.result_message_id
                LEFT JOIN im_v2.messages AS recovered_message
                  ON operation.result_message_id IS NULL
                 AND recovered_message.sender_user_id = operation.actor_user_id
                 AND recovered_message.client_message_id = operation.target_client_message_id
                WHERE operation.actor_user_id = \(bind: actorID)
                  AND operation.operation_id = \(bind: operationID)
                  AND operation.source_message_id IN (
                      SELECT value::uuid
                      FROM jsonb_array_elements_text(\(bind: sourceJSON)::jsonb) AS source(value)
                  )
                  AND operation.target_room_id IN (
                      SELECT value::uuid
                      FROM jsonb_array_elements_text(\(bind: targetJSON)::jsonb) AS target(value)
                  )
                FOR UPDATE OF operation
                """).all(decoding: ForwardReplayRow.self)
            var results: [ForwardPairKey: V2ForwardMessageResult] = [:]
            results.reserveCapacity(rows.count)
            let requested = Dictionary(uniqueKeysWithValues: sources.map { ($0.messageID, $0) })
            for row in rows {
                let source = try MessageID(row.sourceMessageID.uuidString)
                let target = try RoomID(row.targetRoomID.uuidString)
                guard let reference = requested[source],
                      row.sourceRoomID == reference.roomID.uuidValue,
                      row.sourceContentRevision == reference.revision.signedValue else {
                    results[.init(source: source, target: target)] = try .init(sourceMessageID: source, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "IDEMPOTENCY_CONFLICT")
                    continue
                }
                guard let messageID = row.messageID,
                      let roomID = row.roomID,
                      let roomSequence = row.roomSequence,
                      roomID == row.targetRoomID,
                      roomSequence > 0
                else { continue }
                if row.resultMessageID == nil {
                    try await sql.raw("""
                        UPDATE im_v2.message_forward_operations
                        SET result_message_id = \(bind: messageID)
                        WHERE actor_user_id = \(bind: actorID)
                          AND operation_id = \(bind: operationID)
                          AND source_message_id = \(bind: row.sourceMessageID)
                          AND target_room_id = \(bind: row.targetRoomID)
                          AND result_message_id IS NULL
                        """).run()
                }
                results[.init(source: source, target: target)] = try .init(
                    sourceMessageID: source,
                    targetRoomID: target,
                    messageID: .init(messageID.uuidString),
                    roomSequence: UInt64(roomSequence),
                    errorCode: nil
                )
            }
            return results
        }
    }

    package func markResult(actor: UserID, operation: MessageForwardOperationID, source: MessageID, target: RoomID, sourceRoomID: RoomID, message: MessageID, ownerRoutes: [RoomID: V2RoomShardRoute]?) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardStoreError.corrupt }
            try await requireOwners([sourceRoomID, target], ownerRoutes: ownerRoutes, sql: sql)
            guard let actor = UUID(uuidString: actor.rawValue), let operation = UUID(uuidString: operation.rawValue), let source = UUID(uuidString: source.rawValue), let target = UUID(uuidString: target.rawValue), let message = UUID(uuidString: message.rawValue) else { throw V2ForwardStoreError.corrupt }
            guard let row = try await sql.raw("UPDATE im_v2.message_forward_operations SET result_message_id = \(bind: message) WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) AND source_message_id = \(bind: source) AND target_room_id = \(bind: target) AND (result_message_id IS NULL OR result_message_id = \(bind: message)) RETURNING result_message_id").first(decoding: ForwardMarkedResultRow.self), row.resultMessageID == message else {
                throw V2ForwardStoreError.corrupt
            }
        }
    }
}

extension V2ForwardMessagesService {
    public init(database: any Database, writeStore: any V2OwnerValidatedForwardMessageWriteStore,
                capacityProfile: V2CapacityProfile, limits: V2MessageCommandLimits,
                acceptanceIDs: V2AcceptanceIDFactory = .init(), maximumTargetConcurrency: Int = 4,
                makeUUID: @escaping @Sendable () -> UUID = UUID.init,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.init(persistence: PostgresV2ForwardPersistence(database: database, makeUUID: makeUUID, now: now),
                  writeStore: writeStore, capacityProfile: capacityProfile, limits: limits,
                  acceptanceIDs: acceptanceIDs, maximumTargetConcurrency: maximumTargetConcurrency, now: now)
    }
}

private struct ForwardSourceLookupInput: Encodable {
    let ordinal: Int
    let messageID: String
    let roomID: String
    enum CodingKeys: String, CodingKey { case ordinal; case messageID = "message_id", roomID = "room_id" }
}
private struct ForwardSourceBatchRow: Decodable {
    let ordinal: Int
    let senderUserID: UUID?
    let contentRevision: Int64?
    let text: String?
    let entitiesJSON: String?
    let mediaJSON: String
    enum CodingKeys: String, CodingKey {
        case ordinal
        case senderUserID = "sender_user_id"
        case contentRevision = "content_revision"
        case text = "text_body"
        case entitiesJSON = "entities_json"
        case mediaJSON = "media_json"
    }
}
private struct ForwardOperationRow: Decodable { let clientMessageID: UUID; let sourceContentRevision: Int64?; let sourceRoomID: UUID?; enum CodingKeys: String, CodingKey { case clientMessageID = "target_client_message_id", sourceContentRevision = "source_content_revision", sourceRoomID = "source_room_id" } }
private struct ForwardReplayRow: Decodable {
    let resultMessageID: UUID?
    let sourceMessageID: UUID
    let sourceRoomID: UUID?
    let sourceContentRevision: Int64?
    let targetRoomID: UUID
    let messageID: UUID?
    let roomID: UUID?
    let roomSequence: Int64?
    enum CodingKeys: String, CodingKey {
        case resultMessageID = "result_message_id"
        case sourceMessageID = "source_message_id"
        case sourceRoomID = "source_room_id", sourceContentRevision = "source_content_revision"
        case targetRoomID = "target_room_id"
        case messageID = "message_id"
        case roomID = "room_id"
        case roomSequence = "room_sequence"
    }
}
private struct ForwardMarkedResultRow: Decodable {
    let resultMessageID: UUID
    enum CodingKeys: String, CodingKey { case resultMessageID = "result_message_id" }
}
