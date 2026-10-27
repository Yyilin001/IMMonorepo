import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
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
    private var activationScope: V2RoomActivationWriteScope?

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
        self.activationScope = nil
    }

    /// 将新导出和不可变重放都绑定到获准的源房间轮次。
    public func usingActivationToken(_ token: V2RoomActivationToken) throws -> Self {
        var scoped = self
        scoped.activationScope = try .init(tokens: [token])
        return scoped
    }

    /// Original source-side proof precedes current membership. A closure shares the export lock;
    /// an existing export must be reconciled through target authority instead of erased.
    public func recover(_ pair: V2ActorForwardPairWire, action: V2OperationRecoveryRequest.Action) async throws -> V2ForwardImportOutcome? {
        guard let actor=pair.actorUserID.uuidValue, let operation=pair.operationID.uuidValue,
              let message=pair.source.messageID.uuidValue, let target=pair.targetRoomID.uuidValue,
              let sourceRoom=pair.source.roomID.uuidValue else { throw V2ForwardExportError.invalidRequest }
        return try await v2WithPostgresTransactionRetry(database:database,maximumRetryCount:0) { transaction in
            guard let sql=transaction as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
            let key="v2-forward-export:\(actor):\(operation):\(message):\(target)"
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:key),0))").run()
            try await activationScope?.require([sourceRoom],sql:sql)
            if let prior=try await PostgresV2ForwardReceiptStore(database:transaction).terminalStatus(actor:pair.actorUserID,operation:pair.operationID,source:pair.source,target:pair.targetRoomID) { return prior }
            if let existing=try await sql.raw("SELECT source_room_id,source_content_revision FROM im_v2.message_forward_exports WHERE actor_user_id=\(bind:actor) AND operation_id=\(bind:operation) AND source_message_id=\(bind:message) AND target_room_id=\(bind:target)").first(decoding:ForwardRecoverOriginal.self) {
                guard existing.source_room_id==sourceRoom,existing.source_content_revision==pair.source.revision.signedValue else { throw V2ForwardExportError.idempotencyConflict }
                return nil
            }
            guard action == .closeIfAbsent else { return nil }
            try await sql.raw("""
                INSERT INTO im_v2.forward_preparation_rejections(actor_user_id,operation_id,source_message_id,target_room_id,source_room_id,source_content_revision,error_code)
                VALUES(\(bind:actor),\(bind:operation),\(bind:message),\(bind:target),\(bind:sourceRoom),\(bind:pair.source.revision.signedValue),'CLOSED_BEFORE_EXECUTION')
                """).run()
            return .rejected(code:"CLOSED_BEFORE_EXECUTION")
        }
    }

    /// 准备一次转发导出，或在重试时返回既有导出。
    ///
    /// 加锁顺序为一个用户对互斥锁加一个源房间锁，绝不锁定远端目标房间。
    /// 已存在同一用户、操作、源消息与目标房间的导出时逐字段复核其不可变绑定，
    /// 包括源房间与源修订；不匹配即判定幂等冲突，而不会改写信封或重新授予。
    /// 新导出会校验源房间归属、消息可见性与未撤回状态、修订一致、富文本合法、
    /// 媒体引用全部未撤销且可用，并以 UUID 顺序锁定消息引用的全部媒体。
    /// 已绑定的新资源不受首次上传绑定期限限制；旧媒体仍沿用原期限合同。
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

    /// 在同一数据库快照中读取原始信封或终态回执。
    /// 服务预检后才提交的回执不应再要求读取内容。
    public func prepareForDelivery(
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
        if let activationScope {
            let token = try activationScope.token(for: sourceRoom)
            guard token.owner.shardID == sourceRoute.shardID,
                  token.owner.epoch == sourceRoute.epoch else {
                throw V2RoomActorStateError.activationChanged
            }
        }
        return try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            // 先取得一把关系互斥锁，再锁定一个源房间；绝不锁远端目标。
            // 声称来自不同源房间的竞争性重试，不能创建两份副本
            // 或绕过原始源绑定。
            let key = "v2-forward-export:\(actor):\(operation):\(message):\(target)"
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
            try await activationScope?.require([sourceRoom], sql: sql)
            if let prior = try await forwardPreparationRejection(actor: actor, operation: operation, source: source, target: targetRoomID, sql: sql) {
                if replayTerminal { return .terminal(.rejected(code: prior)) }
                throw V2ForwardExportError.sourceUnavailable
            }
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
                // 原始路由纪元是不可变证据。重试不能依据变化后的源事实
                // 重新授权，也不能改写此信封。
                return .export(export)
            }
            do {
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
            // 锁定所有引用，包括已撤销的引用。
            // 若在 SQL 中过滤已撤销记录，带附件的消息会悄然变成纯文本。
            let references = try await sql.raw("""
                SELECT media_id, ordinal, revoked_at FROM im_v2.message_media_references
                WHERE message_id = \(bind: message) ORDER BY media_id FOR SHARE
                """).all(decoding: ExportReferenceRow.self)
            guard references.count <= V2MessageCommandLimits.maxMediaAttachments,
                  references.allSatisfy({ $0.revokedAt == nil })
            else { throw V2ForwardExportError.mediaUnavailable }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardExportError.corruptPersistenceState }
            var mediaByID: [UUID: V2ForwardExportMedia] = [:]
            // 所有媒体使用方都按 UUID 顺序加锁。保留期清理使用 SKIP LOCKED；
            // 要么先将媒体标记为过期并导致此处拒绝，
            // 要么在导出事务提交后的下一轮看到这份导出固定引用。
            for reference in references {
                guard let media = try await sql.raw("""
                    SELECT media_id, upload_session_id, content_type, byte_count, state, expires_at,
                           (SELECT c.display_name FROM im_v2.resource_catalog c WHERE c.media_id=media_objects.media_id) AS display_name,
                           EXISTS(SELECT 1 FROM im_v2.resource_catalog c
                             WHERE c.media_id=media_objects.media_id AND c.home_kind='room'
                               AND c.home_id=\(bind:sourceRoom) AND c.usage_kind='message_attachment') AS bound_resource
                    FROM im_v2.media_objects WHERE media_id = \(bind: reference.mediaID) FOR UPDATE
                    """).first(decoding: ExportMediaRow.self),
                      media.state == "available", media.boundResource, let displayName = media.displayName,
                      media.byteCount > 0
                else { throw V2ForwardExportError.mediaUnavailable }
                mediaByID[media.mediaID] = .init(mediaID: media.mediaID, uploadSessionID: media.uploadSessionID,
                                               contentType: media.contentType, byteCount: media.byteCount,
                                               displayName: try V2ResourceDisplayName(displayName))
            }
            let orderedReferences = references.sorted { $0.ordinal < $1.ordinal }
            guard Set(orderedReferences.map(\.ordinal)).count == orderedReferences.count,
                  orderedReferences.allSatisfy({ $0.ordinal >= 0 })
            else { throw V2ForwardExportError.corruptPersistenceState }
            let media = try orderedReferences.map { reference in
                guard let item = mediaByID[reference.mediaID] else { throw V2ForwardExportError.corruptPersistenceState }
                return item
            }
            // 只有未完成的投递占用队列槽位。终态回执不可变；
            // 重放不会再次预留槽位或固定媒体引用。
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
            } catch {
                guard replayTerminal else { throw error }
                let code: String
                switch error {
                case V2ForwardExportError.sourceUnavailable: code = "NOT_FOUND"
                case V2ForwardExportError.sourceChanged: code = "SOURCE_CHANGED"
                case V2ForwardExportError.mediaUnavailable: code = "MEDIA_UNAVAILABLE"
                case V2ForwardExportError.invalidRequest: code = "INVALID_ARGUMENT"
                default: throw error
                }
                try await sql.raw("""
                    INSERT INTO im_v2.forward_preparation_rejections(actor_user_id,operation_id,source_message_id,target_room_id,source_room_id,source_content_revision,error_code)
                    VALUES(\(bind:actor),\(bind:operation),\(bind:message),\(bind:target),\(bind:sourceRoom),\(bind:source.revision.signedValue),\(bind:code))
                    """).run()
                return .terminal(.rejected(code: code))
            }
        }
    }
}

private struct ForwardRecoverOriginal:Decodable { let source_room_id:UUID;let source_content_revision:Int64 }



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
    let byteCount: Int64; let state: String; let expiresAt: V2PersistenceTimestamp
    let boundResource: Bool
    let displayName: String?
    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"; case uploadSessionID = "upload_session_id"; case contentType = "content_type"
        case byteCount = "byte_count"; case state; case expiresAt = "expires_at"
        case boundResource = "bound_resource"
        case displayName = "display_name"
    }
}
