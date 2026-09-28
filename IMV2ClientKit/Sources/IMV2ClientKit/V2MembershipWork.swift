import Foundation
import GRDB
import IMV2Core

public enum V2MembershipAdmissionError:Error,Sendable { case confirmationRequired }
public enum V2MembershipPreparationState:String,Sendable { case ready,paused,cancelled,frozen }
public struct V2MembershipPending:Equatable,Sendable {
    public let id:UUID
    public let intent:V2MembershipIntent
    public let command:V2MembershipOperationCommand?
    public let work:V2OperationWork?
    public let preparationState:V2MembershipPreparationState
    public let preparationAttempts:Int
    public let nextPreparationAt:Date
    public let confirmationActivationID:UUID
    public let preparationCode:String?
    public var confirmationRequired:Bool { preparationState == .paused }
}
extension GRDBV2LocalSyncStore {
    static func membershipOrderingKey(_ intent:V2MembershipIntent) throws -> String {
        "membership:"+String(decoding:try JSONEncoder().encode([intent.actorUserID.rawValue,intent.roomID.rawValue]),as:UTF8.self)
    }
    func enqueueMembership(_ intent:V2MembershipIntent,activationID:UUID,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(intent),identity=try intent.identity,key=try Self.membershipOrderingKey(intent),time=try Self.commandRetryTimestamp(now)
        guard bytes.count<=4_096,Double(intent.confirmedUntilMilliseconds)/1_000>time,
            Double(intent.confirmedUntilMilliseconds)/1_000-time<=120.001 else { throw V2MembershipOperationValidationError.invalidIntent }
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==intent.actorUserID.rawValue else { throw V2OperationWorkError.accountMismatch }
            if let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_membership_intents WHERE identity_key=?",arguments:[identity.storageKey]) {
                let existing=try Self.decodeMembership(row,db:db)
                guard existing.intent==intent else { throw V2OperationWorkError.identityConflict };return existing.id
            }
            guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM v2_membership_intents i LEFT JOIN v2_operation_work w USING(work_id) WHERE i.ordering_key=? AND i.preparation_state<>'cancelled' AND (i.work_id IS NULL OR w.scheduling_state<>'finished'))",arguments:[key])==false else { throw V2MembershipAdmissionError.confirmationRequired }
            try Self.requireOperationCapacity(adding:Self.membershipWorkReservation,limits:limits,db:db)
            let id=UUID()
            try db.execute(sql:"INSERT INTO v2_membership_intents(intent_id,identity_key,account_id,room_id,target_user_id,ordering_key,intent,payload_bytes,confirmation_activation_id,preparation_state,preparation_next_at) VALUES(?,?,?,?,?,?,?,?,?,'ready',?)",arguments:[id.uuidString,identity.storageKey,intent.actorUserID.rawValue,intent.roomID.rawValue,intent.targetUserID.rawValue,key,bytes,Self.membershipWorkReservation,activationID.uuidString,time])
            return id
        }
    }
    static func decodeMembership(_ row:Row,db:Database) throws -> V2MembershipPending {
        guard let id=UUID(uuidString:row["intent_id"]),let activation=UUID(uuidString:row["confirmation_activation_id"]),
            let state=V2MembershipPreparationState(rawValue:row["preparation_state"]) else { throw V2OperationWorkError.invalidRecord }
        let intent=try JSONDecoder().decode(V2MembershipIntent.self,from:row["intent"])
        guard try intent.identity.storageKey==row["identity_key"] as String,intent.actorUserID.rawValue==row["account_id"] as String,
            intent.roomID.rawValue==row["room_id"] as String,intent.targetUserID.rawValue==row["target_user_id"] as String,
            try membershipOrderingKey(intent)==row["ordering_key"] as String else { throw V2OperationWorkError.identityConflict }
        let command=try (row["command"] as Data?).map { try JSONDecoder().decode(V2MembershipOperationCommand.self,from:$0) }
        let work=try (row["work_id"] as String?).map { value -> V2OperationWork in
            guard let id=UUID(uuidString:value) else { throw V2OperationWorkError.invalidRecord };return try requireOperationWork(id,db:db)
        }
        if let command,let work { guard command.intent==intent,try command.identity==work.identity,try command.fingerprint==work.fingerprint else { throw V2OperationWorkError.identityConflict } }
        let attempts:Int=row["preparation_attempts"]
        guard (0...5).contains(attempts),(command != nil)==(work != nil),(work != nil)==(state == .frozen) else { throw V2OperationWorkError.invalidRecord }
        return .init(id:id,intent:intent,command:command,work:work,preparationState:state,preparationAttempts:attempts,nextPreparationAt:Date(timeIntervalSince1970:row["preparation_next_at"]),confirmationActivationID:activation,preparationCode:row["last_preparation_code"])
    }
    func membershipPending(id:UUID) throws -> V2MembershipPending {
        try databasePool.read { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_membership_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord };return try Self.decodeMembership(row,db:db) }
    }
    func beginMembershipPreparation(now:Date=Date()) throws -> V2MembershipPending? {
        let time=try Self.commandRetryTimestamp(now)
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_membership_intents WHERE preparation_state='ready' AND preparation_next_at<=? ORDER BY local_sequence LIMIT 1",arguments:[time]) else { return nil }
            let pending=try Self.decodeMembership(row,db:db),deadline:Double?=row["preparation_deadline"]
            guard pending.preparationAttempts<5,deadline.map({$0>time}) ?? true,Double(pending.intent.confirmedUntilMilliseconds)/1_000>time else {
                try db.execute(sql:"UPDATE v2_membership_intents SET preparation_state='paused',last_preparation_code='CONFIRMATION_REQUIRED' WHERE intent_id=?",arguments:[pending.id.uuidString]);return nil
            }
            let end=min(deadline ?? time+60,Double(pending.intent.confirmedUntilMilliseconds)/1_000)
            try db.execute(sql:"UPDATE v2_membership_intents SET preparation_attempts=preparation_attempts+1,preparation_deadline=? WHERE intent_id=?",arguments:[end,pending.id.uuidString])
            return try Self.decodeMembership(Row.fetchOne(db,sql:"SELECT * FROM v2_membership_intents WHERE intent_id=?",arguments:[pending.id.uuidString])!,db:db)
        }
    }
    func pauseMembershipPreparation(id:UUID,until:Date=Date(),code:String,paused:Bool=true) throws {
        let time=try Self.commandRetryTimestamp(until)
        try databasePool.write { db in try db.execute(sql:"UPDATE v2_membership_intents SET preparation_state=?,preparation_next_at=MAX(preparation_next_at,?),last_preparation_code=? WHERE intent_id=? AND preparation_state='ready' AND work_id IS NULL",arguments:[paused ? "paused":"ready",time,code,id.uuidString]) }
    }
    func freezeMembership(id:UUID,admission:V2MembershipAdmission,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID? {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_membership_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeMembership(row,db:db)
            guard pending.preparationState == .ready,pending.work==nil else { return nil }
            let command=try V2MembershipOperationCommand(intent:pending.intent,admission:admission),encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let bytes=try encoder.encode(command)
            guard bytes.count<=4_096 else { throw V2OperationWorkError.invalidRecord }
            let workID=UUID()
            _ = try Self.insertOperationWork(.init(id:workID,intentID:id,identity:command.identity,fingerprint:command.fingerprint,orderingKey:row["ordering_key"],payloadBytes:Self.membershipWorkReservation,admissionDeadline:Date(timeIntervalSince1970:Double(admission.expiresAtMilliseconds)/1_000)),now:now,limits:limits,db:db)
            try db.execute(sql:"UPDATE v2_membership_intents SET command=?,work_id=?,preparation_state='frozen' WHERE intent_id=?",arguments:[bytes,workID.uuidString,id.uuidString])
            return workID
        }
    }
    func membershipCommand(workID:UUID) throws -> V2MembershipOperationCommand {
        try databasePool.read { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_membership_intents WHERE work_id=?",arguments:[workID.uuidString]),let command=try Self.decodeMembership(row,db:db).command else { throw V2OperationWorkError.invalidRecord };return command }
    }
    func completeMembership(_ receipt:V2MembershipReceipt,command:V2MembershipOperationCommand,now:Date=Date()) throws {
        guard receipt.validates(command:command) else { throw V2MembershipOperationValidationError.invalidReceipt }
        let state:V2OperationExecutionState
        switch receipt.outcome { case .changed:state = .committed;case .closed:state = .closed;case .rejected(.membershipChanged):state = .conflicted;case .rejected:state = .rejected }
        try completeOperationWork(.init(identity:receipt.identity,fingerprint:receipt.fingerprint,state:state,receipt:receipt),now:now)
    }
    func replaceMembershipDraft(id:UUID,intent:V2MembershipIntent,activationID:UUID,now:Date) throws -> UUID {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(intent),identity=try intent.identity,key=try Self.membershipOrderingKey(intent),time=try Self.commandRetryTimestamp(now)
        guard bytes.count<=4096,Double(intent.confirmedUntilMilliseconds)/1000>time,Double(intent.confirmedUntilMilliseconds)/1000-time<=120.001 else { throw V2MembershipOperationValidationError.invalidIntent }
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_membership_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let previous=try Self.decodeMembership(row,db:db)
            guard previous.work==nil,previous.preparationState == .paused,previous.intent.actorUserID==intent.actorUserID,previous.intent.targetUserID==intent.targetUserID,previous.intent.roomID==intent.roomID,previous.intent.action==intent.action else { throw V2OperationWorkError.invalidTransition }
            try Self.requireOperationCapacity(adding:Self.membershipWorkReservation,excludingIntent:id,limits:.init(),db:db)
            let replacement=UUID()
            try db.execute(sql:"UPDATE v2_membership_intents SET preparation_state='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
            try db.execute(sql:"INSERT INTO v2_membership_intents(intent_id,identity_key,account_id,room_id,target_user_id,ordering_key,intent,payload_bytes,confirmation_activation_id,preparation_state,preparation_next_at) VALUES(?,?,?,?,?,?,?,?,?,'ready',?)",arguments:[replacement.uuidString,identity.storageKey,intent.actorUserID.rawValue,intent.roomID.rawValue,intent.targetUserID.rawValue,key,bytes,Self.membershipWorkReservation,activationID.uuidString,max(previous.nextPreparationAt.timeIntervalSince1970,time)])
            return replacement
        }
    }
    func discardMembershipDraft(id:UUID,accountID:UserID) throws {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_membership_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeMembership(row,db:db)
            guard pending.intent.actorUserID==accountID,pending.work==nil else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql:"UPDATE v2_membership_intents SET preparation_state='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
        }
    }
}

extension GRDBV2LocalSyncStore {
    public nonisolated func membershipUpdates(roomID:RoomID) -> AsyncThrowingStream<[V2MembershipPending],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"SELECT i.* FROM v2_membership_intents i LEFT JOIN v2_operation_work w USING(work_id) WHERE i.room_id=? AND i.preparation_state<>'cancelled' ORDER BY CASE WHEN w.scheduling_state='finished' THEN 1 ELSE 0 END,i.local_sequence DESC LIMIT 2200",arguments:[roomID.rawValue]).map { try Self.decodeMembership($0,db:db) }
                    }.removeDuplicates()
                    for try await value in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
    func membershipPreparationSchedule() -> V2CommandRetrySchedule {
        let pool=databasePool,query="SELECT MIN(preparation_next_at) FROM v2_membership_intents WHERE preparation_state='ready'"
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
