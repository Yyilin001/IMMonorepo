import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

public struct PostgresV2MessageSendOperationStore:Sendable {
    private let database:any Database
    private let writes:PostgresV2RoomWriteStore
    private let clock:@Sendable () -> Date
    private let committedMessageObserver: (any V2CommittedMessageBatchObserving)?
    public init(database:any Database,writes:PostgresV2RoomWriteStore,clock:@escaping @Sendable () -> Date = Date.init, committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil) { self.database=database;self.writes=writes;self.clock=clock;self.committedMessageObserver=committedMessageObserver }
    public func send(_ command:V2MessageSendOperationCommand,token:V2RoomActivationToken,capacityProfile:V2CapacityProfile,identifiers:V2AcceptanceIdentifiers) async throws -> V2MessageSendOperationRecoveryResult {
        let identity=try command.identity,fingerprint=try command.fingerprint
        let committed: (V2MessageSendOperationRecoveryResult, V2SendMessageOutcome?) = try await v2WithRoomScopedTransaction(database:database) { transaction in
            let sql=try await lock(identity:identity,token:token,database:transaction)
            if let result=try await existing(identity:identity,fingerprint:fingerprint,domain:command.command.fingerprint,sql:sql) { return (result, nil) }
            let now=clock(),ms=try timestamp(now)
            guard command.firstSubmissionDeadlineMilliseconds>ms,command.firstSubmissionDeadlineMilliseconds-ms<=86_400_000 else {
                return (.receipt(try await persist(identity:identity,fingerprint:fingerprint,domain:command.command.fingerprint,outcome:.rejected(.expiredUnsubmitted),now:now,sql:sql)), nil)
            }
            try await sql.raw("SAVEPOINT v2_message_domain_body").run()
            let outcome:V2SendMessageOutcome
            do {
                outcome=try await writes.usingWorkloadDatabase(transaction).usingOperationTransaction().usingActivationScope(.init(tokens:[token]))
                    .accept(command:command.command,capacityProfile:capacityProfile,identifiers:identifiers,now:now)
            } catch V2RoomWriteStoreError.strangerMessageLimitReached {
                try await rollbackBody(sql)
                return (.deferred(try .init(identity:identity,fingerprint:fingerprint,reason:.rateLimited,retryAfterMilliseconds:await quotaRetryAfter(room:token.roomID,actor:identity.accountID,now:now,sql:sql))), nil)
            } catch V2RoomWriteStoreError.actorNotEligible {
                try await rollbackBody(sql)
                return (.receipt(try await persist(identity:identity,fingerprint:fingerprint,domain:command.command.fingerprint,outcome:.rejected(.permissionDenied),now:now,sql:sql)), nil)
            } catch V2RoomWriteStoreError.actorMuted {
                try await rollbackBody(sql)
                return (.receipt(try await persist(identity:identity,fingerprint:fingerprint,domain:command.command.fingerprint,outcome:.rejected(.permissionDenied),now:now,sql:sql)), nil)
            } catch V2RoomWriteStoreError.roomFrozen {
                try await rollbackBody(sql)
                return (.receipt(try await persist(identity:identity,fingerprint:fingerprint,domain:command.command.fingerprint,outcome:.rejected(.permissionDenied),now:now,sql:sql)), nil)
            } catch V2RoomWriteStoreError.roomNotFound {
                try await rollbackBody(sql)
                return (.receipt(try await persist(identity:identity,fingerprint:fingerprint,domain:command.command.fingerprint,outcome:.rejected(.roomNotFound),now:now,sql:sql)), nil)
            }
            try await sql.raw("RELEASE SAVEPOINT v2_message_domain_body").run()
            if let accepted=outcome.acceptanceReceipt {
                let newlyAccepted: V2SendMessageOutcome?
                if case .accepted = outcome { newlyAccepted = outcome } else { newlyAccepted = nil }
                return (.receipt(try await persist(identity:identity,fingerprint:fingerprint,domain:command.command.fingerprint,outcome:.accepted(.init(messageID:accepted.messageID,roomSequence:accepted.roomSequence)),now:now,sql:sql)), newlyAccepted)
            }
            switch outcome {
            case .denied: return (.receipt(try await persist(identity:identity,fingerprint:fingerprint,domain:command.command.fingerprint,outcome:.rejected(.directPolicyDenied),now:now,sql:sql)), nil)
            case .idempotencyConflict: return (.fingerprintConflict, nil)
            case .rateLimited(let seconds): return (.deferred(try .init(identity:identity,fingerprint:fingerprint,reason:.rateLimited,retryAfterMilliseconds:UInt64(min(86_400,max(1,seconds)))*1000)), nil)
            case .unavailable: return (.deferred(try .init(identity:identity,fingerprint:fingerprint,reason:.admissionUnavailable,retryAfterMilliseconds:nil)), nil)
            case .accepted,.idempotent: throw V2MessageOperationValidationError.invalidReceipt
            }
        }
        // Only a newly accepted domain result from the successfully committed
        // outer transaction enters the existing bounded live-delivery observer.
        if let outcome = committed.1 {
            committedMessageObserver?.observeCommittedMessages([outcome])
        }
        return committed.0
    }
    public func recover(_ request:V2MessageSendOperationRecoveryRequest,token:V2RoomActivationToken) async throws -> V2MessageSendOperationRecoveryResult {
        try await v2WithRoomScopedTransaction(database:database) { transaction in
            let sql=try await lock(identity:request.identity,token:token,database:transaction)
            if let result=try await existing(identity:request.identity,fingerprint:request.fingerprint,domain:request.domainFingerprint,sql:sql) { return result }
            // Existing permanent acceptance is stronger than absence of the execution envelope.
            // Ordinary production submissions always create both in the same transaction.
            if let _=try await sql.raw("SELECT 1 AS present FROM im_v2.message_send_completions WHERE room_id=\(bind:token.roomID.uuidValue!) AND sender_user_id=\(bind:request.identity.accountID.uuidValue!) AND client_message_id=\(bind:UUID(uuidString:request.identity.operation.rawOperationID)!)").first() {
                throw V2MessageOperationValidationError.invalidReceipt
            }
            guard request.action == .closeIfAbsent else { return .unresolved }
            return .receipt(try await persist(identity:request.identity,fingerprint:request.fingerprint,domain:request.domainFingerprint,outcome:.closed,now:clock(),sql:sql))
        }
    }
    private func lock(identity:V2OperationIdentity,token:V2RoomActivationToken,database:any Database) async throws -> any SQLDatabase {
        guard identity.kind == .sendMessage,case .room(let room)=identity.scope,room==token.roomID,
            let roomUUID=room.uuidValue,let actor=identity.accountID.uuidValue,let operation=UUID(uuidString:identity.operation.rawOperationID),let sql=database as? any SQLDatabase else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended('v2-message-operation:' || \(bind:roomUUID)::text || ':' || \(bind:actor)::text || ':' || \(bind:operation)::text,0))").run()
        try await v2RequireRoomActivation(token:token,sql:sql)
        return sql
    }
    private func existing(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,domain:V2SendMessageFingerprint,sql:any SQLDatabase) async throws -> V2MessageSendOperationRecoveryResult? {
        guard case .room(let room)=identity.scope else { throw V2MessageOperationValidationError.invalidKind }
        guard let row=try await sql.raw("SELECT receipt::text AS receipt,domain_fingerprint FROM im_v2.message_send_operation_receipts WHERE room_id=\(bind:room.uuidValue!) AND actor_user_id=\(bind:identity.accountID.uuidValue!) AND operation_id=\(bind:UUID(uuidString:identity.operation.rawOperationID)!)").first(decoding:SendReceiptRow.self) else { return nil }
        let receipt=try JSONDecoder().decode(V2MessageSendOperationReceipt.self,from:Data(row.receipt.utf8))
        guard receipt.validates(identity:identity,fingerprint:fingerprint),row.domainFingerprint==domain.digest else { return .fingerprintConflict }
        return .receipt(receipt)
    }
    private func persist(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,domain:V2SendMessageFingerprint,outcome:V2MessageSendOperationTerminalOutcome,now:Date,sql:any SQLDatabase) async throws -> V2MessageSendOperationReceipt {
        guard case .room(let room)=identity.scope else { throw V2MessageOperationValidationError.invalidKind }
        let receipt=try V2MessageSendOperationReceipt(identity:identity,fingerprint:fingerprint,outcome:outcome,resolvedAtMilliseconds:timestamp(now))
        let actor=identity.accountID.uuidValue!,operation=UUID(uuidString:identity.operation.rawOperationID)!,roomUUID=room.uuidValue!
        // A negative outcome fences even delayed domain appends using the original v3 lock and close trigger.
        if case .accepted=outcome {} else {
            try await sql.raw("INSERT INTO im_v2.message_operation_closures(room_id,sender_user_id,client_message_id,fingerprint_version,request_fingerprint,closed_at) VALUES(\(bind:roomUUID),\(bind:actor),\(bind:operation),3,\(bind:domain.digest),\(bind:now))").run()
        }
        let payload=String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
        try await sql.raw("""
            INSERT INTO im_v2.message_send_operation_receipts(room_id,actor_user_id,operation_id,fingerprint_version,request_fingerprint,domain_fingerprint,receipt,resolved_at)
            VALUES(\(bind:roomUUID),\(bind:actor),\(bind:operation),1,\(bind:fingerprint.digest),\(bind:domain.digest),\(bind:payload)::jsonb,\(bind:now))
            """).run()
        return receipt
    }
    private func quotaRetryAfter(room:RoomID,actor:UserID,now:Date,sql:any SQLDatabase) async throws -> UInt64 {
        let seconds=writes.strangerQuotaWindowSeconds
        let row=try await sql.raw("""
            SELECT quota_window.window_started_at AS started_at
            FROM im_v2.direct_room_pairs pair JOIN im_v2.stranger_message_windows quota_window
              ON quota_window.sender_user_id=\(bind:actor.uuidValue!)
              AND quota_window.recipient_user_id=CASE WHEN pair.lower_user_id=\(bind:actor.uuidValue!) THEN pair.higher_user_id ELSE pair.lower_user_id END
            WHERE pair.room_id=\(bind:room.uuidValue!)
            """).first(decoding:QuotaWindow.self)
        let remaining=row.map { $0.startedAt.addingTimeInterval(seconds).timeIntervalSince(now) } ?? seconds
        return UInt64(min(86_400_000,max(1000,ceil(remaining*1000))))
    }
    private func rollbackBody(_ sql:any SQLDatabase) async throws {
        try await sql.raw("ROLLBACK TO SAVEPOINT v2_message_domain_body").run()
        try await sql.raw("RELEASE SAVEPOINT v2_message_domain_body").run()
    }
    private func timestamp(_ date:Date) throws -> UInt64 {
        let value=date.timeIntervalSince1970*1000
        guard value.isFinite,value>0,value<Double(Int64.max) else { throw V2MessageOperationValidationError.invalidReceipt }
        return UInt64(value)
    }
}
private struct SendReceiptRow:Decodable {
    let receipt:String;let domainFingerprint:Data
    enum CodingKeys:String,CodingKey { case receipt,domainFingerprint="domain_fingerprint" }
}

private struct QuotaWindow:Decodable { let startedAt:Date;enum CodingKeys:String,CodingKey { case startedAt="started_at" } }
