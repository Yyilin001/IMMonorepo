import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Permanent minimal outcomes. Submission and closure hold the same operation lock
/// before the room activation fence; message content remains in its existing lifecycle.
public struct PostgresV2MessageMutationOperationStore:Sendable {
    private let database:any Database
    private let identities:(any V2MembershipIdentitySnapshotValidating)?
    private let contentReviewMode:V2ContentReviewMode
    private let clock:@Sendable () -> Date
    private let committedMessageObserver: (any V2CommittedMessageBatchObserving)?
    public init(database:any Database,contentReviewMode:V2ContentReviewMode,identities:(any V2MembershipIdentitySnapshotValidating)? = nil,clock:@escaping @Sendable () -> Date = Date.init,committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil) { self.database=database;self.contentReviewMode=contentReviewMode;self.identities=identities;self.clock=clock;self.committedMessageObserver=committedMessageObserver }
    public func edit(_ command:V2MessageEditOperationCommand,token:V2RoomActivationToken,capacityProfile:V2CapacityProfile,eventID:EventID,now:Date,maximumUTF8Bytes:Int) async throws -> V2MessageMutationRecoveryResult {
        let identity=try command.identity, fingerprint=try command.fingerprint
        return try await execute(identity:identity,fingerprint:fingerprint,deadline:command.firstSubmissionDeadlineMilliseconds,token:token,now:now) { transaction in
            let outcome=try await PostgresV2MessageEditStore(database:transaction,contentReviewMode:contentReviewMode,identities:identities)
                .usingOperationTransaction().usingActivationScope(.init(tokens:[token])).edit(command:command.domainCommand(maximumUTF8Bytes:maximumUTF8Bytes),capacityProfile:capacityProfile,eventID:eventID,now:now)
            switch outcome {
            case .edited(let value): return .terminal(.committed(try .init(messageID:value.messageID,messageRevision:value.messageRevision,roomSequence:value.roomSequence,eventID:value.eventID)), isNewEvent: true)
            case .idempotent(let value): return .terminal(.committed(try .init(messageID:value.messageID,messageRevision:value.messageRevision,roomSequence:value.roomSequence,eventID:value.eventID)))
            case .revisionConflict(let revision): return .terminal(.rejected(.revisionConflict(current:revision)))
            case .alreadyWithdrawn: return .terminal(.rejected(.alreadyWithdrawn))
            case .idempotencyConflict: throw V2MessageOperationValidationError.invalidReceipt
            case .rateLimited(let seconds): return .deferred(try .init(identity:identity,fingerprint:fingerprint,reason:.rateLimited,retryAfterMilliseconds:UInt64(min(86_400,max(1,seconds)))*1000))
            case .unavailable: return .deferred(try .init(identity:identity,fingerprint:fingerprint,reason:.admissionUnavailable,retryAfterMilliseconds:nil))
            }
        }
    }
    public func withdraw(_ command:V2MessageWithdrawalOperationCommand,token:V2RoomActivationToken,capacityProfile:V2CapacityProfile,eventID:EventID,now:Date) async throws -> V2MessageMutationRecoveryResult {
        let identity=try command.identity, fingerprint=try command.fingerprint
        return try await execute(identity:identity,fingerprint:fingerprint,deadline:command.firstSubmissionDeadlineMilliseconds,token:token,now:now) { transaction in
            let outcome=try await PostgresV2MessageWithdrawalStore(database:transaction)
                .usingOperationTransaction().usingActivationScope(.init(tokens:[token])).withdraw(command:command.domainCommand(),capacityProfile:capacityProfile,eventID:eventID,now:now)
            switch outcome {
            case .withdrawn(let value): return .terminal(.committed(try .init(messageID:value.messageID,messageRevision:value.messageRevision,roomSequence:value.roomSequence,eventID:value.eventID)), isNewEvent: true)
            case .idempotent(let value): return .terminal(.committed(try .init(messageID:value.messageID,messageRevision:value.messageRevision,roomSequence:value.roomSequence,eventID:value.eventID)))
            case .revisionConflict(let revision): return .terminal(.rejected(.revisionConflict(current:revision)))
            case .alreadyWithdrawn: return .terminal(.rejected(.alreadyWithdrawn))
            case .idempotencyConflict: throw V2MessageOperationValidationError.invalidReceipt
            case .rateLimited(let seconds): return .deferred(try .init(identity:identity,fingerprint:fingerprint,reason:.rateLimited,retryAfterMilliseconds:UInt64(min(86_400,max(1,seconds)))*1000))
            case .unavailable: return .deferred(try .init(identity:identity,fingerprint:fingerprint,reason:.admissionUnavailable,retryAfterMilliseconds:nil))
            }
        }
    }
    public func recover(_ request:V2MessageMutationRecoveryRequest,token:V2RoomActivationToken,now:Date) async throws -> V2MessageMutationRecoveryResult {
        try await v2WithRoomScopedTransaction(database:database) { transaction in
            let context=try await lockedContext(identity:request.identity,token:token,database:transaction)
            if let result=try await existing(identity:request.identity,fingerprint:request.fingerprint,sql:context.sql) { return result }
            guard request.action == .closeIfAbsent else { return .unresolved }
            return .receipt(try await persist(identity:request.identity,fingerprint:request.fingerprint,outcome:.closed,now:now,sql:context.sql))
        }
    }
    private func execute(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,deadline:UInt64,token:V2RoomActivationToken,now:Date,body:@escaping @Sendable(any Database) async throws -> MutationBodyResult) async throws -> V2MessageMutationRecoveryResult {
        let committed: (V2MessageMutationRecoveryResult, Bool) = try await v2WithRoomScopedTransaction(database:database) { transaction in
            let context=try await lockedContext(identity:identity,token:token,database:transaction)
            if let result=try await existing(identity:identity,fingerprint:fingerprint,sql:context.sql) { return (result, false) }
            // The body captures the caller timestamp; validate it only after original proof lookup.
            _ = try timestamp(now)
            let now=clock()
            let nowMS=try timestamp(now)
            guard deadline>nowMS,deadline-nowMS<=600_000 else {
                return (.receipt(try await persist(identity:identity,fingerprint:fingerprint,outcome:.rejected(.expiredUnsubmitted),now:now,sql:context.sql)), false)
            }
            let result:MutationBodyResult
            do { result=try await body(transaction) }
            catch V2MessageEditStoreError.roomNotFound { result = .terminal(.rejected(.roomNotFound)) }
            catch V2MessageEditStoreError.messageNotFound { result = .terminal(.rejected(.messageNotFound)) }
            catch V2MessageEditStoreError.actorNotAuthor { result = .terminal(.rejected(.permissionDenied)) }
            catch V2MessageWithdrawalStoreError.roomNotFound { result = .terminal(.rejected(.roomNotFound)) }
            catch V2MessageWithdrawalStoreError.messageNotFound { result = .terminal(.rejected(.messageNotFound)) }
            catch V2MessageWithdrawalStoreError.actorNotAuthor { result = .terminal(.rejected(.permissionDenied)) }
            catch V2RoomWriteStoreError.actorNotEligible { result = .terminal(.rejected(.permissionDenied)) }
            catch V2RoomWriteStoreError.actorMuted { result = .terminal(.rejected(.permissionDenied)) }
            catch V2RoomWriteStoreError.roomFrozen { result = .terminal(.rejected(.permissionDenied)) }
            switch result {
            case .terminal(let outcome, let isNewEvent): return (.receipt(try await persist(identity:identity,fingerprint:fingerprint,outcome:outcome,now:now,sql:context.sql)), isNewEvent)
            case .deferred(let hint): return (.deferred(hint), false)
            }
        }
        if committed.1, case .receipt(let receipt) = committed.0, case .committed(let event) = receipt.outcome {
            committedMessageObserver?.observeCommittedRoomSequence(roomID: token.roomID, roomSequence: event.roomSequence)
        }
        return committed.0
    }
    private func lockedContext(identity:V2OperationIdentity,token:V2RoomActivationToken,database:any Database) async throws -> (sql:any SQLDatabase,room:UUID) {
        guard identity.kind == .editMessage || identity.kind == .withdrawMessage,
              case .message(let roomID,_)=identity.scope,roomID==token.roomID,
              let room=roomID.uuidValue,let actor=identity.accountID.uuidValue,
              let operation=UUID(uuidString:identity.operation.rawOperationID),let sql=database as? any SQLDatabase else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        // Preserve the inner mutation lock ordering while replacing its retained ledger.
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:actor.uuidString+":"+operation.uuidString),0))").run()
        try await v2RequireRoomActivation(token:token,sql:sql)
        return (sql,room)
    }
    private func existing(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,sql:any SQLDatabase) async throws -> V2MessageMutationRecoveryResult? {
        guard let row=try await sql.raw("SELECT receipt::text AS receipt FROM im_v2.message_mutation_receipts WHERE actor_user_id=\(bind:identity.accountID.uuidValue!) AND operation_id=\(bind:UUID(uuidString:identity.operation.rawOperationID)!)").first(decoding:ReceiptRow.self) else { return nil }
        let receipt=try JSONDecoder().decode(V2MessageMutationReceipt.self,from:Data(row.receipt.utf8))
        guard receipt.validates(identity:identity,fingerprint:fingerprint) else { return .fingerprintConflict }
        return .receipt(receipt)
    }
    private func persist(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,outcome:V2MessageMutationTerminalOutcome,now:Date,sql:any SQLDatabase) async throws -> V2MessageMutationReceipt {
        let receipt=try V2MessageMutationReceipt(identity:identity,fingerprint:fingerprint,outcome:outcome,resolvedAtMilliseconds:timestamp(now))
        guard case .message(let room,let message)=identity.scope else { throw V2MessageOperationValidationError.invalidKind }
        let payload=String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
        try await sql.raw("""
            INSERT INTO im_v2.message_mutation_receipts(actor_user_id,operation_id,room_id,message_id,kind,fingerprint_version,request_fingerprint,receipt,resolved_at)
            VALUES(\(bind:identity.accountID.uuidValue!),\(bind:UUID(uuidString:identity.operation.rawOperationID)!),\(bind:room.uuidValue!),\(bind:message.uuidValue!),\(bind:identity.kind.rawValue),\(bind:Int16(fingerprint.version)),\(bind:fingerprint.digest),\(bind:payload)::jsonb,\(bind:now))
            """).run()
        return receipt
    }
    private func timestamp(_ date:Date) throws -> UInt64 {
        let value=date.timeIntervalSince1970*1000
        guard v2PostgresTimestampCanEncode(date),value.isFinite,value>0,value<Double(Int64.max) else { throw V2MessageOperationValidationError.invalidReceipt }
        return UInt64(value)
    }
}
private struct ReceiptRow:Decodable { let receipt:String }

private enum MutationBodyResult:Sendable { case terminal(V2MessageMutationTerminalOutcome, isNewEvent: Bool = false),deferred(V2MessageOperationRetryHint) }
