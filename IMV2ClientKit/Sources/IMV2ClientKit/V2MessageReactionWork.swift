import Foundation
import GRDB
import IMV2Core

public protocol V2MessageReactionOperationClient:Sendable {
    func snapshot(roomID:RoomID,messageID:MessageID,reaction:String) async throws -> V2MessageReactionSnapshot
    func submit(_ command:V2MessageReactionOperationCommand) async throws -> V2MessageReactionRecoveryResult
    func recover(_ request:V2MessageReactionRecoveryRequest) async throws -> V2MessageReactionRecoveryResult
}
public struct V2MessageReactionIntent:Codable,Equatable,Sendable {
    public let id:UUID
    public let roomID:RoomID
    public let actorUserID:UserID
    public let operationID:MessageReactionOperationID
    public let messageID:MessageID
    public let reaction:String
    public let targetState:V2MessageReactionTargetState
    public let deadlineMilliseconds:UInt64
    public func command(revision:UInt64) throws -> V2MessageReactionOperationCommand {
        try .init(command:.init(roomID:roomID,actorUserID:actorUserID,operationID:operationID,messageID:messageID,reaction:reaction,action:targetState == .present ? .add : .remove),expectedReactionRevision:revision,firstSubmissionDeadlineMilliseconds:deadlineMilliseconds)
    }
}
public struct V2MessageReactionPending:Equatable,Sendable {
    public let intent:V2MessageReactionIntent
    public let work:V2OperationWork?
    public let preparationPaused:Bool
    public let expiredUnsubmitted:Bool
}

extension GRDBV2LocalSyncStore {
    static let messageReactionWorkSchemaSQL="""
        CREATE TABLE v2_message_reaction_intents (
            local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            intent_id TEXT NOT NULL UNIQUE,ordering_key TEXT NOT NULL,room_id TEXT NOT NULL,
            payload BLOB NOT NULL CHECK(length(payload)<=65536),payload_bytes INTEGER NOT NULL CHECK(payload_bytes>0),
            deadline REAL NOT NULL,work_id TEXT UNIQUE REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            command BLOB CHECK(length(command)<=65536),local_terminal TEXT CHECK(local_terminal IN ('expiredUnsubmitted','cancelledLocally')),
            preparation_attempts INTEGER NOT NULL DEFAULT 0,preparation_not_before REAL NOT NULL DEFAULT 0,preparation_started_at REAL,preparation_next_at REAL,preparation_error TEXT,
            CHECK((work_id IS NULL)=(command IS NULL)),CHECK(local_terminal IS NULL OR work_id IS NULL)
        );
        CREATE INDEX v2_message_reaction_intents_order ON v2_message_reaction_intents(ordering_key,local_sequence);
        """
    static let nextReactionDraftQuery="""
        SELECT i.* FROM v2_message_reaction_intents i WHERE i.work_id IS NULL AND i.local_terminal IS NULL
            AND i.preparation_next_at IS NOT NULL
            AND NOT EXISTS(SELECT 1 FROM v2_message_reaction_intents p LEFT JOIN v2_operation_work w ON w.work_id=p.work_id
                WHERE p.ordering_key=i.ordering_key AND p.local_sequence<i.local_sequence AND p.local_terminal IS NULL
                AND (p.work_id IS NULL OR w.scheduling_state<>'finished'))
        """
    @discardableResult public func enqueueReactionIntent(accountID:UserID,roomID:RoomID,messageID:MessageID,reaction:String,targetState:V2MessageReactionTargetState,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID {
        let domain=try V2ChangeMessageReactionCommand(roomID:roomID,actorUserID:accountID,operationID:.init(uuid:UUID()),messageID:messageID,reaction:reaction,action:targetState == .present ? .add : .remove)
        let key="reaction:\(roomID.rawValue):\(messageID.rawValue):\(accountID.rawValue):\(domain.reaction)"
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            let existing=try Row.fetchOne(db,sql:"SELECT * FROM v2_message_reaction_intents WHERE ordering_key=? AND work_id IS NULL AND local_terminal IS NULL ORDER BY local_sequence DESC LIMIT 1",arguments:[key])
            let original=try existing.map { try JSONDecoder().decode(V2MessageReactionIntent.self,from:$0["payload"]) }
            let intent=V2MessageReactionIntent(id:original?.id ?? UUID(),roomID:roomID,actorUserID:accountID,operationID:original?.operationID ?? domain.operationID,messageID:messageID,reaction:domain.reaction,targetState:targetState,deadlineMilliseconds:try original?.deadlineMilliseconds ?? Self.messageSendDeadline(now:now))
            let bytes=try encoder.encode(intent),reservation=try encoder.encode(intent.command(revision:UInt64(Int64.max)-1)).count
            try Self.requireOperationCapacity(adding:Int64(reservation),excludingIntent:original?.id,limits:limits,db:db)
            if let original {
                // Coalescing changes only the unfrozen desired state; it does not renew time or automatic attempts.
                try db.execute(sql:"UPDATE v2_message_reaction_intents SET payload=?,payload_bytes=? WHERE intent_id=?",arguments:[bytes,reservation,original.id.uuidString])
            } else {
                try db.execute(sql:"INSERT INTO v2_message_reaction_intents(intent_id,ordering_key,room_id,payload,payload_bytes,deadline,preparation_next_at) VALUES(?,?,?,?,?,?,?)",arguments:[intent.id.uuidString,key,roomID.rawValue,bytes,reservation,Double(intent.deadlineMilliseconds)/1_000,now.timeIntervalSince1970])
            }
            return intent.id
        }
    }
    func nextReactionDraft(now:Date) throws -> V2MessageReactionIntent? {
        try databasePool.read { db in try Row.fetchOne(db,sql:Self.nextReactionDraftQuery+" AND i.preparation_next_at<=? ORDER BY i.local_sequence LIMIT 1",arguments:[now.timeIntervalSince1970]).map { try JSONDecoder().decode(V2MessageReactionIntent.self,from:$0["payload"]) } }
    }
    func startReactionPreparation(id:UUID,now:Date) throws -> (Int,Date) {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_message_reaction_intents WHERE intent_id=? AND work_id IS NULL AND local_terminal IS NULL",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidTransition }
            let attempts:Int=row["preparation_attempts"],started:Double?=row["preparation_started_at"]
            try db.execute(sql:"UPDATE v2_message_reaction_intents SET preparation_attempts=preparation_attempts+1,preparation_started_at=COALESCE(preparation_started_at,?) WHERE intent_id=?",arguments:[now.timeIntervalSince1970,id.uuidString])
            return (attempts+1,Date(timeIntervalSince1970:started ?? now.timeIntervalSince1970))
        }
    }
    func deferReactionPreparation(id:UUID,until:Date,paused:Bool,code:String) throws {
        try databasePool.write { db in try db.execute(sql:"UPDATE v2_message_reaction_intents SET preparation_next_at=?,preparation_not_before=?,preparation_error=? WHERE intent_id=? AND work_id IS NULL",arguments:[paused ? nil : until.timeIntervalSince1970,until.timeIntervalSince1970,code,id.uuidString]) }
    }
    func expireReactionDraft(id:UUID) throws { try databasePool.write { db in try db.execute(sql:"UPDATE v2_message_reaction_intents SET local_terminal='expiredUnsubmitted',preparation_next_at=NULL WHERE intent_id=? AND work_id IS NULL",arguments:[id.uuidString]) } }
    func freezeReactionIntent(_ intent:V2MessageReactionIntent,snapshot:V2MessageReactionSnapshot,now:Date) throws -> Bool {
        guard snapshot.actorUserID==intent.actorUserID,snapshot.roomID==intent.roomID,snapshot.messageID==intent.messageID,snapshot.reaction==intent.reaction else { throw V2OperationWorkError.identityConflict }
        let command=try intent.command(revision:snapshot.revision),encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(command)
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_message_reaction_intents WHERE intent_id=? AND work_id IS NULL AND local_terminal IS NULL",arguments:[intent.id.uuidString]) else { return false }
            guard try JSONDecoder().decode(V2MessageReactionIntent.self,from:row["payload"])==intent else { return false }
            if Double(intent.deadlineMilliseconds)/1_000<=now.timeIntervalSince1970 {
                try db.execute(sql:"UPDATE v2_message_reaction_intents SET local_terminal='expiredUnsubmitted',preparation_next_at=NULL WHERE intent_id=?",arguments:[intent.id.uuidString]);return true
            }
            // Atomically move its reservation into public work, including at a full account quota.
            let key:String=row["ordering_key"]
            try Self.insertOperationWork(.init(id:intent.id,intentID:intent.id,identity:command.identity,fingerprint:command.fingerprint,orderingKey:key,payloadBytes:Int64(bytes.count),admissionDeadline:Date(timeIntervalSince1970:Double(intent.deadlineMilliseconds)/1_000)),now:now,db:db)
            try db.execute(sql:"UPDATE v2_message_reaction_intents SET work_id=?,command=?,preparation_next_at=NULL WHERE intent_id=?",arguments:[intent.id.uuidString,bytes,intent.id.uuidString])
            return true
        }
    }
    func reactionCommand(workID:UUID) throws -> V2MessageReactionOperationCommand {
        try databasePool.read { db in guard let bytes:Data=try Data.fetchOne(db,sql:"SELECT command FROM v2_message_reaction_intents WHERE work_id=?",arguments:[workID.uuidString]) else { throw V2OperationWorkError.invalidRecord };return try JSONDecoder().decode(V2MessageReactionOperationCommand.self,from:bytes) }
    }
    func completeReaction(_ command:V2MessageReactionOperationCommand,receipt:V2MessageReactionReceipt) throws {
        guard try receipt.validates(identity:command.identity,fingerprint:command.fingerprint) else { throw V2OperationWorkError.identityConflict }
        let state:V2OperationExecutionState
        switch receipt.outcome { case .committed(let commit):
            guard commit.targetState==command.targetState,commit.revision==command.expectedReactionRevision+1 else { throw V2OperationWorkError.identityConflict };state = .committed
        case .closed:state = .closed
        case .rejected(.revisionConflict):state = .conflicted
        case .rejected:state = .rejected }
        try completeOperationWork(.init(identity:command.identity,fingerprint:command.fingerprint,state:state,receipt:receipt),now:Date())
    }
    public func resumeReactionIntent(id:UUID,accountID:UserID,now:Date=Date()) throws {
        let workID:UUID?=try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_message_reaction_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let intent=try JSONDecoder().decode(V2MessageReactionIntent.self,from:row["payload"])
            guard intent.actorUserID==accountID else { throw V2OperationWorkError.accountMismatch }
            if let work:String=row["work_id"] { guard let id=UUID(uuidString:work) else { throw V2OperationWorkError.invalidRecord };return id }
            guard (row["local_terminal"] as String?)==nil else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql:"UPDATE v2_message_reaction_intents SET preparation_attempts=0,preparation_started_at=NULL,preparation_next_at=MAX(preparation_not_before,?),preparation_error=NULL WHERE intent_id=?",arguments:[now.timeIntervalSince1970,id.uuidString]);return nil
        }
        if let workID { try retryOperationWorkByUser(id:workID,now:now) }
    }
    public nonisolated func reactionPendingUpdates(roomID:RoomID) -> AsyncThrowingStream<[V2MessageReactionPending],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"SELECT i.* FROM v2_message_reaction_intents i LEFT JOIN v2_operation_work w ON w.work_id=i.work_id WHERE i.room_id=? AND (i.work_id IS NULL OR w.execution_state<>'committed') ORDER BY i.local_sequence DESC LIMIT 200",arguments:[roomID.rawValue]).map { row in
                            let intent=try JSONDecoder().decode(V2MessageReactionIntent.self,from:row["payload"])
                            let work=try (row["work_id"] as String?).map { value in guard let id=UUID(uuidString:value) else { throw V2OperationWorkError.invalidRecord };return try Self.requireOperationWork(id,db:db) }
                            return V2MessageReactionPending(intent:intent,work:work,preparationPaused:work==nil && (row["preparation_next_at"] as Double?)==nil,expiredUnsubmitted:(row["local_terminal"] as String?)=="expiredUnsubmitted")
                        }
                    }.removeDuplicates()
                    for try await pending in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(pending) };continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
    func reactionPreparationSchedule() -> V2CommandRetrySchedule {
        let pool=databasePool,query="SELECT MIN(preparation_next_at) FROM (\(Self.nextReactionDraftQuery))"
        return .init(nextAttemptAt:{ try await pool.read { try Double.fetchOne($0,sql:query).map(Date.init(timeIntervalSince1970:)) } },updates:{
            AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
                let task=Task {
                    do { let observation=ValueObservation.tracking { try Double.fetchOne($0,sql:query) }.removeDuplicates()
                        for try await _ in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(()) };continuation.finish()
                    } catch { continuation.finish(throwing:error) }
                };continuation.onTermination={ _ in task.cancel() }
            }
        })
    }
}

/// User actions persist a desired state first; only the account activity obtains a version and freezes execution.
public actor V2MessageReactionOperationService {
    private let accountID:UserID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2MessageReactionOperationClient
    private var preparing=false
    public init(accountID:UserID,store:GRDBV2LocalSyncStore,client:any V2MessageReactionOperationClient) { self.accountID=accountID;self.store=store;self.client=client }
    @discardableResult public func enqueue(roomID:RoomID,messageID:MessageID,reaction:String,targetState:V2MessageReactionTargetState) async throws -> UUID {
        try Task.checkCancellation()
        return try await store.enqueueReactionIntent(accountID:accountID,roomID:roomID,messageID:messageID,reaction:reaction,targetState:targetState)
    }
    public func updates(roomID:RoomID) async -> AsyncThrowingStream<[V2MessageReactionPending],any Error> { store.reactionPendingUpdates(roomID:roomID) }
    public func resumeConfirmation(intentID:UUID) async throws { try await store.resumeReactionIntent(id:intentID,accountID:accountID) }
    public func runPreparation() async throws {
        let schedule=await store.reactionPreparationSchedule()
        try await V2CommandRetryScheduler(schedule:schedule,flush:{ _ = try await self.prepareNextIntent() }).run()
    }
    @discardableResult public func prepareNextIntent(now:Date=Date()) async throws -> Bool {
        guard !preparing else { return false };preparing=true;defer { preparing=false }
        guard let intent=try await store.nextReactionDraft(now:now) else { return false }
        guard intent.actorUserID==accountID else { throw V2OperationWorkError.accountMismatch }
        if Double(intent.deadlineMilliseconds)/1_000<=now.timeIntervalSince1970 { try await store.expireReactionDraft(id:intent.id);return true }
        let (attempts,started)=try await store.startReactionPreparation(id:intent.id,now:now)
        let policy=V2NetworkWorkPolicy.commandRecovery
        guard attempts<=policy.maximumAttempts,now.timeIntervalSince(started)<policy.totalBudget else {
            try await store.deferReactionPreparation(id:intent.id,until:now,paused:true,code:"REACTION_BASELINE_BUDGET_EXHAUSTED")
            return false
        }
        do {
            let baseline=try await V2NetworkWorkScope.$context.withValue(.init(service:"accountAPI",priority:.recovery,isRetry:attempts>1)) {
                try await client.snapshot(roomID:intent.roomID,messageID:intent.messageID,reaction:intent.reaction)
            }
            try Task.checkCancellation()
            return try await store.freezeReactionIntent(intent,snapshot:baseline,now:Date())
        } catch is CancellationError { throw CancellationError() }
        catch {
            let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,failure=error as? V2HTTPFailure
            let malformed=error is V2OperationWorkError || error is V2MessageOperationValidationError || error is DatabaseError || (failure.map{[.invalidEndpoint,.invalidResponse,.responseTooLarge].contains($0.kind)} ?? false)
            let retry=policy.nextAttempt(now:now,startedAt:started,attemptsCompleted:attempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:failure?.retryAfter)
            try await store.deferReactionPreparation(id:intent.id,until:max(retry ?? now,failure?.retryAfter ?? now),paused:malformed || retry == nil,code:"REACTION_BASELINE_REQUIRED")
            if error is DatabaseError { throw error }
            return false
        }
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,claim.work.identity.kind == .reaction else { throw V2OperationWorkError.accountMismatch }
        let command=try await store.reactionCommand(workID:claim.work.id)
        guard try command.identity==claim.work.identity,try command.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        do {
            let result:V2MessageReactionRecoveryResult
            if claim.action == .submit { result=try await client.submit(command) }
            else { result=try await client.recover(.init(identity:claim.work.identity,fingerprint:claim.work.fingerprint,action:Date().timeIntervalSince1970*1_000<Double(command.firstSubmissionDeadlineMilliseconds) ? .query : .closeIfAbsent)) }
            switch result {
            case .receipt(let receipt):try await store.completeReaction(command,receipt:receipt)
            case .fingerprintConflict:try await store.deferOperationWork(claim,until:Date(),code:"REACTION_FINGERPRINT_CONFLICT",scheduling:.needsAttention)
            case .unresolved:
                try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"REACTION_UNRESOLVED",nextAction:Date().timeIntervalSince1970*1_000<Double(command.firstSubmissionDeadlineMilliseconds) ? .submit : .reconcile)
            case .deferred(let hint):
                guard hint.validates(identity:claim.work.identity,fingerprint:claim.work.fingerprint) else { throw V2OperationWorkError.identityConflict }
                let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,floor=Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1_000)
                let deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
                let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
                try await store.deferOperationWork(claim,until:max(retry ?? now,floor),code:hint.reason == .rateLimited ? "RATE_LIMITED" : "ADMISSION_UNAVAILABLE",scheduling:retry == nil ? .needsAttention : .backingOff)
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"REACTION_INTERRUPTED");throw CancellationError()
        } catch {
            let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,failure=error as? V2HTTPFailure
            let deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
            let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:failure?.retryAfter)
            let malformed=error is V2OperationWorkError || error is V2MessageOperationValidationError || (failure.map{[.invalidEndpoint,.invalidResponse,.responseTooLarge].contains($0.kind)} ?? false)
            try await store.deferOperationWork(claim,until:max(retry ?? now,failure?.retryAfter ?? now),code:"REACTION_CONFIRMATION_REQUIRED",scheduling:malformed || retry == nil ? .needsAttention : .backingOff)
            if error is DatabaseError { throw error }
        }
    }
}
