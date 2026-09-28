import Foundation
import GRDB
import IMV2Core

public protocol V2ForwardPlanOperationClient:Sendable {
    func submit(_ command:V2ForwardPlanOperationCommand) async throws -> V2ForwardPlanRecoveryResult
    func recover(_ command:V2ForwardPlanOperationCommand,action:V2ForwardPlanRecoveryAction) async throws -> V2ForwardPlanRecoveryResult
}
public enum V2ForwardPlanAdmissionError:Error,Sendable { case confirmationRequired }
public struct V2ForwardPlanSnapshot:Equatable,Sendable {
    public let work:V2OperationWork
    public let command:V2ForwardPlanOperationCommand
    public let progress:V2ForwardPlanProgress?
    public let cancellationRequested:Bool
    public var succeeded:Int { progress?.children.reduce(0) { total,child in
        guard case .resolved(let receipt)=child.state,case .completed(let items)=receipt.outcome else { return total }
        return total+items.filter { if case .accepted = $0.outcome { true } else { false } }.count
    } ?? 0 }
    public var rejected:Int { progress?.children.reduce(0) { total,child in
        guard case .resolved(let receipt)=child.state,case .completed(let items)=receipt.outcome else { return total }
        return total+items.filter { if case .rejected = $0.outcome { true } else { false } }.count
    } ?? 0 }
    public var cancelled:Int {
        if work.execution == .cancelledLocally { return command.command.sources.count*command.command.targetRoomIDs.count }
        return progress?.children.reduce(0) { total,child in
        guard case .resolved(let receipt)=child.state,case .cancelledBeforeStart=receipt.outcome else { return total }
        return total+((try? command.childCommand(index:child.index).sources.count) ?? 0)
    } ?? 0 }
    public var unresolved:Int { work.execution == .expiredUnsubmitted ? 0 : command.command.sources.count*command.command.targetRoomIDs.count-succeeded-rejected-cancelled }
}
extension GRDBV2LocalSyncStore {
    static let forwardPlanWorkSchemaSQL="""
        CREATE TABLE v2_forward_plan_operations (
            work_id TEXT PRIMARY KEY REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            command BLOB NOT NULL CHECK(length(command)<=65536),source_room_ids TEXT NOT NULL,
            progress BLOB CHECK(length(progress)<=1048576),cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK(cancel_requested IN (0,1))
        );
        """
    @discardableResult public func enqueueForwardPlanOperation(_ command:V2ForwardPlanOperationCommand,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID {
        let identity=try command.identity,fingerprint=try command.fingerprint,encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(command)
        guard bytes.count<=65_536 else { throw V2OperationWorkError.invalidRecord }
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==command.actorUserID.rawValue else { throw V2OperationWorkError.accountMismatch }
            if let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_operation_work WHERE identity_key=?",arguments:[identity.storageKey]) {
                let existing=try Self.decodeOperationWork(row)
                guard existing.identity==identity,existing.fingerprint==fingerprint else { throw V2OperationWorkError.identityConflict }
                return existing.id
            }
            for row in try Row.fetchAll(db,sql:"SELECT f.command,w.work_id FROM v2_forward_plan_operations f JOIN v2_operation_work w USING(work_id) WHERE w.scheduling_state<>'finished' AND w.account_id=?",arguments:[command.actorUserID.rawValue]) {
                let original=try JSONDecoder().decode(V2ForwardPlanOperationCommand.self,from:row["command"])
                if original.command.sources==command.command.sources && original.command.targetRoomIDs==command.command.targetRoomIDs {
                    guard let id=UUID(uuidString:row["work_id"]) else { throw V2OperationWorkError.invalidRecord };return id
                }
                // An unresolved overlapping batch cannot be rebuilt with a fresh parent ID.
                if !Set(original.command.sources.map(\.messageID)).isDisjoint(with:command.command.sources.map(\.messageID)),
                    !Set(original.command.targetRoomIDs).isDisjoint(with:command.command.targetRoomIDs) { throw V2ForwardPlanAdmissionError.confirmationRequired }
            }
            let id=UUID()
            // Reserve the 1 MiB domain proof and 64 KiB public terminal receipt before any I/O.
            // The generic processing helper changes scheduling only; it stores no second proof.
            _ = try Self.insertOperationWork(.init(id:id,intentID:id,identity:identity,fingerprint:fingerprint,orderingKey:"forward:"+command.operationID.rawValue,payloadBytes:Int64(bytes.count)+1_048_576+65_536,admissionDeadline:Date(timeIntervalSince1970:Double(command.firstSubmissionDeadlineMilliseconds)/1_000)),now:now,limits:limits,db:db)
            let rooms=String(decoding:try encoder.encode(Set(command.command.sources.map{$0.roomID.rawValue}).sorted()),as:UTF8.self)
            try db.execute(sql:"INSERT INTO v2_forward_plan_operations(work_id,command,source_room_ids) VALUES(?,?,?)",arguments:[id.uuidString,bytes,rooms])
            return id
        }
    }
    func forwardPlanSnapshot(workID:UUID) throws -> V2ForwardPlanSnapshot { try databasePool.read { try Self.readForwardPlanSnapshot(workID:workID,db:$0) } }
    static func readForwardPlanSnapshot(workID:UUID,db:Database) throws -> V2ForwardPlanSnapshot {
        let work=try requireOperationWork(workID,db:db)
        guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_forward_plan_operations WHERE work_id=?",arguments:[workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
        let command=try JSONDecoder().decode(V2ForwardPlanOperationCommand.self,from:row["command"])
        guard try command.identity==work.identity,try command.fingerprint==work.fingerprint else { throw V2OperationWorkError.identityConflict }
        let progress=try (row["progress"] as Data?).map { try JSONDecoder().decode(V2ForwardPlanProgress.self,from:$0) }
        guard progress?.validates(command:command) ?? true else { throw V2OperationWorkError.identityConflict }
        return .init(work:work,command:command,progress:progress,cancellationRequested:row["cancel_requested"] as Bool)
    }
    func recordForwardPlanProgress(_ progress:V2ForwardPlanProgress,claim:V2OperationWorkClaim,until:Date,scheduling:V2OperationSchedulingState) throws {
        try databasePool.write { db in
            let snapshot=try Self.readForwardPlanSnapshot(workID:claim.work.id,db:db)
            guard progress.validates(command:snapshot.command),snapshot.progress.map({progress.canAdvance(from:$0,command:snapshot.command)}) ?? true else { throw V2ForwardPlanValidationError.invalidProgress }
            let verified=try V2VerifiedOperationProgress(identity:progress.identity,fingerprint:progress.fingerprint,proof:progress)
            guard try Self.recordProcessingProgress(verified,claim:claim,until:until,scheduling:scheduling,db:db) else { return }
            try db.execute(sql:"UPDATE v2_forward_plan_operations SET progress=? WHERE work_id=?",arguments:[verified.canonicalProof,claim.work.id.uuidString])
        }
    }
    func completeForwardPlan(_ result:V2ForwardPlanResolvedResult,workID:UUID,now:Date=Date()) throws {
        try databasePool.write { db in
            let snapshot=try Self.readForwardPlanSnapshot(workID:workID,db:db)
            guard result.validates(command:snapshot.command),snapshot.progress.map({result.progress.canAdvance(from:$0,command:snapshot.command)}) ?? true else { throw V2ForwardPlanValidationError.invalidReceipt }
            let state:V2OperationExecutionState
            switch result.receipt.outcome { case .completed:state = .committed;case .closedBeforeStart:state = .closed;case .rejected:state = .rejected }
            let proof=try V2VerifiedOperationProgress(identity:result.progress.identity,fingerprint:result.progress.fingerprint,proof:result.progress)
            try Self.completeOperationWork(.init(identity:result.receipt.identity,fingerprint:result.receipt.fingerprint,state:state,receipt:result.receipt),now:now,db:db)
            try db.execute(sql:"UPDATE v2_forward_plan_operations SET progress=? WHERE work_id=?",arguments:[proof.canonicalProof,workID.uuidString])
        }
    }
    public func requestForwardPlanCancellation(workID:UUID,accountID:UserID,now:Date=Date()) throws {
        try databasePool.write { db in
            let work=try Self.requireOperationWork(workID,db:db)
            guard work.identity.accountID==accountID,work.identity.kind == .forwardMessage else { throw V2OperationWorkError.accountMismatch }
            guard !work.execution.isTerminal else { return }
            try db.execute(sql:"UPDATE v2_forward_plan_operations SET cancel_requested=1 WHERE work_id=?",arguments:[workID.uuidString])
            if !work.submissionStarted {
                try Self.finishLocalOperation(workID,state:.cancelledLocally,now:now.timeIntervalSince1970,db:db)
            } else if work.scheduling != .claimed {
                // Explicit cancellation authorizes a bounded confirmation round; it never renews first submission time.
                try db.execute(sql:"UPDATE v2_operation_work SET scheduling_state='ready',next_action_kind='reconcile',next_action_at=MAX(next_action_at,?),submission_round_attempts=0,reconciliation_round_attempts=0,submission_round_deadline=NULL,reconciliation_round_deadline=NULL,work_revision=work_revision+1 WHERE work_id=?",arguments:[now.timeIntervalSince1970,workID.uuidString])
            }
        }
    }
    public nonisolated func forwardPlanUpdates(sourceRoomID:RoomID) -> AsyncThrowingStream<[V2ForwardPlanSnapshot],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try String.fetchAll(db,sql:"SELECT f.work_id FROM v2_forward_plan_operations f JOIN v2_operation_work w USING(work_id) WHERE EXISTS(SELECT 1 FROM json_each(f.source_room_ids) WHERE value=?) ORDER BY CASE WHEN w.scheduling_state='finished' THEN 1 ELSE 0 END,w.local_sequence DESC LIMIT 2200",arguments:[sourceRoomID.rawValue]).map { value in
                            guard let id=UUID(uuidString:value) else { throw V2OperationWorkError.invalidRecord };return try Self.readForwardPlanSnapshot(workID:id,db:db)
                        }
                    }.removeDuplicates()
                    for try await snapshots in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(snapshots) };continuation.finish()
                } catch { continuation.finish(throwing:error) }
            };continuation.onTermination={ _ in task.cancel() }
        }
    }
}

public actor V2ForwardPlanOperationService {
    private let accountID:UserID,store:GRDBV2LocalSyncStore
    private let client:any V2ForwardPlanOperationClient
    public init(accountID:UserID,store:GRDBV2LocalSyncStore,client:any V2ForwardPlanOperationClient) { self.accountID=accountID;self.store=store;self.client=client }
    @discardableResult public func enqueue(sources:[V2ForwardMessageReference],targetRoomIDs:[RoomID]) async throws -> UUID {
        try Task.checkCancellation()
        let command=try V2ForwardPlanOperationCommand(actorUserID:accountID,command:.init(operationID:.init(uuid:UUID()),sources:sources,targetRoomIDs:targetRoomIDs),firstSubmissionDeadlineMilliseconds:GRDBV2LocalSyncStore.messageSendDeadline(now:Date()))
        return try await store.enqueueForwardPlanOperation(command)
    }
    public func updates(sourceRoomID:RoomID) async -> AsyncThrowingStream<[V2ForwardPlanSnapshot],any Error> { store.forwardPlanUpdates(sourceRoomID:sourceRoomID) }
    public func resumeConfirmation(workID:UUID) async throws {
        let snapshot=try await store.forwardPlanSnapshot(workID:workID)
        guard snapshot.command.actorUserID==accountID else { throw V2OperationWorkError.accountMismatch }
        try await store.retryOperationWorkByUser(id:workID,now:Date())
    }
    public func cancelRemaining(workID:UUID) async throws { try await store.requestForwardPlanCancellation(workID:workID,accountID:accountID) }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,claim.work.identity.kind == .forwardMessage else { throw V2OperationWorkError.accountMismatch }
        let snapshot=try await store.forwardPlanSnapshot(workID:claim.work.id),command=snapshot.command
        do {
            let result:V2ForwardPlanRecoveryResult
            if snapshot.cancellationRequested { result=try await client.recover(command,action:.cancelRemaining) }
            else if claim.action == .submit { result=try await client.submit(command) }
            else { result=try await client.recover(command,action:Date().timeIntervalSince1970*1_000<Double(command.firstSubmissionDeadlineMilliseconds) ? .query : .closeIfUnstarted) }
            switch result {
            case .receipt(let resolved):try await store.completeForwardPlan(resolved,workID:claim.work.id)
            case .processing(let progress):
                let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery
                let deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
                let next=now.addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts))
                let exhausted=claim.work.reconciliationRoundAttempts>=policy.maximumAttempts || next>=deadline
                try await store.recordForwardPlanProgress(progress,claim:claim,until:next,scheduling:exhausted ? .needsAttention : .backingOff)
            case .fingerprintConflict:try await store.deferOperationWork(claim,until:Date(),code:"FORWARD_FINGERPRINT_CONFLICT",scheduling:.needsAttention)
            case .unresolved:
                let next:V2OperationWorkAction=snapshot.progress != nil || Date().timeIntervalSince1970*1_000>=Double(command.firstSubmissionDeadlineMilliseconds) ? .reconcile : .submit
                try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"FORWARD_UNRESOLVED",nextAction:next)
            case .deferred(let hint):
                guard try hint.validates(identity:command.identity,fingerprint:command.fingerprint) else { throw V2OperationWorkError.identityConflict }
                let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,floor=Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1_000)
                let deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
                let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
                try await store.deferOperationWork(claim,until:max(retry ?? now,floor),code:hint.reason == .rateLimited ? "RATE_LIMITED" : "ADMISSION_UNAVAILABLE",scheduling:retry == nil ? .needsAttention : .backingOff)
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"FORWARD_INTERRUPTED");throw CancellationError()
        } catch {
            let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,failure=error as? V2HTTPFailure
            let deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
            let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:failure?.retryAfter)
            let malformed=error is V2OperationWorkError || error is V2ForwardPlanValidationError || (failure.map{[.invalidEndpoint,.invalidResponse,.responseTooLarge].contains($0.kind)} ?? false)
            try await store.deferOperationWork(claim,until:max(retry ?? now,failure?.retryAfter ?? now),code:"FORWARD_CONFIRMATION_REQUIRED",scheduling:malformed || retry == nil ? .needsAttention : .backingOff)
            if error is DatabaseError { throw error }
        }
    }
}
