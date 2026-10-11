import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Own-key revision and permanent original outcomes share the RoomRef write transaction.
public struct PostgresV2MessageReactionOperationStore: Sendable {
    private let database: any Database
    private let clock: @Sendable () -> Date
    private let committedMessageObserver: (any V2CommittedMessageBatchObserving)?
    public init(database: any Database, clock: @escaping @Sendable () -> Date = Date.init, committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil) {
        self.database = database; self.clock = clock; self.committedMessageObserver = committedMessageObserver
    }
    public func change(_ command: V2MessageReactionOperationCommand, token: V2RoomActivationToken,
                       capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageReactionRecoveryResult {
        let identity = try command.identity, fingerprint = try command.fingerprint
        let committed: (V2MessageReactionRecoveryResult, Bool) = try await v2WithRoomScopedTransaction(database: database) { transaction in
            let sql = try await lock(identity: identity, token: token, database: transaction)
            if let prior = try await existing(identity: identity, fingerprint: fingerprint, sql: sql) { return (prior, false) }
            _ = try milliseconds(now)
            let authoritativeNow = clock(), nowMS = try milliseconds(authoritativeNow)
            guard command.firstSubmissionDeadlineMilliseconds > nowMS,
                  command.firstSubmissionDeadlineMilliseconds - nowMS <= 86_400_000 else {
                return (.receipt(try await persist(identity: identity, fingerprint: fingerprint,
                    outcome: .rejected(.expiredUnsubmitted), now: authoritativeNow, sql: sql)), false)
            }
            let outcome: V2MessageReactionTerminalOutcome
            do {
                try await authorize(room: command.roomID, actor: command.actorUserID, message: command.messageID, sql: sql)
                let current = try await version(room: command.roomID, actor: command.actorUserID,
                    message: command.messageID, reaction: command.reaction, sql: sql)
                guard current.revision == command.expectedReactionRevision else {
                    return (.receipt(try await persist(identity: identity, fingerprint: fingerprint,
                        outcome: .rejected(.revisionConflict(current: current.revision)), now: authoritativeNow, sql: sql)), false)
                }
                let result = try await V2PostgresMessageReactionPersistence(transaction: transaction).change(command: command.domainCommand(),
                        capacityProfile: capacityProfile, eventID: eventID, now: now)
                let proof: V2MessageReactionEventProof?
                switch result {
                case .changed(let value): proof = try .init(roomSequence: value.roomSequence, eventID: value.eventID)
                case .alreadyInDesiredState: proof = nil
                case .idempotent, .idempotencyConflict: throw V2MessageOperationValidationError.invalidReceipt
                case .rateLimited(let seconds):
                    return (.deferred(try .init(identity: identity, fingerprint: fingerprint, reason: .rateLimited,
                        retryAfterMilliseconds: UInt64(min(86_400, max(1, seconds))) * 1000)), false)
                case .unavailable:
                    return (.deferred(try .init(identity: identity, fingerprint: fingerprint,
                        reason: .admissionUnavailable, retryAfterMilliseconds: nil)), false)
                }
                let revision = current.revision + 1
                try await sql.raw("""
                    INSERT INTO im_v2.message_reaction_key_revisions(room_id,message_id,actor_user_id,reaction,revision,target_state)
                    VALUES(\(bind: command.roomID.uuidValue!),\(bind: command.messageID.uuidValue!),\(bind: command.actorUserID.uuidValue!),\(bind: command.reaction),\(bind: Int64(revision)),\(bind: command.targetState.rawValue))
                    ON CONFLICT(message_id,actor_user_id,reaction) DO UPDATE SET revision=EXCLUDED.revision,target_state=EXCLUDED.target_state
                    """).run()
                outcome = .committed(try .init(targetState: command.targetState, revision: revision, event: proof))
            } catch V2MessageReactionStoreError.roomNotFound { outcome = .rejected(.roomNotFound) }
              catch V2MessageReactionStoreError.messageNotFound { outcome = .rejected(.messageNotFound) }
              catch V2MessageReactionStoreError.actorNotMember { outcome = .rejected(.permissionDenied) }
              catch V2MessageReactionStoreError.messageWithdrawn { outcome = .rejected(.messageWithdrawn) }
              catch V2MessageReactionStoreError.reactionLimitReached { outcome = .rejected(.reactionLimitReached) }
            return (.receipt(try await persist(identity: identity, fingerprint: fingerprint,
                outcome: outcome, now: authoritativeNow, sql: sql)), true)
        }
        if committed.1, case .receipt(let receipt) = committed.0,
           case .committed(let value) = receipt.outcome, let event = value.event {
            committedMessageObserver?.observeCommittedRoomSequence(roomID: token.roomID, roomSequence: event.roomSequence, activation: token)
        }
        return committed.0
    }
    public func recover(_ request: V2MessageReactionRecoveryRequest, token: V2RoomActivationToken,
                        now: Date) async throws -> V2MessageReactionRecoveryResult {
        try await v2RecoverMessageOperation(database: database, action: request.action, unresolved: .unresolved,
            lock: { try await self.lock(identity: request.identity, token: token, database: $0) },
            existing: { try await self.existing(identity: request.identity, fingerprint: request.fingerprint, sql: $0) },
            close: { .receipt(try await self.persist(identity: request.identity, fingerprint: request.fingerprint,
                outcome: .closed, now: now, sql: $0)) })
    }
    public func snapshot(roomID: RoomID, actorUserID: UserID, messageID: MessageID, reaction: String,
                         token: V2RoomActivationToken) async throws -> V2MessageReactionSnapshot {
        let normalized = try V2ChangeMessageReactionCommand(roomID: roomID, actorUserID: actorUserID,
            operationID: .init(uuid: UUID()), messageID: messageID, reaction: reaction, action: .add).reaction
        guard roomID == token.roomID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        return try await v2WithRoomScopedTransaction(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2MessageReactionStoreError.corruptPersistenceState }
            try await v2RequireRoomActivation(token: token, sql: sql)
            try await authorize(room: roomID, actor: actorUserID, message: messageID, sql: sql)
            let current = try await version(room: roomID, actor: actorUserID, message: messageID, reaction: normalized, sql: sql)
            return try .init(roomID: roomID, actorUserID: actorUserID, messageID: messageID,
                reaction: normalized, targetState: current.targetState, revision: current.revision)
        }
    }
    private func authorize(room: RoomID, actor: UserID, message: MessageID, sql: any SQLDatabase) async throws {
        guard let roomID = room.uuidValue, let actorID = actor.uuidValue, let messageID = message.uuidValue else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        guard let current = try await sql.raw("SELECT membership_revision FROM im_v2.rooms WHERE room_id=\(bind: roomID) FOR UPDATE").first(decoding: MembershipRow.self) else { throw V2MessageReactionStoreError.roomNotFound }
        guard let target = try await sql.raw("SELECT withdrawn_at FROM im_v2.messages WHERE message_id=\(bind: messageID) AND room_id=\(bind: roomID)").first(decoding: MessageRow.self) else { throw V2MessageReactionStoreError.messageNotFound }
        guard target.withdrawnAt == nil else { throw V2MessageReactionStoreError.messageWithdrawn }
        let acceptance = try await v2MessageAcceptanceFact(messageID: messageID, roomID: roomID, sql: sql)
        guard try await sql.raw("""
            SELECT 1 AS present
            WHERE EXISTS (
                SELECT 1 FROM im_v2.room_memberships WHERE room_id=\(bind: roomID) AND user_id=\(bind: actorID)
                AND joined_revision<=\(bind: acceptance.membershipRevision)
                AND (left_revision IS NULL OR left_revision>\(bind: acceptance.membershipRevision))
            ) AND EXISTS (
                SELECT 1 FROM im_v2.room_memberships WHERE room_id=\(bind: roomID) AND user_id=\(bind: actorID)
                AND joined_revision<=\(bind: current.membershipRevision)
                AND (left_revision IS NULL OR left_revision>\(bind: current.membershipRevision))
            )
            """).first(decoding: ExistsRow.self) != nil else { throw V2MessageReactionStoreError.actorNotMember }
    }
    private func version(room: RoomID, actor: UserID, message: MessageID, reaction: String, sql: any SQLDatabase) async throws -> KeyState {
        guard let row = try await sql.raw("SELECT revision,target_state FROM im_v2.message_reaction_key_revisions WHERE message_id=\(bind: message.uuidValue!) AND actor_user_id=\(bind: actor.uuidValue!) AND reaction=\(bind: reaction) FOR UPDATE").first(decoding: KeyRow.self) else { return .init(revision: 0, targetState: .absent) }
        guard row.revision > 0, let state = V2MessageReactionTargetState(rawValue: row.targetState) else { throw V2MessageReactionStoreError.corruptPersistenceState }
        return .init(revision: UInt64(row.revision), targetState: state)
    }
    private func lock(identity: V2OperationIdentity, token: V2RoomActivationToken, database: any Database) async throws -> any SQLDatabase {
        guard identity.kind == .reaction, case .message(let room, _) = identity.scope,
              room == token.roomID, let actor = identity.accountID.uuidValue,
              let operation = UUID(uuidString: identity.operation.rawOperationID), let sql = database as? any SQLDatabase else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        try await v2LockMessageOperation(actor: actor, operation: operation, token: token, sql: sql)
        return sql
    }
    private func existing(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint, sql: any SQLDatabase) async throws -> V2MessageReactionRecoveryResult? {
        try await v2ReadMessageOperationReceipt(V2MessageReactionReceipt.self,
            query: "SELECT receipt::text AS receipt FROM im_v2.message_reaction_receipts WHERE actor_user_id=\(bind: identity.accountID.uuidValue!) AND operation_id=\(bind: UUID(uuidString: identity.operation.rawOperationID)!)",
            sql: sql, validates: { $0.validates(identity: identity, fingerprint: fingerprint) },
            receipt: { .receipt($0) }, conflict: .fingerprintConflict)
    }
    private func persist(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
                         outcome: V2MessageReactionTerminalOutcome, now: Date, sql: any SQLDatabase) async throws -> V2MessageReactionReceipt {
        guard case .message(let room, let message) = identity.scope else { throw V2MessageOperationValidationError.invalidKind }
        let receipt = try V2MessageReactionReceipt(identity: identity, fingerprint: fingerprint,
            outcome: outcome, resolvedAtMilliseconds: milliseconds(now))
        let encoded = try v2EncodePersistenceJSON(receipt)
        try await sql.raw("""
            INSERT INTO im_v2.message_reaction_receipts(actor_user_id,operation_id,room_id,message_id,fingerprint_version,request_fingerprint,receipt,resolved_at)
            VALUES(\(bind: identity.accountID.uuidValue!),\(bind: UUID(uuidString: identity.operation.rawOperationID)!),\(bind: room.uuidValue!),\(bind: message.uuidValue!),1,\(bind: fingerprint.digest),\(bind: encoded)::jsonb,\(bind: now))
            """).run()
        return receipt
    }
    private func milliseconds(_ value: Date) throws -> UInt64 {
        try v2PersistenceMilliseconds(value, invalid: V2MessageOperationValidationError.invalidReceipt)
    }
}
private struct MembershipRow: Decodable { let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision" } }
private struct MessageRow: Decodable { let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case withdrawnAt = "withdrawn_at" } }
private struct ExistsRow: Decodable { let present: Int }
private struct KeyRow: Decodable { let revision: Int64; let targetState: String; enum CodingKeys: String, CodingKey { case revision, targetState = "target_state" } }
private struct KeyState { let revision: UInt64; let targetState: V2MessageReactionTargetState }
