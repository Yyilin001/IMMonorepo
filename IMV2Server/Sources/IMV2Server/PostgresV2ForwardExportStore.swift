import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 转发导出的持久化实现。
///
/// 导出的提交即源端授权的线性化点。该原语不执行任何远程调用，
/// 也绝不把消息报告为目标侧已接受。
public struct PostgresV2ForwardExportStore: Sendable {
    private let database: any Database
    private let maximumExportsPerRoom: Int
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库、单房间导出上限与标识生成方式。
    ///
    /// - Parameters:
    ///   - database: 存放房间、消息、媒体与导出记录的数据库。
    ///   - maximumExportsPerRoom: 单房间允许的未完成导出上限，需大于零，默认 1024。
    ///   - makeUUID: 导出标识生成方式。
    ///
    /// 上限非正时直接失败，避免出现无界导出队列。
    public init(database: any Database, maximumExportsPerRoom: Int = 1_024, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        precondition(maximumExportsPerRoom > 0)
        self.database = database
        self.maximumExportsPerRoom = maximumExportsPerRoom
        self.makeUUID = makeUUID
    }

    /// 准备一次转发导出，或在重试时返回既有导出。
    ///
    /// 加锁顺序为一个用户对互斥锁加一个源房间锁，绝不锁定远端目标房间。
    /// 已存在同一用户、操作、源消息与目标房间的导出时逐字段复核其不可变绑定，
    /// 包括源房间与源修订；不匹配即判定幂等冲突，而不会改写信封或重新授予。
    /// 新导出会校验源房间归属、消息可见性与未撤回状态、修订一致、富文本合法、
    /// 媒体引用全部未撤销且可用未过期，并以 UUID 顺序锁定消息引用的全部媒体。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - operationID: 转发操作标识。
    ///   - source: 源消息引用。
    ///   - sourceRoute: 源房间的已选定归属。
    ///   - targetRoomID: 目标房间。
    ///   - targetRoute: 目标房间的已选定归属。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 可投递的转发导出。
    /// - Throws: 标识非法时抛出 ``V2ForwardExportError/invalidRequest``；
    ///   源房间或消息不可用、修订已变化时抛出
    ///   ``V2ForwardExportError/sourceUnavailable`` 或 ``V2ForwardExportError/sourceChanged``；
    ///   归属不符时抛出 ``V2ForwardExportError/ownerChanged``；媒体不可用或存在撤销引用时抛出
    ///   ``V2ForwardExportError/mediaUnavailable``；已有导出绑定不一致时抛出
    ///   ``V2ForwardExportError/idempotencyConflict``；队列已满或持久化状态异常时抛出
    ///   ``V2ForwardExportError/capacityExceeded`` 或 ``V2ForwardExportError/corruptPersistenceState``。
    public func prepare(
        actorUserID: UserID,
        operationID: MessageForwardOperationID,
        source: V2ForwardMessageReference,
        sourceRoute: V2RoomShardRoute,
        targetRoomID: RoomID,
        targetRoute: V2RoomShardRoute,
        now: Date
    ) async throws -> V2ForwardExport {
        let result = try await prepareResult(actorUserID: actorUserID, operationID: operationID, source: source,
            sourceRoute: sourceRoute, targetRoomID: targetRoomID, targetRoute: targetRoute, now: now, replayTerminal: false)
        guard case .export(let export) = result else { throw V2ForwardExportError.corruptPersistenceState }
        return export
    }

    /// Read the original envelope or terminal receipt in one database snapshot.
    /// A receipt committed after the service preflight must not require content.
    func prepareForDelivery(
        actorUserID: UserID, operationID: MessageForwardOperationID, source: V2ForwardMessageReference,
        sourceRoute: V2RoomShardRoute, targetRoomID: RoomID, targetRoute: V2RoomShardRoute, now: Date
    ) async throws -> V2ForwardExportPreparation {
        try await prepareResult(actorUserID: actorUserID, operationID: operationID, source: source,
            sourceRoute: sourceRoute, targetRoomID: targetRoomID, targetRoute: targetRoute, now: now, replayTerminal: true)
    }

    private func prepareResult(
        actorUserID: UserID, operationID: MessageForwardOperationID, source: V2ForwardMessageReference,
        sourceRoute: V2RoomShardRoute, targetRoomID: RoomID, targetRoute: V2RoomShardRoute, now: Date,
        replayTerminal: Bool
    ) async throws -> V2ForwardExportPreparation {
        guard let actor = actorUserID.uuidValue, let operation = operationID.uuidValue,
              let sourceRoom = source.roomID.uuidValue, let message = source.messageID.uuidValue,
              let target = targetRoomID.uuidValue
        else { throw V2ForwardExportError.invalidRequest }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
            // One pair mutex, then one source room. Never lock a remote target.
            // Competing retries with a different claimed source room cannot
            // create two copies or bypass the original source binding.
            let key = "v2-forward-export:\(actor):\(operation):\(message):\(target)"
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
            if let prior = try await sql.raw("""
                SELECT export.source_room_id, export.source_content_revision,
                       CASE WHEN \(bind: replayTerminal) AND receipt.export_id IS NOT NULL
                            THEN NULL ELSE export.payload END AS payload,
                       export.payload_digest AS export_digest,
                       receipt.payload_digest, receipt.state, receipt.result_message_id,
                       receipt.result_room_sequence, receipt.error_code
                FROM im_v2.message_forward_exports AS export
                LEFT JOIN im_v2.message_forward_export_receipts AS receipt USING (export_id)
                WHERE export.actor_user_id = \(bind: actor) AND export.operation_id = \(bind: operation)
                  AND export.source_message_id = \(bind: message) AND export.target_room_id = \(bind: target)
                """).first(decoding: ExportPreparationRow.self) {
                guard prior.sourceRoomID == sourceRoom, prior.sourceRevision == source.revision.signedValue
                else { throw V2ForwardExportError.idempotencyConflict }
                if replayTerminal, let receipt = prior.receipt {
                    guard prior.digest.count == 32, prior.digest == receipt.digest
                    else { throw V2ForwardExportError.corruptPersistenceState }
                    return .terminal(try receipt.outcome)
                }
                guard let payload = prior.payload else {
                    guard let receipt = prior.receipt, prior.digest.count == 32, prior.digest == receipt.digest
                    else { throw V2ForwardExportError.corruptPersistenceState }
                    _ = try receipt.outcome
                    throw V2ForwardExportError.payloadCompacted
                }
                let export = try V2ForwardExport(payload: payload, digest: prior.digest)
                guard export.intent.actorUserID == actor, export.intent.operationID == operation,
                      export.intent.sourceMessageID == message, export.intent.targetRoomID == target,
                      export.intent.sourceRoomID == sourceRoom,
                      export.intent.sourceRevision == source.revision.signedValue
                else { throw V2ForwardExportError.idempotencyConflict }
                // Original routing epochs are immutable evidence. A future
                // migration delivery protocol must carry them, never regrant
                // from a changed source or rewrite this envelope on retry.
                return .export(export)
            }
            guard let room = try await sql.raw("""
                SELECT room_shard_id, owner_epoch FROM im_v2.rooms
                WHERE room_id = \(bind: sourceRoom) FOR UPDATE
                """).first(decoding: ExportRoomRow.self)
            else { throw V2ForwardExportError.sourceUnavailable }
            guard room.shardID == sourceRoute.shardID, room.epoch == sourceRoute.epoch
            else { throw V2ForwardExportError.ownerChanged }
            guard let content = try await sql.raw("""
                SELECT message.sender_user_id, message.content_revision, message.text_body,
                       message.rich_entities::text AS entities_json
                FROM im_v2.messages AS message
                JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                WHERE message.message_id = \(bind: message) AND message.room_id = \(bind: sourceRoom)
                  AND message.withdrawn_at IS NULL AND (\(v2ForwardSourceVisibility(actorID: actor)))
                FOR SHARE OF message
                """).first(decoding: ExportContentRow.self)
            else { throw V2ForwardExportError.sourceUnavailable }
            guard content.revision == source.revision.signedValue else { throw V2ForwardExportError.sourceChanged }
            let entities = try JSONDecoder().decode([V2MessageEntity].self, from: Data(content.entitiesJSON.utf8))
            try V2RichMessageContent.validate(text: content.text, entities: entities)
            // Lock every reference, including revoked ones. Filtering revoked
            // rows in SQL would silently turn an attachment message into text.
            let references = try await sql.raw("""
                SELECT media_id, ordinal, revoked_at FROM im_v2.message_media_references
                WHERE message_id = \(bind: message) ORDER BY media_id FOR SHARE
                """).all(decoding: ExportReferenceRow.self)
            guard references.count <= V2MessageCommandLimits.maxMediaAttachments,
                  references.allSatisfy({ $0.revokedAt == nil })
            else { throw V2ForwardExportError.mediaUnavailable }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardExportError.corruptPersistenceState }
            let currentTime = try V2PostgresTimestamp(date: now)
            var mediaByID: [UUID: V2ForwardExportMedia] = [:]
            // All media users follow UUID order. Retention uses SKIP LOCKED;
            // it either expires first (and we reject) or sees this export pin
            // on its next pass after the export transaction commits.
            for reference in references {
                guard let media = try await sql.raw("""
                    SELECT media_id, upload_session_id, content_type, byte_count, state, expires_at
                    FROM im_v2.media_objects WHERE media_id = \(bind: reference.mediaID) FOR UPDATE
                    """).first(decoding: ExportMediaRow.self),
                      media.state == "available", media.expiresAt.microseconds > currentTime.microseconds,
                      media.byteCount > 0
                else { throw V2ForwardExportError.mediaUnavailable }
                mediaByID[media.mediaID] = .init(mediaID: media.mediaID, uploadSessionID: media.uploadSessionID,
                                               contentType: media.contentType, byteCount: media.byteCount)
            }
            let orderedReferences = references.sorted { $0.ordinal < $1.ordinal }
            guard Set(orderedReferences.map(\.ordinal)).count == orderedReferences.count,
                  orderedReferences.allSatisfy({ $0.ordinal >= 0 })
            else { throw V2ForwardExportError.corruptPersistenceState }
            let media = try orderedReferences.map { reference in
                guard let item = mediaByID[reference.mediaID] else { throw V2ForwardExportError.corruptPersistenceState }
                return item
            }
            // Only outstanding delivery consumes a queue slot. A terminal
            // receipt is immutable; replay never reserves or repins it again.
            let slots = try await sql.raw("""
                SELECT export.export_id FROM im_v2.message_forward_exports AS export
                WHERE export.source_room_id = \(bind: sourceRoom)
                  AND NOT EXISTS (SELECT 1 FROM im_v2.message_forward_export_receipts AS receipt
                                  WHERE receipt.export_id = export.export_id)
                LIMIT \(bind: maximumExportsPerRoom)
                """).all(decoding: ExportIDRow.self)
            guard slots.count < maximumExportsPerRoom else { throw V2ForwardExportError.capacityExceeded }
            let export = try V2ForwardExport(intent: .init(
                version: 1, exportID: makeUUID(), actorUserID: actor, operationID: operation,
                sourceRoomID: sourceRoom, sourceMessageID: message, sourceRevision: content.revision,
                sourceSenderUserID: content.senderID, sourceShardID: sourceRoute.shardID, sourceEpoch: sourceRoute.epoch,
                targetRoomID: target, targetClientMessageID: makeUUID(),
                targetShardID: targetRoute.shardID, targetEpoch: targetRoute.epoch,
                text: content.text, entities: entities, media: media
            ))
            let mediaJSON = String(decoding: try JSONEncoder().encode(media.map(\.mediaID)), as: UTF8.self)
            try await sql.raw("""
                INSERT INTO im_v2.message_forward_exports
                    (export_id, actor_user_id, operation_id, source_room_id, source_message_id,
                     source_content_revision, source_shard_id, source_epoch, target_room_id,
                     target_client_message_id, target_shard_id, target_epoch,
                     payload, payload_digest, media_ids, created_at)
                VALUES (\(bind: export.intent.exportID), \(bind: actor), \(bind: operation),
                        \(bind: sourceRoom), \(bind: message), \(bind: content.revision),
                        \(bind: sourceRoute.shardID), \(bind: sourceRoute.epoch), \(bind: target),
                        \(bind: export.intent.targetClientMessageID), \(bind: targetRoute.shardID), \(bind: targetRoute.epoch),
                        \(bind: export.payload), \(bind: export.digest),
                        ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(\(bind: mediaJSON)::jsonb)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.message_forward_delivery_jobs (export_id, state, next_attempt_at, created_at)
                VALUES (\(bind: export.intent.exportID), 'pending', \(bind: now), \(bind: now))
                """).run()
            return .export(export)
        }
    }
}

enum V2ForwardExportPreparation: Sendable {
    case export(V2ForwardExport)
    case terminal(V2ForwardImportOutcome)
}

private struct ExportPreparationRow: Decodable {
    let sourceRoomID: UUID
    let sourceRevision: Int64
    let payload: Data?
    let digest: Data
    let receipt: V2ForwardReceiptRow?
    enum CodingKeys: String, CodingKey {
        case sourceRoomID = "source_room_id", sourceRevision = "source_content_revision", payload
        case digest = "export_digest", state
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceRoomID = try values.decode(UUID.self, forKey: .sourceRoomID)
        sourceRevision = try values.decode(Int64.self, forKey: .sourceRevision)
        payload = try values.decodeIfPresent(Data.self, forKey: .payload)
        digest = try values.decode(Data.self, forKey: .digest)
        receipt = try values.decodeIfPresent(String.self, forKey: .state) == nil ? nil : V2ForwardReceiptRow(from: decoder)
    }
}
private struct ExportIDRow: Decodable {
    let exportID: UUID
    enum CodingKeys: String, CodingKey { case exportID = "export_id" }
}
private struct ExportRoomRow: Decodable {
    let shardID: String; let epoch: Int64
    enum CodingKeys: String, CodingKey { case shardID = "room_shard_id"; case epoch = "owner_epoch" }
}
private struct ExportContentRow: Decodable {
    let senderID: UUID; let revision: Int64; let text: String; let entitiesJSON: String
    enum CodingKeys: String, CodingKey {
        case senderID = "sender_user_id"; case revision = "content_revision"
        case text = "text_body"; case entitiesJSON = "entities_json"
    }
}
private struct ExportReferenceRow: Decodable {
    let mediaID: UUID; let ordinal: Int; let revokedAt: Date?
    enum CodingKeys: String, CodingKey { case mediaID = "media_id"; case ordinal; case revokedAt = "revoked_at" }
}
private struct ExportMediaRow: Decodable {
    let mediaID: UUID; let uploadSessionID: UUID; let contentType: String
    let byteCount: Int64; let state: String; let expiresAt: V2PostgresTimestamp
    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"; case uploadSessionID = "upload_session_id"; case contentType = "content_type"
        case byteCount = "byte_count"; case state; case expiresAt = "expires_at"
    }
}
