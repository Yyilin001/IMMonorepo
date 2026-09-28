import Foundation
import GRDB
import IMV2Core

public struct V2GroupCreationPending:Equatable,Sendable {
    public let work:V2OperationWork
    public let intent:V2GroupCreationIntent
    public let members:[UserID]
    public let receipt:V2GroupCreationReceipt?
    public let progress:V2GroupCreationProgress?
    public let cancellationRequested:Bool
}

extension GRDBV2LocalSyncStore {
    static let groupCreationWorkSchemaSQL="""
        CREATE TABLE v2_group_creation_operations (
            work_id TEXT PRIMARY KEY REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            intent BLOB NOT NULL CHECK(length(intent)<=4096),
            members BLOB NOT NULL CHECK(length(members)<=8388608),
            progress BLOB CHECK(length(progress)<=4096),
            cancellation_requested INTEGER NOT NULL DEFAULT 0 CHECK(cancellation_requested IN (0,1))
        );
        """
    func enqueueGroupCreationOperation(_ intent:V2GroupCreationIntent,members:[UserID],now:Date=Date()) throws -> UUID {
        let canonical=try V2GroupCreationAudience.canonical(members,actorUserID:intent.identity.accountID)
        guard canonical==members,members.count==intent.initialMemberCount,
              try V2GroupCreationAudience.digest(members)==intent.audienceDigest else { throw V2GroupCreationValidationError.invalidIntent }
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(intent),audience=try encoder.encode(members)
        guard bytes.count<=4096,audience.count<=8_388_608 else { throw V2OperationWorkError.invalidRecord }
        return try databasePool.write { db in
            if let existing=try String.fetchOne(db,sql:"SELECT work_id FROM v2_operation_work WHERE identity_key=?",arguments:[intent.identity.storageKey]) {
                guard let id=UUID(uuidString:existing) else { throw V2OperationWorkError.invalidRecord }
                let saved=try Self.requireGroupCreation(id,db:db)
                guard saved.intent==intent,saved.members==members else { throw V2OperationWorkError.identityConflict }
                return id
            }
            if let active=try String.fetchOne(db,sql:"SELECT w.work_id FROM v2_operation_work w JOIN v2_group_creation_operations g USING(work_id) WHERE w.scheduling_state<>'finished' ORDER BY w.local_sequence LIMIT 1") {
                guard let id=UUID(uuidString:active) else { throw V2OperationWorkError.invalidRecord }
                let saved=try Self.requireGroupCreation(id,db:db)
                guard saved.intent.title==intent.title,saved.intent.capacityClass==intent.capacityClass,saved.members==members,!saved.cancellationRequested else { throw V2OperationWorkError.invalidTransition }
                return id
            }
            let id=UUID()
            _ = try Self.insertOperationWork(.init(id:id,intentID:id,identity:intent.identity,fingerprint:intent.fingerprint,
                orderingKey:"group-create:"+intent.identity.storageKey,payloadBytes:Int64(bytes.count+audience.count+4096+65536),
                admissionDeadline:Date(timeIntervalSince1970:Double(intent.firstSubmissionDeadlineMilliseconds)/1000)),now:now,limits:.init(),db:db)
            try db.execute(sql:"INSERT INTO v2_group_creation_operations(work_id,intent,members) VALUES(?,?,?)",arguments:[id.uuidString,bytes,audience])
            return id
        }
    }
    static func requireGroupCreation(_ id:UUID,db:Database) throws -> V2GroupCreationPending {
        guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_group_creation_operations WHERE work_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
        let intent=try JSONDecoder().decode(V2GroupCreationIntent.self,from:row["intent"])
        let members=try JSONDecoder().decode([UserID].self,from:row["members"])
        let work=try requireOperationWork(id,db:db)
        let progress=try (row["progress"] as Data?).map { try JSONDecoder().decode(V2GroupCreationProgress.self,from:$0) }
        guard work.identity==intent.identity,try work.fingerprint==intent.fingerprint,
            members.count==intent.initialMemberCount,try V2GroupCreationAudience.canonical(members,actorUserID:intent.identity.accountID)==members,
            try V2GroupCreationAudience.digest(members)==intent.audienceDigest,
            progress.map({$0.validates(intent:intent,canonicalMembers:members)}) ?? true else { throw V2OperationWorkError.identityConflict }
        let receipt=try Data.fetchOne(db,sql:"SELECT terminal_receipt FROM v2_operation_work WHERE work_id=?",arguments:[id.uuidString]).map { try JSONDecoder().decode(V2GroupCreationReceipt.self,from:$0) }
        guard receipt.map({$0.validates(intent:intent)}) ?? true else { throw V2GroupCreationValidationError.invalidReceipt }
        return .init(work:work,intent:intent,members:members,receipt:receipt,progress:progress,cancellationRequested:row["cancellation_requested"])
    }
    func latestGroupCreation() throws -> V2GroupCreationPending? {
        try databasePool.read { db in
            guard let raw=try String.fetchOne(db,sql:"SELECT w.work_id FROM v2_operation_work w JOIN v2_group_creation_operations g USING(work_id) ORDER BY (w.scheduling_state='finished'),w.local_sequence DESC LIMIT 1"),let id=UUID(uuidString:raw) else { return nil }
            return try Self.requireGroupCreation(id,db:db)
        }
    }
    func groupCreationPending(id:UUID) throws -> V2GroupCreationPending {
        try databasePool.read { try Self.requireGroupCreation(id,db:$0) }
    }
    func saveGroupCreationProgress(_ progress:V2GroupCreationProgress,claim:V2OperationWorkClaim,nextAction:V2OperationWorkAction,now:Date=Date()) throws {
        let id=claim.work.id,time=try Self.commandRetryTimestamp(now)
        try databasePool.write { db in
            let pending=try Self.requireGroupCreation(id,db:db)
            try Self.requireOperationClaim(claim,db:db)
            guard progress.validates(intent:pending.intent,canonicalMembers:pending.members),
                pending.progress.map({$0.roomID==progress.roomID && $0.acceptedMemberCount<=progress.acceptedMemberCount && $0.copiedMemberCount<=progress.copiedMemberCount && ($0.phase != .finalizing || progress.phase == .finalizing)}) ?? true else { throw V2GroupCreationValidationError.invalidProgress }
            let bytes=try JSONEncoder().encode(progress)
            guard bytes.count<=4096 else { throw V2OperationWorkError.invalidRecord }
            try db.execute(sql:"UPDATE v2_group_creation_operations SET progress=? WHERE work_id=?",arguments:[bytes,id.uuidString])
            let advanced=pending.progress.map { $0.acceptedMemberCount<progress.acceptedMemberCount || $0.copiedMemberCount<progress.copiedMemberCount || $0.phase != progress.phase } ?? true
            // Only verified forward progress earns a fresh per-step retry budget.
            // Repeated identical polls never replenish attempts or extend the intent deadline.
            try db.execute(sql:"""
                UPDATE v2_operation_work SET execution_state=?,scheduling_state='backingOff',
                    next_action_kind=?,next_action_at=?,last_error_code=NULL,
                    submission_round_attempts=CASE WHEN ? THEN 0 ELSE submission_round_attempts END,
                    reconciliation_round_attempts=CASE WHEN ? THEN 0 ELSE reconciliation_round_attempts END,
                    submission_round_deadline=CASE WHEN ? THEN NULL ELSE submission_round_deadline END,
                    reconciliation_round_deadline=CASE WHEN ? THEN NULL ELSE reconciliation_round_deadline END,
                    claim_id=NULL,claim_owner_id=NULL,claim_until=NULL,work_revision=work_revision+1 WHERE work_id=?
                """,arguments:[progress.phase == .finalizing ? "processing" : "awaitingConfirmation",nextAction.rawValue,time+(advanced ? 0:1),advanced,advanced,advanced,advanced,id.uuidString])
        }
    }
    func requestGroupCreationCancellation(id:UUID,accountID:UserID) throws {
        try databasePool.write { db in
            let pending=try Self.requireGroupCreation(id,db:db)
            guard pending.work.identity.accountID==accountID,!pending.work.execution.isTerminal else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql:"UPDATE v2_group_creation_operations SET cancellation_requested=1 WHERE work_id=?",arguments:[id.uuidString])
        }
    }
    func completeGroupCreation(_ receipt:V2GroupCreationReceipt,intent:V2GroupCreationIntent,now:Date=Date()) throws {
        guard receipt.validates(intent:intent) else { throw V2GroupCreationValidationError.invalidReceipt }
        let state:V2OperationExecutionState
        switch receipt.outcome { case .created:state = .committed;case .closed:state = .closed;case .rejected:state = .rejected }
        try databasePool.write { db in
            guard let raw=try String.fetchOne(db,sql:"SELECT work_id FROM v2_operation_work WHERE identity_key=?",arguments:[intent.identity.storageKey]),let id=UUID(uuidString:raw) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.requireGroupCreation(id,db:db)
            guard pending.intent==intent else { throw V2OperationWorkError.identityConflict }
            if case .created(let room,_,_,_)=receipt.outcome,let progress=pending.progress,progress.roomID != room { throw V2GroupCreationValidationError.invalidReceipt }
            try Self.completeOperationWork(.init(identity:receipt.identity,fingerprint:receipt.fingerprint,state:state,receipt:receipt),now:now,db:db)
        }
    }
}

extension GRDBV2LocalSyncStore {
    nonisolated func groupCreationUpdates() -> AsyncThrowingStream<Void,any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"SELECT w.work_id,w.work_revision,g.cancellation_requested,g.progress FROM v2_operation_work w JOIN v2_group_creation_operations g USING(work_id) ORDER BY w.local_sequence DESC LIMIT 2000").map { row -> String in
                            let id:String=row["work_id"],revision:Int64=row["work_revision"],cancelled:Bool=row["cancellation_requested"]
                            return id+":"+String(revision)+":"+String(cancelled)
                        }
                    }
                    for try await _ in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(()) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
}
