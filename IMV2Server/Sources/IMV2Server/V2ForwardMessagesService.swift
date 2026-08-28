import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Multi-forward is intentionally a sequence of independently durable pairs.
/// A target may be unavailable without discarding successful targets, while a
/// durable client-message ID makes every pair retry-safe across a crash between
/// the operation row and normal message acceptance transaction.
public struct V2ForwardMessagesService: Sendable {
    private let database: any Database
    private let writeStore: any V2RoomWriteStore
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let acceptanceIDs: V2AcceptanceIDFactory
    private let maximumTargetConcurrency: Int
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(database: any Database, writeStore: any V2RoomWriteStore, capacityProfile: V2CapacityProfile, limits: V2MessageCommandLimits, acceptanceIDs: V2AcceptanceIDFactory = .init(), maximumTargetConcurrency: Int = 4, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init) {
        precondition(maximumTargetConcurrency > 0)
        self.database = database; self.writeStore = writeStore; self.capacityProfile = capacityProfile; self.limits = limits; self.acceptanceIDs = acceptanceIDs; self.maximumTargetConcurrency = maximumTargetConcurrency; self.makeUUID = makeUUID; self.now = now
    }

    public func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        let priorResults = try await replayedResults(
            actor: actorUserID,
            operation: command.operationID,
            sources: command.sourceMessageIDs,
            targets: command.targetRoomIDs
        )
        let sources = try await readSources(
            messageIDs: command.sourceMessageIDs,
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
                results.append(.init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: errorCode))
            case .content(let content):
                do {
                    let clientID = try await clientMessageID(actor: actorUserID, operation: operationID, source: source.messageID, target: target)
                    let request = try V2SendMessageCommand(roomID: target, senderUserID: actorUserID, clientMessageID: clientID, text: content.text, media: content.media, entities: content.entities, forwardedFrom: .init(messageID: source.messageID, senderUserID: content.senderUserID), limits: limits)
                    let acceptedAt = now()
                    let outcome = try await writeStore.accept(
                        command: request,
                        capacityProfile: capacityProfile,
                        identifiers: try acceptanceIDs.make(at: acceptedAt),
                        now: acceptedAt
                    )
                    switch outcome {
                    case .accepted(let message), .idempotent(let message):
                        try await markResult(actor: actorUserID, operation: operationID, source: source.messageID, target: target, message: message.messageID)
                        results.append(.init(sourceMessageID: source.messageID, targetRoomID: target, messageID: message.messageID, roomSequence: message.roomSequence, errorCode: nil))
                    case .idempotencyConflict: results.append(.init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "IDEMPOTENCY_CONFLICT"))
                    case .denied: results.append(.init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "DIRECT_MESSAGE_RESTRICTED"))
                    case .rateLimited: results.append(.init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "RATE_LIMITED"))
                    case .unavailable: results.append(.init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "UNAVAILABLE"))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    results.append(.init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: forwardErrorCode(error)))
                }
            }
        }
        return .init(targetIndex: targetIndex, results: results)
    }

    private func readSources(
        messageIDs: [MessageID],
        actorUserID: UserID
    ) async throws -> [ForwardSource] {
        guard let sql = database as? any SQLDatabase,
              let actor = UUID(uuidString: actorUserID.rawValue)
        else { throw V2ForwardStoreError.corrupt }
        let encodedInputs = String(
            decoding: try JSONEncoder().encode(messageIDs.enumerated().map {
                ForwardSourceLookupInput(ordinal: $0.offset, messageID: $0.element.rawValue)
            }),
            as: UTF8.self
        )
        let rows: [ForwardSourceBatchRow]
        do {
            rows = try await sql.raw("""
                WITH requested AS (
                    SELECT ordinal, message_id
                    FROM jsonb_to_recordset(\(bind: encodedInputs)::jsonb)
                        AS input(ordinal integer, message_id uuid)
                )
                SELECT requested.ordinal, message.sender_user_id, message.text_body,
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
                   AND message.withdrawn_at IS NULL
                   AND EXISTS (
                       SELECT 1 FROM im_v2.room_memberships AS membership
                       WHERE membership.room_id = message.room_id
                         AND membership.user_id = \(bind: actor)
                         AND membership.joined_revision <= room.membership_revision
                         AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision)
                   )
                LEFT JOIN im_v2.message_media_references AS media
                  ON media.message_id = message.message_id
                GROUP BY requested.ordinal, message.sender_user_id,
                         message.text_body, message.rich_entities
                ORDER BY requested.ordinal
                """).all(decoding: ForwardSourceBatchRow.self)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return messageIDs.map { .init(messageID: $0, outcome: .unavailable("UNAVAILABLE")) }
        }
        guard rows.count == messageIDs.count else {
            return messageIDs.map { .init(messageID: $0, outcome: .unavailable("UNAVAILABLE")) }
        }
        return rows.enumerated().map { expectedOrdinal, row in
            let messageID = messageIDs[expectedOrdinal]
            guard row.ordinal == expectedOrdinal else {
                return .init(messageID: messageID, outcome: .unavailable("UNAVAILABLE"))
            }
            guard let senderUserID = row.senderUserID,
                  let text = row.text,
                  let entitiesJSON = row.entitiesJSON
            else {
                return .init(messageID: messageID, outcome: .unavailable("NOT_FOUND"))
            }
            do {
                let entities = try JSONDecoder().decode([V2MessageEntity].self, from: Data(entitiesJSON.utf8))
                let mediaIDs = try JSONDecoder().decode([UUID].self, from: Data(row.mediaJSON.utf8))
                let content = try ForwardSourceContent(
                    senderUserID: .init(senderUserID.uuidString),
                    text: text,
                    media: mediaIDs.map { try .init(mediaID: .init($0.uuidString)) },
                    entities: entities
                )
                return .init(messageID: messageID, outcome: .content(content))
            } catch {
                return .init(messageID: messageID, outcome: .unavailable("UNAVAILABLE"))
            }
        }
    }

    private func clientMessageID(actor: UserID, operation: MessageForwardOperationID, source: MessageID, target: RoomID) async throws -> ClientMessageID {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase, let actor = UUID(uuidString: actor.rawValue), let operation = UUID(uuidString: operation.rawValue), let source = UUID(uuidString: source.rawValue), let target = UUID(uuidString: target.rawValue) else { throw V2ForwardStoreError.corrupt }
            // Two replicas may retry the same pair concurrently. Serialize
            // the lookup/create boundary so both receive the same durable
            // client ID instead of leaking a uniqueness error as UNAVAILABLE.
            let lockKey = "v2-forward-pair:\(actor):\(operation):\(source):\(target)"
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let prior = try await sql.raw("SELECT target_client_message_id FROM im_v2.message_forward_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) AND source_message_id = \(bind: source) AND target_room_id = \(bind: target)").first(decoding: ForwardOperationRow.self) { return try .init(prior.clientMessageID.uuidString) }
            let client = makeUUID()
            try await sql.raw("INSERT INTO im_v2.message_forward_operations (actor_user_id, operation_id, source_message_id, target_room_id, target_client_message_id, created_at) VALUES (\(bind: actor), \(bind: operation), \(bind: source), \(bind: target), \(bind: client), \(bind: now()))").run()
            return try .init(client.uuidString)
        }
    }

    /// A successful pair is immutable even when the source is later edited,
    /// withdrawn, or becomes invisible to the actor. The second join predicate
    /// also repairs a crash after message acceptance but before result_message_id
    /// was recorded: the durable target client ID is the acceptance fence.
    private func replayedResults(
        actor: UserID,
        operation: MessageForwardOperationID,
        sources: [MessageID],
        targets: [RoomID]
    ) async throws -> [ForwardPairKey: V2ForwardMessageResult] {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let actorID = UUID(uuidString: actor.rawValue),
                  let operationID = UUID(uuidString: operation.rawValue)
            else { throw V2ForwardStoreError.corrupt }
            let sourceValues = try JSONEncoder().encode(sources.map(\.rawValue))
            let targetValues = try JSONEncoder().encode(targets.map(\.rawValue))
            guard let sourceJSON = String(data: sourceValues, encoding: .utf8),
                  let targetJSON = String(data: targetValues, encoding: .utf8)
            else { throw V2ForwardStoreError.corrupt }
            let rows = try await sql.raw("""
                SELECT operation.result_message_id,
                       operation.source_message_id,
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
            for row in rows {
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
                let source = try MessageID(row.sourceMessageID.uuidString)
                let target = try RoomID(row.targetRoomID.uuidString)
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

    private func markResult(actor: UserID, operation: MessageForwardOperationID, source: MessageID, target: RoomID, message: MessageID) async throws {
        guard let sql = database as? any SQLDatabase, let actor = UUID(uuidString: actor.rawValue), let operation = UUID(uuidString: operation.rawValue), let source = UUID(uuidString: source.rawValue), let target = UUID(uuidString: target.rawValue), let message = UUID(uuidString: message.rawValue) else { throw V2ForwardStoreError.corrupt }
        guard let row = try await sql.raw("UPDATE im_v2.message_forward_operations SET result_message_id = \(bind: message) WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) AND source_message_id = \(bind: source) AND target_room_id = \(bind: target) AND (result_message_id IS NULL OR result_message_id = \(bind: message)) RETURNING result_message_id").first(decoding: ForwardMarkedResultRow.self), row.resultMessageID == message else {
            throw V2ForwardStoreError.corrupt
        }
    }
}

private struct ForwardSourceLookupInput: Encodable {
    let ordinal: Int
    let messageID: String
    enum CodingKeys: String, CodingKey { case ordinal; case messageID = "message_id" }
}
private struct ForwardSourceBatchRow: Decodable {
    let ordinal: Int
    let senderUserID: UUID?
    let text: String?
    let entitiesJSON: String?
    let mediaJSON: String
    enum CodingKeys: String, CodingKey {
        case ordinal
        case senderUserID = "sender_user_id"
        case text = "text_body"
        case entitiesJSON = "entities_json"
        case mediaJSON = "media_json"
    }
}
private struct ForwardSource: Sendable {
    let messageID: MessageID
    let outcome: ForwardSourceOutcome
}
private enum ForwardSourceOutcome: Sendable {
    case content(ForwardSourceContent)
    case unavailable(String)
}
private struct ForwardSourceContent: Sendable { let senderUserID: UserID; let text: String; let media: [V2MediaReference]; let entities: [V2MessageEntity] }
private struct ForwardTargetResults: Sendable { let targetIndex: Int; let results: [V2ForwardMessageResult] }
private struct ForwardOperationRow: Decodable { let clientMessageID: UUID; enum CodingKeys: String, CodingKey { case clientMessageID = "target_client_message_id" } }
private struct ForwardReplayRow: Decodable {
    let resultMessageID: UUID?
    let sourceMessageID: UUID
    let targetRoomID: UUID
    let messageID: UUID?
    let roomID: UUID?
    let roomSequence: Int64?
    enum CodingKeys: String, CodingKey {
        case resultMessageID = "result_message_id"
        case sourceMessageID = "source_message_id"
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
private enum V2ForwardStoreError: Error { case notVisible, corrupt }
private func forwardErrorCode(_ error: Error) -> String { switch error { case V2ForwardStoreError.notVisible: "NOT_FOUND"; case V2RoomWriteStoreError.actorNotEligible: "FORBIDDEN"; case V2RoomWriteStoreError.roomNotFound: "NOT_FOUND"; default: "UNAVAILABLE" } }
