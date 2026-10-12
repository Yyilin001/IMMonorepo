import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 同一所有者上的双房间执行。调用方已取得规范的来源／目标预留；
/// 此类型不会再次尝试预留执行轮次。
public struct V2ActorForwardPairDomainExecutor: Sendable {
    private let database: any Database
    private var write: PostgresV2RoomWriteStore
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let acceptanceIDs: V2AcceptanceIDFactory
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    private let now: @Sendable () -> Date

    public init(database: any Database, write: PostgresV2RoomWriteStore,
                capacityProfile: V2CapacityProfile, limits: V2MessageCommandLimits,
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
                acceptanceIDs: V2AcceptanceIDFactory = .init(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database; self.write = write
        self.capacityProfile = capacityProfile; self.limits = limits
        self.acceptanceIDs = acceptanceIDs; self.now = now
        self.databaseWorkAdmission = databaseWorkAdmission
    }

    package func usingPolicyAuthorizations(_ service: V2RoomPolicyAuthorizationService) -> Self {
        var copy = self; copy.write = write.usingPolicyAuthorizations(service); return copy
    }

    public func execute(_ pair: V2ActorForwardPairWire,
                        activationTokens: [V2RoomActivationToken],
                        deadline: ContinuousClock.Instant? = nil) async throws -> V2ActorForwardMessageResultWire {
        let deadline = deadline ?? V2RoomSQLDeadline.boundedTransactionDeadline()
        return try await v2WithAdmittedRoomDatabaseWork(databaseWorkAdmission,
            workClass: .foregroundWrite, callerDeadline: deadline) {
            try await V2RoomSQLDeadline.withDeadline(deadline) {
                do {
                    return try await executeBounded(pair, activationTokens: activationTokens)
                } catch V2SendOperationResponseError.directPolicyDenied {
                    return try failure(pair, code: "DIRECT_MESSAGE_RESTRICTED")
                }
            }
        }
    }

    private func executeBounded(_ pair: V2ActorForwardPairWire,
                                activationTokens: [V2RoomActivationToken]) async throws -> V2ActorForwardMessageResultWire {
        let selected = Set([pair.source.roomID, pair.targetRoomID])
        guard activationTokens.count == selected.count,
              Set(activationTokens.map(\.roomID)) == selected else {
            throw V2RoomActorStateError.activationChanged
        }
        let scope = try V2RoomActivationWriteScope(tokens: activationTokens)
        let key = try ForwardPairIdentity(pair)
        if let replay = try await replay(key, scope: scope) { return .init(domain: replay) }
        guard let content = try await sourceContent(key: key, scope: scope) else {
            return try failure(pair, code: "NOT_FOUND")
        }
        guard content.revision == pair.source.revision.signedValue else {
            return try failure(pair, code: "SOURCE_CHANGED")
        }
        let clientID = deterministicClientID(key)
        let command = try V2SendMessageCommand(roomID: pair.targetRoomID,
            senderUserID: pair.actorUserID, clientMessageID: .init(uuid: clientID),
            text: content.text,
            media: content.media.map { .init(mediaID: .init(uuid: $0)) },
            entities: content.entities,
            forwardedFrom: .init(messageID: pair.source.messageID,
                                 senderUserID: .init(uuid: content.sender),
                                 sourceRevision: pair.source.revision), limits: limits)
        let acceptedAt = now()
        guard v2PostgresTimestampCanEncode(acceptedAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let request = V2RoomWriteRequest(command: command, capacityProfile: capacityProfile,
            identifiers: try acceptanceIDs.make(at: acceptedAt), now: acceptedAt)
        let outcome = try await write.acceptActorForwardPair(request: request,
            sourceRoomID: pair.source.roomID, activationTokens: activationTokens,
            prepareLedger: { transaction in
                let sql = try forwardSQL(transaction)
                try await prepare(key, clientID: clientID, at: acceptedAt, sql: sql)
            }, recordLedger: { outcome, transaction in
                guard let receipt = outcome.acceptanceReceipt else { return }
                let sql = try forwardSQL(transaction)
                try await record(key, messageID: receipt.messageID, sql: sql)
            })
        switch outcome {
        case .accepted, .idempotent:
            guard let receipt = outcome.acceptanceReceipt else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return .init(domain: try .init(sourceMessageID: pair.source.messageID,
                targetRoomID: pair.targetRoomID, messageID: receipt.messageID,
                roomSequence: receipt.roomSequence, errorCode: nil))
        case .idempotencyConflict: return try failure(pair, code: "IDEMPOTENCY_CONFLICT")
        case .denied: return try failure(pair, code: "DIRECT_MESSAGE_RESTRICTED")
        case .rateLimited: return try failure(pair, code: "RATE_LIMITED")
        case .unavailable: return try failure(pair, code: "UNAVAILABLE")
        }
    }

    private func failure(_ pair: V2ActorForwardPairWire, code: String) throws -> V2ActorForwardMessageResultWire {
        .init(domain: try .init(sourceMessageID: pair.source.messageID,
            targetRoomID: pair.targetRoomID, messageID: nil, roomSequence: nil, errorCode: code))
    }

    private func replay(_ key: ForwardPairIdentity,
                        scope: V2RoomActivationWriteScope) async throws -> V2ForwardMessageResult? {
        try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: true, useRoomDeadline: true) { transaction in
            let sql = try forwardSQL(transaction)
            try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
            try await scope.require([key.sourceRoom, key.target], sql: sql)
            guard let row = try await sql.raw("""
                SELECT operation.result_message_id, completion.message_id AS completion_message_id,
                       COALESCE(saved.message_id, recovered.message_id) AS physical_message_id,
                       operation.source_room_id,
                       operation.source_content_revision,
                       COALESCE(saved.message_id, recovered.message_id, completion.message_id) AS message_id,
                       COALESCE(saved.room_id, recovered.room_id, completion.room_id) AS room_id,
                       COALESCE(saved.room_sequence, recovered.room_sequence, completion.room_sequence) AS room_sequence
                FROM im_v2.message_forward_operations AS operation
                LEFT JOIN im_v2.messages AS saved ON saved.message_id = operation.result_message_id
                LEFT JOIN im_v2.messages AS recovered
                  ON operation.result_message_id IS NULL
                 AND recovered.sender_user_id = operation.actor_user_id
                 AND recovered.client_message_id = operation.target_client_message_id
                LEFT JOIN im_v2.message_send_completions AS completion
                  ON completion.room_id = operation.target_room_id
                 AND completion.sender_user_id = operation.actor_user_id
                 AND completion.client_message_id = operation.target_client_message_id
                WHERE operation.actor_user_id = \(bind: key.actor)
                  AND operation.operation_id = \(bind: key.operation)
                  AND operation.source_message_id = \(bind: key.source)
                  AND operation.target_room_id = \(bind: key.target)
                FOR UPDATE OF operation
                """).first(decoding: ForwardPairReplayRow.self) else { return nil }
            guard row.sourceRoomID == key.sourceRoom,
                  row.sourceRevision == key.revision else {
                return try .init(sourceMessageID: .init(uuid: key.source),
                    targetRoomID: .init(uuid: key.target), messageID: nil,
                    roomSequence: nil, errorCode: "IDEMPOTENCY_CONFLICT")
            }
            guard let id = row.messageID, row.roomID == key.target,
                  let sequence = row.roomSequence, sequence > 0 else { return nil }
            guard row.resultMessageID == nil || row.resultMessageID == id,
                  row.completionMessageID == nil || row.completionMessageID == id else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            if row.resultMessageID == nil, row.physicalMessageID != nil {
                try await record(key, messageID: .init(uuid: id), sql: sql)
            }
            return try .init(sourceMessageID: .init(uuid: key.source),
                targetRoomID: .init(uuid: key.target), messageID: .init(uuid: id),
                roomSequence: UInt64(sequence), errorCode: nil)
        }
    }

    private func sourceContent(key: ForwardPairIdentity,
                               scope: V2RoomActivationWriteScope) async throws -> ForwardPairContent? {
        try await v2WithRoomScopedTransaction(database: database) { transaction in
            let sql = try forwardSQL(transaction)
            try await scope.require([key.sourceRoom], sql: sql)
            guard let row = try await sql.raw("""
            SELECT message.sender_user_id, message.text_body,
                   message.content_revision,
                   message.rich_entities::text AS entities_json,
                   COALESCE(jsonb_agg(media.media_id ORDER BY media.ordinal)
                     FILTER (WHERE media.media_id IS NOT NULL AND media.revoked_at IS NULL),
                     '[]'::jsonb)::text AS media_json
            FROM im_v2.messages AS message
            JOIN im_v2.rooms AS room ON room.room_id = message.room_id
            LEFT JOIN im_v2.message_media_references AS media
              ON media.message_id = message.message_id
            WHERE message.message_id = \(bind: key.source)
              AND message.room_id = \(bind: key.sourceRoom)
              AND message.withdrawn_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM im_v2.message_media_references AS revoked
                WHERE revoked.message_id = message.message_id AND revoked.revoked_at IS NOT NULL)
              AND \(v2ForwardSourceVisibility(actorID: key.actor))
            GROUP BY message.sender_user_id, message.text_body,
                     message.content_revision, message.rich_entities
            """).first(decoding: ForwardPairSourceRow.self) else { return nil }
            return try .init(sender: row.sender, text: row.text, revision: row.revision,
                entities: JSONDecoder().decode([V2MessageEntity].self, from: Data(row.entitiesJSON.utf8)),
                media: JSONDecoder().decode([UUID].self, from: Data(row.mediaJSON.utf8)))
        }
    }
}

private struct ForwardPairIdentity: Sendable {
    let actor: UUID, operation: UUID, source: UUID, sourceRoom: UUID, target: UUID
    let revision: Int64
    init(_ pair: V2ActorForwardPairWire) throws {
        guard let actor = pair.actorUserID.uuidValue,
              let operation = pair.operationID.uuidValue,
              let source = pair.source.messageID.uuidValue,
              let sourceRoom = pair.source.roomID.uuidValue,
              let target = pair.targetRoomID.uuidValue else { throw V2ForwardExportError.invalidRequest }
        self.actor = actor; self.operation = operation; self.source = source
        self.sourceRoom = sourceRoom; self.target = target
        self.revision = pair.source.revision.signedValue
    }
}

private struct ForwardPairReplayRow: Decodable {
    let resultMessageID: UUID?
    let completionMessageID: UUID?
    let physicalMessageID: UUID?
    let sourceRoomID: UUID?
    let sourceRevision: Int64?
    let messageID: UUID?
    let roomID: UUID?
    let roomSequence: Int64?
    enum CodingKeys: String, CodingKey {
        case resultMessageID = "result_message_id"
        case completionMessageID = "completion_message_id"
        case physicalMessageID = "physical_message_id"
        case sourceRoomID = "source_room_id"
        case sourceRevision = "source_content_revision"
        case messageID = "message_id"
        case roomID = "room_id"
        case roomSequence = "room_sequence"
    }
}
private struct ForwardPairSourceRow: Decodable {
    let sender: UUID
    let text: String
    let revision: Int64
    let entitiesJSON: String
    let mediaJSON: String
    enum CodingKeys: String, CodingKey {
        case sender = "sender_user_id", text = "text_body"
        case revision = "content_revision", entitiesJSON = "entities_json"
        case mediaJSON = "media_json"
    }
}
private struct ForwardPairContent: Sendable {
    let sender: UUID
    let text: String
    let revision: Int64
    let entities: [V2MessageEntity]
    let media: [UUID]
}

private func forwardSQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return sql
}

private func deterministicClientID(_ key: ForwardPairIdentity) -> UUID {
    let value = "v2-forward-pair:v1:\(key.actor):\(key.operation):\(key.source):\(key.target)"
    var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))")!
}

private func prepare(_ key: ForwardPairIdentity, clientID: UUID, at now: Date,
                     sql: any SQLDatabase) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.message_forward_operations
          (actor_user_id, operation_id, source_message_id, target_room_id,
           target_client_message_id, source_content_revision, source_room_id, created_at)
        VALUES (\(bind: key.actor), \(bind: key.operation), \(bind: key.source),
                \(bind: key.target), \(bind: clientID), \(bind: key.revision),
                \(bind: key.sourceRoom), \(bind: now))
        ON CONFLICT DO NOTHING
        """).run()
    guard let row = try await sql.raw("""
        SELECT target_client_message_id, source_content_revision, source_room_id
        FROM im_v2.message_forward_operations
        WHERE actor_user_id = \(bind: key.actor) AND operation_id = \(bind: key.operation)
          AND source_message_id = \(bind: key.source) AND target_room_id = \(bind: key.target)
        FOR UPDATE
        """).first(decoding: ForwardPairPreparedRow.self),
        row.clientMessageID == clientID, row.sourceRevision == key.revision,
        row.sourceRoomID == key.sourceRoom else {
        throw V2ForwardExportError.idempotencyConflict
    }
}

private func record(_ key: ForwardPairIdentity, messageID: MessageID,
                    sql: any SQLDatabase) async throws {
    guard let message = messageID.uuidValue,
          let row = try await sql.raw("""
            UPDATE im_v2.message_forward_operations
            SET result_message_id = \(bind: message)
            WHERE actor_user_id = \(bind: key.actor) AND operation_id = \(bind: key.operation)
              AND source_message_id = \(bind: key.source) AND target_room_id = \(bind: key.target)
              AND (result_message_id IS NULL OR result_message_id = \(bind: message))
            RETURNING result_message_id
            """).first(decoding: ForwardPairRecordedRow.self), row.messageID == message else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
}

private struct ForwardPairPreparedRow: Decodable {
    let clientMessageID: UUID
    let sourceRevision: Int64?
    let sourceRoomID: UUID?
    enum CodingKeys: String, CodingKey {
        case clientMessageID = "target_client_message_id"
        case sourceRevision = "source_content_revision"
        case sourceRoomID = "source_room_id"
    }
}
private struct ForwardPairRecordedRow: Decodable {
    let messageID: UUID
    enum CodingKeys: String, CodingKey { case messageID = "result_message_id" }
}
