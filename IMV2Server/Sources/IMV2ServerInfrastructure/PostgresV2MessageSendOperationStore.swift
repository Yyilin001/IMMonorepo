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
        guard command.command.roomID == token.roomID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        let identity=try command.identity,fingerprint=try command.fingerprint
        let preparations = try await prepareBatchAuthorizations([command], now: clock)
        let committed: (V2MessageSendOperationRecoveryResult, V2SendMessageOutcome?) = try await v2WithRoomScopedTransaction(database:database) { transaction in
            let sql=try await lock(identity:identity,token:token,database:transaction)
            let processed = try await processSubmission(command, identity: identity, fingerprint: fingerprint,
                token: token, capacityProfile: capacityProfile, transaction: transaction, sql: sql,
                makeIdentifiers: { _ in identifiers }, now: clock, savepoint: "v2_message_domain_body",
                authorizationPreparation: preparations[self.operationKey(identity: identity)])
            return (processed.0, processed.1)
        }
        // Only a newly accepted domain result from the successfully committed
        // outer transaction enters the existing bounded live-delivery observer.
        if let outcome = committed.1 {
            committedMessageObserver?.observeCommittedMessages([outcome])
        }
        return committed.0
    }
    /// Commits the durable domain acceptance and all operation receipts in one
    /// room-scoped transaction. Operation advisory locks are acquired in a
    /// stable key order before domain writes, avoiding cross-batch lock cycles.
    public func sendBatch(_ commands: [V2MessageSendOperationCommand], token: V2RoomActivationToken,
                          capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
                          now: @escaping @Sendable () -> Date) async throws -> [V2RoomMessagingResult] {
        guard !commands.isEmpty, commands.count <= 256,
              commands.allSatisfy({ $0.command.roomID == token.roomID }) else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        // This read only avoids reserving current permissions for operations
        // that already have a durable replay result. The receipt is checked
        // again after acquiring all operation locks in the owner transaction.
        let authorizationPreparations = try await prepareBatchAuthorizations(commands, now: now)
        let committed: ([V2MessageSendOperationRecoveryResult], [V2SendMessageOutcome?]) = try await v2WithRoomScopedTransaction(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2MessageOperationValidationError.invalidReceipt }
            let keyed = try commands.map { command -> (V2MessageSendOperationCommand, V2OperationIdentity, V2OperationFingerprint) in
                (command, try command.identity, try command.fingerprint)
            }
            // Acquire every operation lock first. Taking the room/activation
            // lock inside this loop lets two batches each hold an operation
            // lock while waiting for a policy transaction that needs the
            // other operation lock.
            var lockedOperations = Set<String>()
            for (_, identity, _) in keyed.sorted(by: {
                let lhsActor = $0.1.accountID.uuidValue?.uuidString ?? ""
                let rhsActor = $1.1.accountID.uuidValue?.uuidString ?? ""
                if lhsActor != rhsActor { return lhsActor < rhsActor }
                return $0.1.operation.rawOperationID < $1.1.operation.rawOperationID
            }) {
                let operationKey = "\(identity.accountID.uuidValue?.uuidString ?? ""):\(identity.operation.rawOperationID)"
                if lockedOperations.insert(operationKey).inserted {
                    _ = try await self.lockOperation(identity: identity, token: token, database: transaction)
                }
            }
            try await v2RequireRoomActivation(token: token, sql: sql)
            try await sql.raw("SAVEPOINT v2_message_batch_body").run()
            var results: [V2MessageSendOperationRecoveryResult] = []
            var accepted: [V2SendMessageOutcome?] = []
            var reservations: [ShardAdmissionReservation] = []
            for (index, command) in commands.enumerated() {
                let identity = keyed[index].1, fingerprint = keyed[index].2
                let processed = try await self.processSubmission(command, identity: identity,
                    fingerprint: fingerprint, token: token, capacityProfile: capacityProfile,
                    transaction: transaction, sql: sql, makeIdentifiers: { date in try identifiers.make(at: date) },
                    now: now, savepoint: "v2_message_domain_body_\(index)",
                    authorizationPreparation: authorizationPreparations[self.operationKey(identity: identity)],
                    isOperationBatch: true, priorShardAdmissionReservations: reservations)
                results.append(processed.0)
                accepted.append(processed.1)
                if let reservation = processed.2 { reservations.append(reservation) }
            }
            do {
                try await self.writes.reserveShardAdmissionBatch(reservations,
                    retryAfterSeconds: capacityProfile.limits.retryAfterSeconds, now: now(), sql: sql)
                try await sql.raw("RELEASE SAVEPOINT v2_message_batch_body").run()
            } catch let rejection as LateShardAdmissionRejection {
                try await sql.raw("ROLLBACK TO SAVEPOINT v2_message_batch_body").run()
                try await sql.raw("RELEASE SAVEPOINT v2_message_batch_body").run()
                var deferred: [V2MessageSendOperationRecoveryResult] = []
                for (index, command) in commands.enumerated() {
                    let identity = keyed[index].1, fingerprint = keyed[index].2
                    if let existing = try await self.existing(identity: identity, fingerprint: fingerprint,
                        domain: command.command.fingerprint, sql: sql) {
                        deferred.append(existing)
                    } else if case .receipt(let receipt) = results[index],
                              case .accepted = receipt.outcome {
                        deferred.append(try self.admissionDeferred(identity: identity,
                            fingerprint: fingerprint, rejection: rejection))
                    } else if self.requiresDomainRecovery(results[index]) {
                        // Denials include private timeline/capability facts and an
                        // authorization proof. Re-run their domain path rather than
                        // recreating only the execution receipt. Conflicts must also
                        // be checked against state surviving the batch rollback.
                        let recovered = try await self.processSubmission(command, identity: identity,
                            fingerprint: fingerprint, token: token, capacityProfile: capacityProfile,
                            transaction: transaction, sql: sql,
                            makeIdentifiers: { date in try identifiers.make(at: date) }, now: now,
                            savepoint: "v2_message_recovery_body_\(index)",
                            authorizationPreparation: authorizationPreparations[self.operationKey(identity: identity)],
                            isOperationBatch: true, acceptanceRejection: rejection)
                        deferred.append(recovered.0)
                    } else if case .receipt(let receipt) = results[index] {
                        try await self.persist(receipt, domain: command.command.fingerprint, sql: sql)
                        deferred.append(.receipt(receipt))
                    } else {
                        deferred.append(results[index])
                    }
                }
                return (deferred, Array(repeating: nil, count: deferred.count))
            }
            return (results, accepted)
        }
        let newlyAccepted = committed.1.compactMap { $0 }
        if !newlyAccepted.isEmpty { committedMessageObserver?.observeCommittedMessages(newlyAccepted) }
        return committed.0.map(V2RoomMessagingResult.sendOperation)
    }

    private func processSubmission(
        _ command: V2MessageSendOperationCommand,
        identity: V2OperationIdentity,
        fingerprint: V2OperationFingerprint,
        token: V2RoomActivationToken,
        capacityProfile: V2CapacityProfile,
        transaction: any Database,
        sql: any SQLDatabase,
        makeIdentifiers: @Sendable (Date) throws -> V2AcceptanceIdentifiers,
        now: @Sendable () -> Date,
        savepoint: String,
        authorizationPreparation: BatchAuthorizationPreparation? = nil,
        isOperationBatch: Bool = false,
        priorShardAdmissionReservations: [ShardAdmissionReservation] = [],
        acceptanceRejection: LateShardAdmissionRejection? = nil
    ) async throws -> (V2MessageSendOperationRecoveryResult, V2SendMessageOutcome?, ShardAdmissionReservation?) {
        if let result = try await existing(identity: identity, fingerprint: fingerprint,
            domain: command.command.fingerprint, sql: sql) { return (result, nil, nil) }
        let resolvedAt = now(), milliseconds = try timestamp(resolvedAt)
        guard command.firstSubmissionDeadlineMilliseconds > milliseconds,
              command.firstSubmissionDeadlineMilliseconds - milliseconds <= 86_400_000 else {
            return (.receipt(try await persist(identity: identity, fingerprint: fingerprint,
                domain: command.command.fingerprint, outcome: .rejected(.expiredUnsubmitted), now: resolvedAt, sql: sql)), nil, nil)
        }
        try await sql.raw("SAVEPOINT \(savepoint)").run()
        let outcome: V2SendMessageOutcome
        var shardAdmissionReservation: ShardAdmissionReservation?
        do {
            switch authorizationPreparation {
            case .failed(.identityConflict):
                try await rollbackBody(sql, savepoint: savepoint)
                return (.fingerprintConflict, nil, nil)
            case .failed(.actorNotEligible):
                throw V2RoomWriteStoreError.actorNotEligible
            case .failed(.roomNotFound):
                throw V2RoomWriteStoreError.roomNotFound
            case .prepared(let preparedWrites):
                let scopedWrites = try preparedWrites.usingWorkloadDatabase(transaction).usingOperationTransaction()
                    .usingActivationScope(.init(tokens: [token]))
                if isOperationBatch {
                    let accepted = try await scopedWrites.acceptForOperationBatch(command: command.command,
                        capacityProfile: capacityProfile, identifiers: try makeIdentifiers(resolvedAt), now: resolvedAt,
                        priorShardAdmissionReservations: priorShardAdmissionReservations)
                    outcome = accepted.outcome
                    shardAdmissionReservation = accepted.shardAdmissionReservation
                } else {
                    outcome = try await scopedWrites.accept(command: command.command,
                        capacityProfile: capacityProfile, identifiers: try makeIdentifiers(resolvedAt), now: resolvedAt)
                }
            case nil:
                // A missing preparation is expected only for a replay or an
                // expired command, both handled above.
                throw V2MessageOperationValidationError.invalidReceipt
            }
        } catch V2DirectAuthorizationIntentError.identityConflict {
            // A scoped grant carries a control-side fingerprint committed before
            // this owner transaction. Unlike a rolled-back receipt, that binding
            // still supports a conflict during batch recovery.
            try await rollbackBody(sql, savepoint: savepoint)
            return (.fingerprintConflict, nil, nil)
        } catch V2RoomWriteStoreError.strangerMessageLimitReached {
            try await rollbackBody(sql, savepoint: savepoint)
            return (.deferred(try .init(identity: identity, fingerprint: fingerprint, reason: .rateLimited,
                retryAfterMilliseconds: await quotaRetryAfter(room: token.roomID, actor: identity.accountID,
                    now: resolvedAt, sql: sql))), nil, nil)
        } catch V2RoomWriteStoreError.actorNotEligible, V2RoomWriteStoreError.actorMuted, V2RoomWriteStoreError.roomFrozen {
            try await rollbackBody(sql, savepoint: savepoint)
            return (.receipt(try await persist(identity: identity, fingerprint: fingerprint,
                domain: command.command.fingerprint, outcome: .rejected(.permissionDenied), now: resolvedAt, sql: sql)), nil, nil)
        } catch V2RoomWriteStoreError.roomNotFound {
            try await rollbackBody(sql, savepoint: savepoint)
            return (.receipt(try await persist(identity: identity, fingerprint: fingerprint,
                domain: command.command.fingerprint, outcome: .rejected(.roomNotFound), now: resolvedAt, sql: sql)), nil, nil)
        }
        if case .accepted = outcome, let acceptanceRejection {
            // Recovery may find a rolled-back conflict is now a fresh command.
            // Its new acceptance cannot commit after the batch failed admission.
            try await rollbackBody(sql, savepoint: savepoint)
            return (try admissionDeferred(identity: identity, fingerprint: fingerprint,
                rejection: acceptanceRejection), nil, nil)
        }
        try await sql.raw("RELEASE SAVEPOINT \(savepoint)").run()
        if let accepted = outcome.acceptanceReceipt {
            let newlyAccepted: V2SendMessageOutcome? = { if case .accepted = outcome { return outcome }; return nil }()
            return (.receipt(try await persist(identity: identity, fingerprint: fingerprint,
                domain: command.command.fingerprint,
                outcome: .accepted(.init(messageID: accepted.messageID, roomSequence: accepted.roomSequence)),
                now: resolvedAt, sql: sql)), newlyAccepted, shardAdmissionReservation)
        }
        switch outcome {
        case .denied:
            return (.receipt(try await persist(identity: identity, fingerprint: fingerprint,
                domain: command.command.fingerprint, outcome: .rejected(.directPolicyDenied), now: resolvedAt, sql: sql)), nil, nil)
        case .idempotencyConflict: return (.fingerprintConflict, nil, nil)
        case .rateLimited(let seconds):
            return (.deferred(try .init(identity: identity, fingerprint: fingerprint, reason: .rateLimited,
                retryAfterMilliseconds: UInt64(min(86_400, max(1, seconds))) * 1000)), nil, nil)
        case .unavailable:
            return (.deferred(try .init(identity: identity, fingerprint: fingerprint,
                reason: .admissionUnavailable, retryAfterMilliseconds: nil)), nil, nil)
        case .accepted, .idempotent: throw V2MessageOperationValidationError.invalidReceipt
        }
    }

    private func requiresDomainRecovery(_ result: V2MessageSendOperationRecoveryResult) -> Bool {
        switch result {
        case .fingerprintConflict: return true
        case .receipt(let receipt): return receipt.outcome == .rejected(.directPolicyDenied)
        default: return false
        }
    }

    private func admissionDeferred(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
                                   rejection: LateShardAdmissionRejection) throws -> V2MessageSendOperationRecoveryResult {
        switch rejection {
        case .rateLimited(let seconds):
            return .deferred(try .init(identity: identity, fingerprint: fingerprint,
                reason: .rateLimited, retryAfterMilliseconds: UInt64(min(86_400, max(1, seconds))) * 1000))
        case .unavailable:
            return .deferred(try .init(identity: identity, fingerprint: fingerprint,
                reason: .admissionUnavailable, retryAfterMilliseconds: nil))
        }
    }

    private func prepareBatchAuthorizations(
        _ commands: [V2MessageSendOperationCommand],
        now: @Sendable () -> Date
    ) async throws -> [String: BatchAuthorizationPreparation] {
        // Validate the whole batch before any receipt lookup or control intent.
        for command in commands { _ = try persistenceKey(identity: command.identity) }
        guard let sql = database as? any SQLDatabase else { throw V2MessageOperationValidationError.invalidReceipt }
        var candidates: [(String, V2MessageSendOperationCommand)] = []
        var seen = Set<String>()
        for command in commands {
            let identity = try command.identity
            let key = operationKey(identity: identity)
            guard seen.insert(key).inserted else { continue }
            // An already completed operation always replays before current
            // permissions are consulted. The owner transaction repeats this
            // lookup after obtaining the operation locks.
            if try await existing(identity: identity, fingerprint: command.fingerprint,
                                  domain: command.command.fingerprint, sql: sql) != nil { continue }
            let currentTime = now(), currentMilliseconds = try timestamp(currentTime)
            guard command.firstSubmissionDeadlineMilliseconds > currentMilliseconds,
                  command.firstSubmissionDeadlineMilliseconds - currentMilliseconds <= 86_400_000 else { continue }
            candidates.append((key, command))
        }

        var preparations: [String: BatchAuthorizationPreparation] = [:]
        for start in stride(from: 0, to: candidates.count, by: 128) {
            let end = min(start + 128, candidates.count)
            let slice = Array(candidates[start..<end])
            do {
                let scoped = try await writes.prepareOperationBatchAuthorizations(
                    commands: slice.map { $0.1.command }, now: now())
                for (key, command) in slice {
                    preparations[key] = .prepared(try scoped.operationBatchScopedStore(for: command.command))
                }
            } catch let failure as V2DirectAuthorizationIntentError where failure == .identityConflict {
                // A batch preflight error may be specific to one command
                // (for example a malformed direct-room route). Isolate it so
                // each item retains the existing per-operation result.
                for (key, command) in slice {
                    do {
                        let scoped = try await writes.prepareOperationBatchAuthorization(command: command.command, now: now())
                        preparations[key] = .prepared(scoped)
                    } catch let failure as V2DirectAuthorizationIntentError where failure == .identityConflict {
                        preparations[key] = .failed(.identityConflict)
                    } catch V2RoomWriteStoreError.actorNotEligible {
                        preparations[key] = .failed(.actorNotEligible)
                    } catch V2RoomWriteStoreError.roomNotFound {
                        preparations[key] = .failed(.roomNotFound)
                    } catch {
                        throw error
                    }
                }
            } catch V2RoomWriteStoreError.actorNotEligible, V2RoomWriteStoreError.roomNotFound {
                // These are item-level domain failures. Isolate them while
                // allowing infrastructure/database failures to fail the call.
                for (key, command) in slice {
                    do {
                        let scoped = try await writes.prepareOperationBatchAuthorization(command: command.command, now: now())
                        preparations[key] = .prepared(scoped)
                    } catch let failure as V2DirectAuthorizationIntentError where failure == .identityConflict {
                        preparations[key] = .failed(.identityConflict)
                    } catch V2RoomWriteStoreError.actorNotEligible {
                        preparations[key] = .failed(.actorNotEligible)
                    } catch V2RoomWriteStoreError.roomNotFound {
                        preparations[key] = .failed(.roomNotFound)
                    } catch {
                        throw error
                    }
                }
            }
        }
        return preparations
    }

    private func operationKey(identity: V2OperationIdentity) -> String {
        "\(identity.accountID.uuidValue?.uuidString.lowercased() ?? ""):\(identity.operation.rawOperationID.lowercased())"
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
        let sql = try await lockOperation(identity: identity, token: token, database: database)
        try await v2RequireRoomActivation(token:token,sql:sql)
        return sql
    }
    private func lockOperation(identity:V2OperationIdentity,token:V2RoomActivationToken,database:any Database) async throws -> any SQLDatabase {
        let key = try persistenceKey(identity: identity)
        guard key.room == token.roomID.uuidValue, let sql=database as? any SQLDatabase else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended('v2-message-operation:' || \(bind:key.room)::text || ':' || \(bind:key.actor)::text || ':' || \(bind:key.operation)::text,0))").run()
        return sql
    }
    private func persistenceKey(identity: V2OperationIdentity) throws -> (room: UUID, actor: UUID, operation: UUID) {
        guard identity.kind == .sendMessage, case .room(let room) = identity.scope,
              let roomUUID = room.uuidValue, let actor = identity.accountID.uuidValue,
              let operation = UUID(uuidString: identity.operation.rawOperationID) else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        return (roomUUID, actor, operation)
    }
    private func existing(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,domain:V2SendMessageFingerprint,sql:any SQLDatabase) async throws -> V2MessageSendOperationRecoveryResult? {
        let key = try persistenceKey(identity: identity)
        guard let row=try await sql.raw("SELECT receipt::text AS receipt,domain_fingerprint FROM im_v2.message_send_operation_receipts WHERE room_id=\(bind:key.room) AND actor_user_id=\(bind:key.actor) AND operation_id=\(bind:key.operation)").first(decoding:SendReceiptRow.self) else { return nil }
        let receipt=try JSONDecoder().decode(V2MessageSendOperationReceipt.self,from:Data(row.receipt.utf8))
        guard receipt.validates(identity:identity,fingerprint:fingerprint),row.domainFingerprint==domain.digest else { return .fingerprintConflict }
        return .receipt(receipt)
    }
    private func persist(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,domain:V2SendMessageFingerprint,outcome:V2MessageSendOperationTerminalOutcome,now:Date,sql:any SQLDatabase) async throws -> V2MessageSendOperationReceipt {
        guard case .room = identity.scope else { throw V2MessageOperationValidationError.invalidKind }
        let receipt=try V2MessageSendOperationReceipt(identity:identity,fingerprint:fingerprint,outcome:outcome,resolvedAtMilliseconds:timestamp(now))
        try await persist(receipt, domain: domain, sql: sql)
        return receipt
    }
    private func persist(_ receipt: V2MessageSendOperationReceipt, domain: V2SendMessageFingerprint, sql: any SQLDatabase) async throws {
        let key = try persistenceKey(identity: receipt.identity)
        let actor = key.actor, operation = key.operation, roomUUID = key.room
        let resolvedAt = Date(timeIntervalSince1970: Double(receipt.resolvedAtMilliseconds) / 1000)
        // A negative outcome fences even delayed domain appends using the original v3 lock and close trigger.
        if case .accepted=receipt.outcome {} else {
            try await sql.raw("INSERT INTO im_v2.message_operation_closures(room_id,sender_user_id,client_message_id,fingerprint_version,request_fingerprint,closed_at) VALUES(\(bind:roomUUID),\(bind:actor),\(bind:operation),3,\(bind:domain.digest),\(bind:resolvedAt))").run()
        }
        let payload=String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
        try await sql.raw("""
            INSERT INTO im_v2.message_send_operation_receipts(room_id,actor_user_id,operation_id,fingerprint_version,request_fingerprint,domain_fingerprint,receipt,resolved_at)
            VALUES(\(bind:roomUUID),\(bind:actor),\(bind:operation),1,\(bind:receipt.fingerprint.digest),\(bind:domain.digest),\(bind:payload)::jsonb,\(bind:resolvedAt))
            """).run()
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
    private func rollbackBody(_ sql:any SQLDatabase, savepoint:String) async throws {
        try await sql.raw("ROLLBACK TO SAVEPOINT \(savepoint)").run()
        try await sql.raw("RELEASE SAVEPOINT \(savepoint)").run()
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

private enum BatchAuthorizationFailure: Sendable {
    case identityConflict
    case actorNotEligible
    case roomNotFound
}

private enum BatchAuthorizationPreparation: Sendable {
    case prepared(PostgresV2RoomWriteStore)
    case failed(BatchAuthorizationFailure)
}

private struct QuotaWindow:Decodable { let startedAt:Date;enum CodingKeys:String,CodingKey { case startedAt="started_at" } }
