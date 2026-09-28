import Foundation
import GRDB
import IMV2Core

/// Immutable domain payload; execution, attempts and recovery ownership live only in common work.
public enum V2MessageMutationPayload: Equatable, Codable, Sendable {
    case edit(V2MessageEditOperationCommand)
    case withdraw(V2MessageWithdrawalOperationCommand)

    public var identity: V2OperationIdentity { get throws {
        switch self { case .edit(let command): return try command.identity
        case .withdraw(let command): return try command.identity }
    } }
    public var fingerprint: V2OperationFingerprint { get throws {
        switch self { case .edit(let command): return try command.fingerprint
        case .withdraw(let command): return try command.fingerprint }
    } }
    func validates(_ receipt: V2MessageMutationReceipt) throws -> Bool {
        guard receipt.validates(identity: try identity, fingerprint: try fingerprint) else { return false }
        guard case .committed(let result) = receipt.outcome else { return true }
        switch self {
        case .edit(let command): return result.messageID == command.messageID && result.messageRevision == command.expectedMessageRevision + 1
        case .withdraw(let command): return result.messageID == command.messageID && result.messageRevision == command.expectedMessageRevision + 1
        }
    }
    public var deadlineMilliseconds: UInt64 {
        switch self { case .edit(let command): command.firstSubmissionDeadlineMilliseconds
        case .withdraw(let command): command.firstSubmissionDeadlineMilliseconds }
    }
}
public enum V2MessageMutationAdmissionError:Error,Equatable,Sendable { case confirmationRequired }

public protocol V2MessageMutationOperationClient: Sendable {
    func submit(_ payload: V2MessageMutationPayload) async throws -> V2MessageMutationRecoveryResult
    func recover(_ request: V2MessageMutationRecoveryRequest) async throws -> V2MessageMutationRecoveryResult
}
public struct V2MessageMutationSnapshot: Equatable, Sendable {
    public let work:V2OperationWork
    public let payload:V2MessageMutationPayload
}

extension GRDBV2LocalSyncStore {
    static let messageMutationWorkSchemaSQL = """
        CREATE TABLE v2_message_mutation_operations (
            work_id TEXT PRIMARY KEY REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            room_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            command BLOB NOT NULL CHECK(length(command)>0 AND length(command)<=1048576)
        );
        CREATE INDEX v2_message_mutation_operations_room ON v2_message_mutation_operations(room_id);
        """

    @discardableResult public func enqueueMessageMutation(_ payload: V2MessageMutationPayload,
        now: Date = Date(), limits: V2OperationWorkLimits = .init()) throws -> UUID {
        let identity = try payload.identity, fingerprint = try payload.fingerprint
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(payload)
        guard bytes.count <= 1_048_576, case .message(let room, let message) = identity.scope else {
            throw V2OperationWorkError.invalidRecord
        }
        return try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == identity.accountID.rawValue else {
                throw V2OperationWorkError.accountMismatch
            }
            // Exact identity retries reuse the original frozen command, never a fresh operation.
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_operation_work WHERE identity_key=?", arguments:[identity.storageKey]) {
                let existing=try Self.decodeOperationWork(row)
                guard existing.identity==identity, existing.fingerprint==fingerprint else { throw V2OperationWorkError.identityConflict }
                return existing.id
            }
            for row in try Row.fetchAll(db,sql:"""
                SELECT w.*,m.command FROM v2_message_mutation_operations m JOIN v2_operation_work w USING(work_id)
                WHERE m.room_id=? AND m.message_id=? AND w.operation_kind=? AND w.scheduling_state<>'finished'
                """,arguments:[room.rawValue,message.rawValue,identity.kind.rawValue]) {
                let existing=try Self.decodeOperationWork(row)
                let frozen=try JSONDecoder().decode(V2MessageMutationPayload.self,from:row["command"])
                guard try frozen.identity==existing.identity,try frozen.fingerprint==existing.fingerprint else { throw V2OperationWorkError.identityConflict }
                switch (frozen,payload) {
                case (.edit(let original),.edit(let proposed)) where original.expectedMessageRevision==proposed.expectedMessageRevision:
                    guard original.text==proposed.text else { throw V2MessageMutationAdmissionError.confirmationRequired }
                    return existing.id
                case (.withdraw(let original),.withdraw(let proposed)) where original.expectedMessageRevision==proposed.expectedMessageRevision:
                    return existing.id
                default:break
                }
            }
            let id = UUID()
            try Self.insertOperationWork(.init(id:id,intentID:id,identity:identity,fingerprint:fingerprint,
                orderingKey:"message:" + room.rawValue + ":" + message.rawValue,payloadBytes:Int64(bytes.count),
                admissionDeadline:Date(timeIntervalSince1970:Double(payload.deadlineMilliseconds)/1_000)),now:now,limits:limits,db:db)
            try db.execute(sql:"INSERT INTO v2_message_mutation_operations(work_id,room_id,message_id,command) VALUES(?,?,?,?)",arguments:[id.uuidString,room.rawValue,message.rawValue,bytes])
            return id
        }
    }
    public nonisolated func messageMutationUpdates(roomID:RoomID) -> AsyncThrowingStream<[V2MessageMutationSnapshot],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"""
                            SELECT w.*,m.command,m.message_id,m.room_id FROM v2_message_mutation_operations m
                            JOIN v2_operation_work w ON w.work_id=m.work_id
                            WHERE m.room_id=? AND (w.scheduling_state<>'finished' OR w.execution_state IN ('conflicted','rejected','closed','expiredUnsubmitted'))
                            ORDER BY w.local_sequence DESC LIMIT 200
                            """,arguments:[roomID.rawValue]).map { row in
                                let work=try Self.decodeOperationWork(row)
                                let payload=try JSONDecoder().decode(V2MessageMutationPayload.self,from:row["command"])
                                guard try payload.identity==work.identity,try payload.fingerprint==work.fingerprint,
                                    case .message(let room,let message)=work.identity.scope,
                                    room.rawValue == row["room_id"] as String, message.rawValue == row["message_id"] as String else { throw V2OperationWorkError.identityConflict }
                                return V2MessageMutationSnapshot(work:work,payload:payload)
                            }
                    }.removeDuplicates()
                    for try await values in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(values) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
    func messageMutationPayload(workID: UUID) throws -> V2MessageMutationPayload {
        try databasePool.read { db in
            guard let bytes = try Data.fetchOne(db,sql:"SELECT command FROM v2_message_mutation_operations WHERE work_id=?",arguments:[workID.uuidString]) else {
                throw V2OperationWorkError.invalidRecord
            }
            return try JSONDecoder().decode(V2MessageMutationPayload.self,from:bytes)
        }
    }
    func completeMessageMutation(_ payload: V2MessageMutationPayload, receipt: V2MessageMutationReceipt, now: Date = Date()) throws {
        let identity=try payload.identity, fingerprint=try payload.fingerprint
        guard try payload.validates(receipt) else { throw V2OperationWorkError.identityConflict }
        let state: V2OperationExecutionState
        switch receipt.outcome {
        case .committed: state = .committed
        case .closed: state = .closed
        case .rejected(.revisionConflict): state = .conflicted
        case .rejected: state = .rejected
        }
        try completeOperationWork(.init(identity:identity,fingerprint:fingerprint,state:state,receipt:receipt),now:now)
        // Minimal receipts do not grant a historical body or display lease. Normal room sync owns projection content.
    }
}

/// One bounded domain step per claim. A lost response always reconciles the original identity.
public actor V2MessageMutationOperationService {
    private let accountID: UserID
    private let store: GRDBV2LocalSyncStore
    private let client: any V2MessageMutationOperationClient
    public init(accountID:UserID,store:GRDBV2LocalSyncStore,client:any V2MessageMutationOperationClient) {
        self.accountID=accountID; self.store=store; self.client=client
    }
    public func updates(roomID:RoomID) -> AsyncThrowingStream<[V2MessageMutationSnapshot],any Error> { store.messageMutationUpdates(roomID:roomID) }
    @discardableResult public func enqueueEdit(roomID:RoomID,messageID:MessageID,expectedRevision:UInt64,text:String,now:Date=Date()) async throws -> UUID {
        try Task.checkCancellation()
        let deadline=try submissionDeadline(kind:.editMessage,now:now)
        let command=try V2EditMessageCommand(roomID:roomID,actorUserID:accountID,operationID:.init(UUID().uuidString),
            messageID:messageID,expectedMessageRevision:expectedRevision,text:text,maximumUTF8Bytes:65_536)
        return try await enqueue(.edit(.init(command:command,firstSubmissionDeadlineMilliseconds:deadline)))
    }
    @discardableResult public func enqueueWithdrawal(roomID:RoomID,messageID:MessageID,expectedRevision:UInt64,now:Date=Date()) async throws -> UUID {
        try Task.checkCancellation()
        let deadline=try submissionDeadline(kind:.withdrawMessage,now:now)
        let command=try V2WithdrawMessageCommand(roomID:roomID,actorUserID:accountID,operationID:.init(UUID().uuidString),
            messageID:messageID,expectedMessageRevision:expectedRevision)
        return try await enqueue(.withdraw(.init(command:command,firstSubmissionDeadlineMilliseconds:deadline)))
    }
    private func submissionDeadline(kind:V2OperationKind,now:Date) throws -> UInt64 {
        let milliseconds=now.timeIntervalSince1970*1_000
        guard milliseconds.isFinite,milliseconds>0,milliseconds<Double(Int64.max),
            let window=V2CommandPolicy.registered(for:kind).firstSubmissionWindowMilliseconds,
            UInt64(milliseconds)<=UInt64(Int64.max)-window else { throw V2OperationWorkError.invalidRecord }
        return UInt64(milliseconds)+window
    }
    @discardableResult public func enqueue(_ payload:V2MessageMutationPayload) async throws -> UUID {
        try Task.checkCancellation()
        guard try payload.identity.accountID == accountID else { throw V2OperationWorkError.accountMismatch }
        return try await store.enqueueMessageMutation(payload)
    }
    public func resumeConfirmation(workID:UUID) async throws {
        guard let work=try await store.operationWork(id:workID), work.identity.accountID==accountID,
            [.editMessage,.withdrawMessage].contains(work.identity.kind) else { throw V2OperationWorkError.accountMismatch }
        try await store.retryOperationWorkByUser(id:workID,now:Date())
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID, [.editMessage,.withdrawMessage].contains(claim.work.identity.kind) else {
            throw V2OperationWorkError.accountMismatch
        }
        let payload=try await store.messageMutationPayload(workID:claim.work.id)
        guard try payload.identity==claim.work.identity, try payload.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        do {
            let result:V2MessageMutationRecoveryResult
            if claim.action == .submit { result = try await client.submit(payload) }
            else {
                let deadline=Date(timeIntervalSince1970:Double(payload.deadlineMilliseconds)/1_000)
                result=try await client.recover(.init(identity:claim.work.identity,fingerprint:claim.work.fingerprint,
                    action:Date()>=deadline ? .closeIfAbsent : .query))
            }
            switch result {
            case .receipt(let receipt): try await store.completeMessageMutation(payload,receipt:receipt)
            case .fingerprintConflict:
                try await store.deferOperationWork(claim,until:Date(),code:"MESSAGE_MUTATION_FINGERPRINT_CONFLICT",scheduling:.needsAttention)
            case .deferred(let hint):
                guard hint.validates(identity:claim.work.identity,fingerprint:claim.work.fingerprint) else { throw V2OperationWorkError.identityConflict }
                let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery
                let floor=now.addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1_000)
                let deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
                let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
                try await store.deferOperationWork(claim,until:max(retry ?? now,floor),code:hint.reason == .rateLimited ? "RATE_LIMITED" : "ADMISSION_UNAVAILABLE",scheduling:retry == nil ? .needsAttention : .backingOff)
            case .unresolved:
                // A query may permit another submission while the original immutable admission window remains open.
                let next:V2OperationWorkAction = Date().timeIntervalSince1970*1_000 < Double(payload.deadlineMilliseconds) ? .submit : .reconcile
                try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"MESSAGE_MUTATION_UNRESOLVED",nextAction:next)
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"MESSAGE_MUTATION_INTERRUPTED")
            throw CancellationError()
        } catch {
            let now=Date(), failure=error as? V2HTTPFailure, policy=V2NetworkWorkPolicy.commandRecovery
            let deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
            let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),
                attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:failure?.retryAfter)
            let malformed=error is V2OperationWorkError || error is V2MessageOperationValidationError ||
                (failure.map { [.invalidEndpoint,.invalidResponse,.responseTooLarge].contains($0.kind) } ?? false)
            try await store.deferOperationWork(claim,until:max(retry ?? now,failure?.retryAfter ?? now),code:"MESSAGE_MUTATION_CONFIRMATION_REQUIRED",
                scheduling:malformed || retry == nil ? .needsAttention : .backingOff)
            if error is DatabaseError { throw error }
        }
    }
}
