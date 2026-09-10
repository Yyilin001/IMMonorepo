import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 转发消息的对外处理能力。
public protocol V2ForwardMessagesHandling: Sendable {
    /// 执行一次可能包含多个目标房间的转发。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - command: 转发命令。
    /// - Returns: 与源消息和目标房间组合对应的结果列表。
    /// - Throws: 归属不匹配、授权不足或持久化失败时抛出。
    func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult]
}

/// 转发消息服务。
///
/// 多目标转发刻意被设计为一串相互独立的持久化「源消息-目标房间」对：
/// 某个目标不可用不会丢弃已经成功的目标；持久化的目标客户端消息标识使每个组合都能在
/// 操作记录与常规消息接受事务之间发生崩溃时安全重试。
public struct V2ForwardMessagesService: V2OwnerValidatedForwardMessagesHandling {
    private var ownerRoutes: [RoomID: V2RoomShardRoute]?
    private let database: any Database
    private let writeStore: any V2OwnerValidatedForwardMessageWriteStore
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let acceptanceIDs: V2AcceptanceIDFactory
    private let maximumTargetConcurrency: Int
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    /// 组合数据库、写存储与转发参数。
    ///
    /// - Parameters:
    ///   - database: 执行来源读取与操作记录的数据库。
    ///   - writeStore: 目标房间的写入存储。
    ///   - capacityProfile: 本次使用的容量档位。
    ///   - limits: 消息命令限制。
    ///   - acceptanceIDs: 接受标识生成器。
    ///   - maximumTargetConcurrency: 目标房间并发上限，需大于零，默认 4。
    ///   - makeUUID: 客户端消息标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 并发上限非正时直接失败，避免出现无界并发。
    public init(database: any Database, writeStore: any V2OwnerValidatedForwardMessageWriteStore, capacityProfile: V2CapacityProfile, limits: V2MessageCommandLimits, acceptanceIDs: V2AcceptanceIDFactory = .init(), maximumTargetConcurrency: Int = 4, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init) {
        precondition(maximumTargetConcurrency > 0)
        self.database = database; self.writeStore = writeStore; self.capacityProfile = capacityProfile; self.limits = limits; self.acceptanceIDs = acceptanceIDs; self.maximumTargetConcurrency = maximumTargetConcurrency; self.makeUUID = makeUUID; self.now = now
    }

    /// 按已校验的房间归属执行转发。
    ///
    /// 涉及的全部房间都必须出现在归属集合中，否则按归属变更处理；
    /// 归属集合会被裁剪为本次命令涉及的范围后再执行转发。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - command: 转发命令。
    ///   - ownerRoutes: 本次涉及房间的已选定归属。
    /// - Returns: 转发结果列表。
    /// - Throws: 任一房间缺少归属时抛出 ``V2RoomOwnerFenceError/ownerChanged``。
    public func forwardOwnerValidated(actorUserID: UserID, command: V2ForwardMessagesCommand,
        ownerRoutes: [RoomID: V2RoomShardRoute]) async throws -> [V2ForwardMessageResult] {
        let rooms = Set(command.sources.map(\.roomID) + command.targetRoomIDs)
        guard rooms.allSatisfy({ ownerRoutes[$0] != nil }) else { throw V2RoomOwnerFenceError.ownerChanged }
        var scoped = self
        scoped.ownerRoutes = ownerRoutes.filter { rooms.contains($0.key) }
        return try await scoped.forward(actorUserID: actorUserID, command: command)
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
    private func requireOwners(_ rooms: [RoomID], readOnly: Bool = false, sql: any SQLDatabase) async throws {
        guard let ownerRoutes else { return }
        var routes: [UUID: V2RoomShardRoute] = [:]
        for room in rooms {
            guard let id = room.uuidValue, let route = ownerRoutes[room] else { throw V2RoomOwnerFenceError.ownerChanged }
            routes[id] = route
        }
        try await v2RequireForwardOwners(routes, readOnly: readOnly, sql: sql)
    }

    /// 执行一次转发。
    ///
    /// 流程为：先读取既有操作结果以支持幂等重放，再读取源消息内容，
    /// 然后按目标房间并发处理并汇总结果。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - command: 转发命令。
    /// - Returns: 与源消息和目标房间组合对应的结果列表。
    /// - Throws: 源消息不可用、权限不足或持久化失败时抛出。
    public func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        let priorResults = try await replayedResults(
            actor: actorUserID,
            operation: command.operationID,
            sources: command.sources,
            targets: command.targetRoomIDs
        )
        let sources = try await readSources(
            references: command.sources,
            actorUserID: actorUserID
        )
        let targetCount = command.targetRoomIDs.count
        var ordered = Array<V2ForwardMessageResult?>(
            repeating: nil,
            count: command.sourceMessageIDs.count * targetCount
        )

        try await withThrowingTaskGroup(
            of: ForwardTargetResults.self,
            returning: Void.self
        ) { group in
            var nextTargetIndex = 0
            let initialCount = min(maximumTargetConcurrency, targetCount)
            for _ in 0..<initialCount {
                let index = nextTargetIndex
                nextTargetIndex += 1
                let target = command.targetRoomIDs[index]
                group.addTask {
                    try await forward(
                        actorUserID: actorUserID,
                        operationID: command.operationID,
                        target: target,
                        targetIndex: index,
                        sources: sources,
                        priorResults: priorResults
                    )
                }
            }
            while let targetResults = try await group.next() {
                for (sourceIndex, result) in targetResults.results.enumerated() {
                    ordered[(sourceIndex * targetCount) + targetResults.targetIndex] = result
                }
                if nextTargetIndex < targetCount {
                    let index = nextTargetIndex
                    nextTargetIndex += 1
                    let target = command.targetRoomIDs[index]
                    group.addTask {
                        try await forward(
                            actorUserID: actorUserID,
                            operationID: command.operationID,
                            target: target,
                            targetIndex: index,
                            sources: sources,
                            priorResults: priorResults
                        )
                    }
                }
            }
        }
        guard ordered.allSatisfy({ $0 != nil }) else {
            throw V2ForwardStoreError.corrupt
        }
        return ordered.compactMap { $0 }
    }

    private func forward(
        actorUserID: UserID,
        operationID: MessageForwardOperationID,
        target: RoomID,
        targetIndex: Int,
        sources: [ForwardSource],
        priorResults: [ForwardPairKey: V2ForwardMessageResult]
    ) async throws -> ForwardTargetResults {
        var results: [V2ForwardMessageResult] = []
        results.reserveCapacity(sources.count)
        for source in sources {
            try Task.checkCancellation()
            if let replayed = priorResults[.init(source: source.messageID, target: target)] {
                results.append(replayed)
                continue
            }
            switch source.outcome {
            case .unavailable(let errorCode):
                results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: errorCode))
            case .content(let content):
                do {
                    let clientID = try await clientMessageID(actor: actorUserID, operation: operationID, source: source.messageID, target: target, sourceRoomID: source.reference.roomID, sourceRevision: content.sourceRevision)
                    let request = try V2SendMessageCommand(roomID: target, senderUserID: actorUserID, clientMessageID: clientID, text: content.text, media: content.media, entities: content.entities, forwardedFrom: .init(messageID: source.messageID, senderUserID: content.senderUserID, sourceRevision: content.sourceRevision), limits: limits)
                    let acceptedAt = now()
                    guard v2PostgresTimestampCanEncode(acceptedAt) else { throw V2ForwardStoreError.corrupt }
                    let prepared = V2RoomWriteRequest(command: request, capacityProfile: capacityProfile,
                        identifiers: try acceptanceIDs.make(at: acceptedAt), now: acceptedAt)
                    let outcome: V2SendMessageOutcome
                    if let ownerRoutes {
                        guard let sourceRoute = ownerRoutes[source.reference.roomID], let targetRoute = ownerRoutes[target]
                        else { throw V2RoomOwnerFenceError.ownerChanged }
                        outcome = try await writeStore.acceptForwardOwnerValidated(request: prepared,
                            sourceRoomID: source.reference.roomID, sourceOwnerRoute: sourceRoute, targetOwnerRoute: targetRoute)
                    } else {
                        outcome = try await writeStore.accept(command: request, capacityProfile: capacityProfile,
                            identifiers: prepared.identifiers, now: acceptedAt)
                    }
                    switch outcome {
                    case .accepted, .idempotent:
                        guard let message = outcome.acceptanceReceipt else { throw V2ForwardStoreError.corrupt }
                        try await markResult(actor: actorUserID, operation: operationID, source: source.messageID, target: target, sourceRoomID: source.reference.roomID, message: message.messageID)
                        results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: message.messageID, roomSequence: message.roomSequence, errorCode: nil))
                    case .idempotencyConflict: results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "IDEMPOTENCY_CONFLICT"))
                    case .denied: results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "DIRECT_MESSAGE_RESTRICTED"))
                    case .rateLimited: results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "RATE_LIMITED"))
                    case .unavailable: results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "UNAVAILABLE"))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: forwardErrorCode(error)))
                }
            }
        }
        return .init(targetIndex: targetIndex, results: results)
    }

    private func readSources(
        references: [V2ForwardMessageReference],
        actorUserID: UserID
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
                    try await requireOwners(references.map(\.roomID), readOnly: true, sql: scopedSQL)
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

    private func clientMessageID(actor: UserID, operation: MessageForwardOperationID, source: MessageID, target: RoomID, sourceRoomID: RoomID, sourceRevision: V2MessageRevision) async throws -> ClientMessageID {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase, let actor = UUID(uuidString: actor.rawValue), let operation = UUID(uuidString: operation.rawValue), let source = UUID(uuidString: source.rawValue), let target = UUID(uuidString: target.rawValue), let sourceRoom = UUID(uuidString: sourceRoomID.rawValue) else { throw V2ForwardStoreError.corrupt }
            // Two replicas may retry the same pair concurrently. Serialize
            // the lookup/create boundary so both receive the same durable
            // client ID instead of leaking a uniqueness error as UNAVAILABLE.
            let lockKey = "v2-forward-pair:\(actor):\(operation):\(source):\(target)"
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            try await requireOwners([.init(uuid: sourceRoom), .init(uuid: target)], sql: sql)
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
    private func replayedResults(
        actor: UserID,
        operation: MessageForwardOperationID,
        sources: [V2ForwardMessageReference],
        targets: [RoomID]
    ) async throws -> [ForwardPairKey: V2ForwardMessageResult] {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let actorID = UUID(uuidString: actor.rawValue),
                  let operationID = UUID(uuidString: operation.rawValue)
            else { throw V2ForwardStoreError.corrupt }
            try await requireOwners(sources.map(\.roomID) + targets, sql: sql)
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

    private func markResult(actor: UserID, operation: MessageForwardOperationID, source: MessageID, target: RoomID, sourceRoomID: RoomID, message: MessageID) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardStoreError.corrupt }
            try await requireOwners([sourceRoomID, target], sql: sql)
            guard let actor = UUID(uuidString: actor.rawValue), let operation = UUID(uuidString: operation.rawValue), let source = UUID(uuidString: source.rawValue), let target = UUID(uuidString: target.rawValue), let message = UUID(uuidString: message.rawValue) else { throw V2ForwardStoreError.corrupt }
            guard let row = try await sql.raw("UPDATE im_v2.message_forward_operations SET result_message_id = \(bind: message) WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) AND source_message_id = \(bind: source) AND target_room_id = \(bind: target) AND (result_message_id IS NULL OR result_message_id = \(bind: message)) RETURNING result_message_id").first(decoding: ForwardMarkedResultRow.self), row.resultMessageID == message else {
                throw V2ForwardStoreError.corrupt
            }
        }
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
private struct ForwardSource: Sendable {
    let reference: V2ForwardMessageReference
    var messageID: MessageID { reference.messageID }
    let outcome: ForwardSourceOutcome
}
private enum ForwardSourceOutcome: Sendable {
    case content(ForwardSourceContent)
    case unavailable(String)
}
private struct ForwardSourceContent: Sendable { let senderUserID: UserID; let sourceRevision: V2MessageRevision; let text: String; let media: [V2MediaReference]; let entities: [V2MessageEntity] }
private struct ForwardTargetResults: Sendable { let targetIndex: Int; let results: [V2ForwardMessageResult] }
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
private struct ForwardPairKey: Hashable, Sendable {
    let source: MessageID
    let target: RoomID
}
private struct ForwardMarkedResultRow: Decodable {
    let resultMessageID: UUID
    enum CodingKeys: String, CodingKey { case resultMessageID = "result_message_id" }
}
private enum V2ForwardStoreError: Error { case notVisible, corrupt, sourceRevisionConflict }
private func forwardErrorCode(_ error: Error) -> String {
    switch error {
    case V2ForwardStoreError.sourceRevisionConflict: "IDEMPOTENCY_CONFLICT"
    case V2ForwardStoreError.notVisible: "NOT_FOUND"
    case V2RoomWriteStoreError.actorNotEligible: "FORBIDDEN"
    case V2RoomWriteStoreError.roomNotFound: "NOT_FOUND"
    case V2MediaStoreError.mediaUnavailable, V2MediaStoreError.mediaExpired,
         V2MediaStoreError.invalidStateTransition: "MEDIA_UNAVAILABLE"
    default: "UNAVAILABLE"
    }
}
