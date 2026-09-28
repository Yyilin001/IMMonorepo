import Foundation
import GRDB
import IMV2Core

public enum V2InvitationPreparationError:Error,Sendable { case confirmationRequired }
public enum V2InvitationPreparationState:String,Sendable { case ready,paused,cancelled,frozen }
public struct V2InvitationPending:Equatable,Sendable {
    public let id:UUID
    public let intent:V2GroupInvitationOperationIntent
    public let secretReference:UUID?
    public let secretReleasePending:Bool
    public let command:V2GroupInvitationOperationCommand?
    public let work:V2OperationWork?
    public let preparationState:V2InvitationPreparationState
    public let preparationAttempts:Int
    public let nextPreparationAt:Date
    public let confirmationActivationID:UUID
    public let preparationCode:String?
    public var confirmationRequired:Bool { preparationState == .paused }
}
extension GRDBV2LocalSyncStore {
    static func invitationOrderingKey(_ intent:V2GroupInvitationOperationIntent) throws -> String {
        "invitationOperations:"+String(decoding:try JSONEncoder().encode([intent.identity.accountID.rawValue,intent.roomID.rawValue]),as:UTF8.self)
    }
    func enqueueInvitation(_ intent:V2GroupInvitationOperationIntent,activationID:UUID,secretReference:UUID?=nil,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(intent),identity=try intent.identity,key=try Self.invitationOrderingKey(intent),time=try Self.commandRetryTimestamp(now)
        guard bytes.count<=8_192,Double(intent.confirmedUntilMilliseconds)/1_000>time,
            Double(intent.confirmedUntilMilliseconds)/1_000-time<=120.001 else { throw V2GroupInvitationOperationValidationError.invalidIntent }
        if case .submit = intent.action { guard secretReference != nil else { throw V2GroupInvitationOperationValidationError.invalidSecretBinding } } else { guard secretReference == nil else { throw V2GroupInvitationOperationValidationError.invalidSecretBinding } }
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==intent.identity.accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            if let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE identity_key=?",arguments:[identity.storageKey]) {
                let existing=try Self.decodeInvitation(row,db:db)
                guard existing.intent==intent else { throw V2OperationWorkError.identityConflict };return existing.id
            }
            guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM v2_invitation_operation_intents i LEFT JOIN v2_operation_work w USING(work_id) WHERE i.ordering_key=? AND i.preparation_state<>'cancelled' AND (i.work_id IS NULL OR w.scheduling_state<>'finished'))",arguments:[key])==false else { throw V2InvitationPreparationError.confirmationRequired }
            try Self.requireOperationCapacity(adding:Self.invitationWorkReservation,limits:limits,db:db)
            let id=UUID()
            try db.execute(sql:"INSERT INTO v2_invitation_operation_intents(intent_id,identity_key,account_id,room_id,ordering_key,intent,payload_bytes,confirmation_activation_id,preparation_state,preparation_next_at,secret_reference) VALUES(?,?,?,?,?,?,?,?,'ready',?,?)",arguments:[id.uuidString,identity.storageKey,intent.identity.accountID.rawValue,intent.roomID.rawValue,key,bytes,Self.invitationWorkReservation,activationID.uuidString,time,secretReference?.uuidString])
            return id
        }
    }
    static func decodeInvitation(_ row:Row,db:Database) throws -> V2InvitationPending {
        guard let id=UUID(uuidString:row["intent_id"]),let activation=UUID(uuidString:row["confirmation_activation_id"]),
            let state=V2InvitationPreparationState(rawValue:row["preparation_state"]) else { throw V2OperationWorkError.invalidRecord }
        let intent=try JSONDecoder().decode(V2GroupInvitationOperationIntent.self,from:row["intent"])
        guard try intent.identity.storageKey==row["identity_key"] as String,intent.identity.accountID.rawValue==row["account_id"] as String,
            intent.roomID.rawValue==row["room_id"] as String,
            try invitationOrderingKey(intent)==row["ordering_key"] as String else { throw V2OperationWorkError.identityConflict }
        let command=try (row["command"] as Data?).map { try JSONDecoder().decode(V2GroupInvitationOperationCommand.self,from:$0) }
        let work=try (row["work_id"] as String?).map { value -> V2OperationWork in
            guard let id=UUID(uuidString:value) else { throw V2OperationWorkError.invalidRecord };return try requireOperationWork(id,db:db)
        }
        if let command,let work { guard command.intent==intent,try command.identity==work.identity,try command.fingerprint==work.fingerprint else { throw V2OperationWorkError.identityConflict } }
        if let work { guard work.identity==intent.identity,work.fingerprint == (try intent.fingerprint) else {throw V2OperationWorkError.identityConflict} }
        let attempts:Int=row["preparation_attempts"]
        guard (0...5).contains(attempts),(command == nil || work != nil),(work != nil)==(state == .frozen) else { throw V2OperationWorkError.invalidRecord }
        return .init(id:id,intent:intent,secretReference:(row["secret_reference"] as String?).flatMap(UUID.init(uuidString:)),secretReleasePending:row["secret_release_pending"],command:command,work:work,preparationState:state,preparationAttempts:attempts,nextPreparationAt:Date(timeIntervalSince1970:row["preparation_next_at"]),confirmationActivationID:activation,preparationCode:row["last_preparation_code"])
    }
    func invitationPending(id:UUID) throws -> V2InvitationPending {
        try databasePool.read { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord };return try Self.decodeInvitation(row,db:db) }
    }
    func beginInvitationPreparation(now:Date=Date()) throws -> V2InvitationPending? {
        let time=try Self.commandRetryTimestamp(now)
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE preparation_state='ready' AND preparation_next_at<=? ORDER BY local_sequence LIMIT 1",arguments:[time]) else { return nil }
            let pending=try Self.decodeInvitation(row,db:db),deadline:Double?=row["preparation_deadline"]
            guard pending.preparationAttempts<5,deadline.map({$0>time}) ?? true,Double(pending.intent.confirmedUntilMilliseconds)/1_000>time else {
                try db.execute(sql:"UPDATE v2_invitation_operation_intents SET preparation_state='paused',last_preparation_code='CONFIRMATION_REQUIRED' WHERE intent_id=?",arguments:[pending.id.uuidString]);return nil
            }
            let end=min(deadline ?? time+60,Double(pending.intent.confirmedUntilMilliseconds)/1_000)
            try db.execute(sql:"UPDATE v2_invitation_operation_intents SET preparation_attempts=preparation_attempts+1,preparation_deadline=? WHERE intent_id=?",arguments:[end,pending.id.uuidString])
            return try Self.decodeInvitation(Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE intent_id=?",arguments:[pending.id.uuidString])!,db:db)
        }
    }
    func pauseInvitationPreparation(id:UUID,until:Date=Date(),code:String,paused:Bool=true) throws {
        let time=try Self.commandRetryTimestamp(until)
        try databasePool.write { db in try db.execute(sql:"UPDATE v2_invitation_operation_intents SET preparation_state=?,preparation_next_at=MAX(preparation_next_at,?),last_preparation_code=? WHERE intent_id=? AND preparation_state='ready' AND work_id IS NULL",arguments:[paused ? "paused":"ready",time,code,id.uuidString]) }
    }
    func freezeInvitation(id:UUID,admission:V2GroupInvitationAdmission,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID? {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeInvitation(row,db:db)
            guard pending.preparationState == .ready,pending.work==nil else { return nil }
            let command=try V2GroupInvitationOperationCommand(intent:pending.intent,admission:admission),encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let bytes=try encoder.encode(command)
            guard bytes.count<=8_192 else { throw V2OperationWorkError.invalidRecord }
            let workID=UUID()
            _ = try Self.insertOperationWork(.init(id:workID,intentID:id,identity:command.identity,fingerprint:command.fingerprint,orderingKey:row["ordering_key"],payloadBytes:Self.invitationWorkReservation,admissionDeadline:Date(timeIntervalSince1970:Double(admission.expiresAtMilliseconds)/1_000)),now:now,limits:limits,db:db)
            try db.execute(sql:"UPDATE v2_invitation_operation_intents SET command=?,work_id=?,preparation_state='frozen' WHERE intent_id=?",arguments:[bytes,workID.uuidString,id.uuidString])
            return workID
        }
    }
    func invitationCommand(workID:UUID) throws -> V2GroupInvitationOperationCommand {
        try databasePool.read { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE work_id=?",arguments:[workID.uuidString]),let command=try Self.decodeInvitation(row,db:db).command else { throw V2OperationWorkError.invalidRecord };return command }
    }
    func completeInvitation(_ receipt:V2GroupInvitationOperationReceipt,intent:V2GroupInvitationOperationIntent,now:Date=Date()) throws {
        guard receipt.validates(intent:intent) else { throw V2GroupInvitationOperationValidationError.invalidReceipt }
        let state:V2OperationExecutionState
        switch receipt.outcome { case .applied,.alreadySatisfied:state = .committed;case .closed:state = .closed;case .rejected(.membershipChanged):state = .conflicted;case .rejected:state = .rejected }
        try databasePool.write { db in
            try Self.completeOperationWork(.init(identity:receipt.identity,fingerprint:receipt.fingerprint,state:state,receipt:receipt),now:now,db:db)
            try db.execute(sql:"UPDATE v2_invitation_operation_intents SET secret_release_pending=1 WHERE identity_key=? AND secret_reference IS NOT NULL",arguments:[intent.identity.storageKey])
        }
    }
    // Recovery can proceed without a gate credential or unlocked bearer.
    func trackInvitationRecovery(id:UUID,now:Date=Date()) throws -> UUID {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE intent_id=?",arguments:[id.uuidString]) else {throw V2OperationWorkError.invalidRecord}
            let pending=try Self.decodeInvitation(row,db:db)
            if let work=pending.work {return work.id}
            guard pending.preparationState != .cancelled else {throw V2OperationWorkError.invalidTransition}
            let workID=UUID()
            _ = try Self.insertOperationWork(.init(id:workID,intentID:id,identity:pending.intent.identity,fingerprint:pending.intent.fingerprint,orderingKey:row["ordering_key"],payloadBytes:Self.invitationWorkReservation,admissionDeadline:Date(timeIntervalSince1970:Double(pending.intent.confirmedUntilMilliseconds)/1000)),now:now,limits:.init(),db:db)
            try db.execute(sql:"UPDATE v2_operation_work SET next_action_kind='reconcile' WHERE work_id=?",arguments:[workID.uuidString])
            try db.execute(sql:"UPDATE v2_invitation_operation_intents SET work_id=?,preparation_state='frozen' WHERE intent_id=?",arguments:[workID.uuidString,id.uuidString])
            return workID
        }
    }
    func invitationPending(workID:UUID) throws -> V2InvitationPending {
        try databasePool.read { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE work_id=?",arguments:[workID.uuidString]) else {throw V2OperationWorkError.invalidRecord};return try Self.decodeInvitation(row,db:db) }
    }
    func invitationSecretsForRelease() throws -> [V2InvitationPending] {
        try databasePool.read { db in try Row.fetchAll(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE secret_release_pending=1 ORDER BY local_sequence LIMIT 100").map {try Self.decodeInvitation($0,db:db)} }
    }
    func markInvitationSecretReleased(id:UUID) throws {
        try databasePool.write { db in try db.execute(sql:"UPDATE v2_invitation_operation_intents SET secret_reference=NULL,secret_release_pending=0 WHERE intent_id=? AND secret_release_pending=1",arguments:[id.uuidString]) }
    }
    static func sameInvitationProposal(_ left:V2GroupInvitationOperationAction,_ right:V2GroupInvitationOperationAction) -> Bool {
        switch (left,right) {
        case (.create(let a,let b,_),.create(let c,let d,_)):return a==c && b==d
        case (.revoke(let a,_),.revoke(let b,_)):return a==b
        case (.decide(let a,let b,_),.decide(let c,let d,_)):return a==c && b==d
        default:return left==right
        }
    }
    func replaceInvitationDraft(id:UUID,intent:V2GroupInvitationOperationIntent,activationID:UUID,now:Date) throws -> UUID {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(intent),identity=try intent.identity,key=try Self.invitationOrderingKey(intent),time=try Self.commandRetryTimestamp(now)
        guard bytes.count<=8192,Double(intent.confirmedUntilMilliseconds)/1000>time,Double(intent.confirmedUntilMilliseconds)/1000-time<=120.001 else { throw V2GroupInvitationOperationValidationError.invalidIntent }
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let previous=try Self.decodeInvitation(row,db:db)
            guard previous.work==nil,previous.preparationState == .paused,previous.intent.identity.accountID==intent.identity.accountID,previous.intent.roomID==intent.roomID,Self.sameInvitationProposal(previous.intent.action,intent.action) else { throw V2OperationWorkError.invalidTransition }
            try Self.requireOperationCapacity(adding:Self.invitationWorkReservation,excludingIntent:id,limits:.init(),db:db)
            let replacement=UUID()
            try db.execute(sql:"UPDATE v2_invitation_operation_intents SET preparation_state='cancelled',secret_reference=NULL WHERE intent_id=?",arguments:[id.uuidString])
            try db.execute(sql:"INSERT INTO v2_invitation_operation_intents(intent_id,identity_key,account_id,room_id,ordering_key,intent,payload_bytes,confirmation_activation_id,preparation_state,preparation_next_at,secret_reference) VALUES(?,?,?,?,?,?,?,?,'ready',?,?)",arguments:[replacement.uuidString,identity.storageKey,intent.identity.accountID.rawValue,intent.roomID.rawValue,key,bytes,Self.invitationWorkReservation,activationID.uuidString,max(previous.nextPreparationAt.timeIntervalSince1970,time),previous.secretReference?.uuidString])
            return replacement
        }
    }
    func discardInvitationDraft(id:UUID,accountID:UserID) throws {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_invitation_operation_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeInvitation(row,db:db)
            guard pending.intent.identity.accountID==accountID,pending.work==nil else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql:"UPDATE v2_invitation_operation_intents SET preparation_state='cancelled',secret_release_pending=CASE WHEN secret_reference IS NULL THEN 0 ELSE 1 END WHERE intent_id=?",arguments:[id.uuidString])
        }
    }
}

extension GRDBV2LocalSyncStore {
    public nonisolated func invitationUpdates(roomID:RoomID) -> AsyncThrowingStream<[V2InvitationPending],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"SELECT i.* FROM v2_invitation_operation_intents i LEFT JOIN v2_operation_work w USING(work_id) WHERE i.room_id=? AND i.preparation_state<>'cancelled' ORDER BY CASE WHEN w.scheduling_state='finished' THEN 1 ELSE 0 END,i.local_sequence DESC LIMIT 2200",arguments:[roomID.rawValue]).map { try Self.decodeInvitation($0,db:db) }
                    }.removeDuplicates()
                    for try await value in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
    func invitationPreparationSchedule() -> V2CommandRetrySchedule {
        let pool=databasePool,query="SELECT MIN(preparation_next_at) FROM v2_invitation_operation_intents WHERE preparation_state='ready'"
        return .init(nextAttemptAt:{ try await pool.read { try Double.fetchOne($0,sql:query).map(Date.init(timeIntervalSince1970:)) } },updates:{
            AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
                let task=Task {
                    do {
                        let observation=ValueObservation.tracking { try Double.fetchOne($0,sql:query) }.removeDuplicates()
                        for try await _ in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(()) };continuation.finish()
                    } catch { continuation.finish(throwing:error) }
                };continuation.onTermination={ _ in task.cancel() }
            }
        })
    }
}
