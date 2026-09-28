import Foundation
import GRDB
import IMV2Core

public enum V2GroupCapabilityAdmissionError:Error,Sendable { case confirmationRequired }
public enum V2GroupCapabilityPreparationState:String,Sendable { case ready,paused,cancelled,frozen }
public struct V2GroupCapabilityPending:Equatable,Sendable {
    public let id:UUID
    public let intent:V2GroupCapabilityIntent
    public let command:V2GroupCapabilityCommand?
    public let work:V2OperationWork?
    public let preparationState:V2GroupCapabilityPreparationState
    public let preparationAttempts:Int
    public let nextPreparationAt:Date
    public let confirmationActivationID:UUID
    public let preparationCode:String?
    public var confirmationRequired:Bool { preparationState == .paused }
}
extension GRDBV2LocalSyncStore {
    static let groupCapabilityReservation:Int64=2*32_768+65_536
    static let groupCapabilityWorkSchemaSQL="""
        CREATE TABLE v2_group_capability_intents (
            local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            intent_id TEXT NOT NULL UNIQUE,identity_key TEXT NOT NULL UNIQUE,
            account_id TEXT NOT NULL,room_id TEXT NOT NULL,ordering_key TEXT NOT NULL,
            intent BLOB NOT NULL CHECK(length(intent)<=32768),command BLOB CHECK(length(command)<=32768),
            work_id TEXT UNIQUE REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            payload_bytes INTEGER NOT NULL CHECK(payload_bytes=131072),confirmation_activation_id TEXT NOT NULL,
            preparation_state TEXT NOT NULL CHECK(preparation_state IN ('ready','paused','cancelled','frozen')),
            preparation_attempts INTEGER NOT NULL DEFAULT 0 CHECK(preparation_attempts BETWEEN 0 AND 5),
            preparation_next_at REAL NOT NULL,preparation_deadline REAL,last_preparation_code TEXT,
            CHECK((work_id IS NOT NULL)=(command IS NOT NULL)),CHECK((work_id IS NOT NULL)=(preparation_state='frozen'))
        );
        CREATE INDEX v2_group_capability_ready ON v2_group_capability_intents(preparation_next_at,local_sequence) WHERE preparation_state='ready';
        CREATE INDEX v2_group_capability_order ON v2_group_capability_intents(ordering_key,local_sequence);
        """
    static func groupCapabilityOrderingKey(_ intent:V2GroupCapabilityIntent) throws -> String {
        "group-capability:"+String(decoding:try JSONEncoder().encode([intent.identity.accountID.rawValue,intent.roomID.rawValue]),as:UTF8.self)
    }
    func enqueueGroupCapability(_ intent:V2GroupCapabilityIntent,activationID:UUID,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(intent),identity=intent.identity,key=try Self.groupCapabilityOrderingKey(intent),time=try Self.commandRetryTimestamp(now)
        guard bytes.count<=32_768,Double(intent.confirmedUntilMilliseconds)/1_000>time,
            Double(intent.confirmedUntilMilliseconds)/1_000-time<=120.001 else { throw V2GroupCapabilityValidationError.invalidIntent }
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==intent.identity.accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            if let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_group_capability_intents WHERE identity_key=?",arguments:[identity.storageKey]) {
                let existing=try Self.decodeGroupCapability(row,db:db)
                guard existing.intent==intent else { throw V2OperationWorkError.identityConflict };return existing.id
            }
            guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM v2_group_capability_intents i LEFT JOIN v2_operation_work w USING(work_id) WHERE i.ordering_key=? AND i.preparation_state<>'cancelled' AND (i.work_id IS NULL OR w.scheduling_state<>'finished'))",arguments:[key])==false else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
            try Self.requireOperationCapacity(adding:Self.groupCapabilityReservation,limits:limits,db:db)
            let id=UUID()
            try db.execute(sql:"INSERT INTO v2_group_capability_intents(intent_id,identity_key,account_id,room_id,ordering_key,intent,payload_bytes,confirmation_activation_id,preparation_state,preparation_next_at) VALUES(?,?,?,?,?,?,?,?,'ready',?)",arguments:[id.uuidString,identity.storageKey,intent.identity.accountID.rawValue,intent.roomID.rawValue,key,bytes,Self.groupCapabilityReservation,activationID.uuidString,time])
            return id
        }
    }
    static func decodeGroupCapability(_ row:Row,db:Database) throws -> V2GroupCapabilityPending {
        guard let id=UUID(uuidString:row["intent_id"]),let activation=UUID(uuidString:row["confirmation_activation_id"]),
            let state=V2GroupCapabilityPreparationState(rawValue:row["preparation_state"]) else { throw V2OperationWorkError.invalidRecord }
        let intent=try JSONDecoder().decode(V2GroupCapabilityIntent.self,from:row["intent"])
        guard intent.identity.storageKey==row["identity_key"] as String,intent.identity.accountID.rawValue==row["account_id"] as String,
            intent.roomID.rawValue==row["room_id"] as String,
            try groupCapabilityOrderingKey(intent)==row["ordering_key"] as String else { throw V2OperationWorkError.identityConflict }
        let command=try (row["command"] as Data?).map { try JSONDecoder().decode(V2GroupCapabilityCommand.self,from:$0) }
        let work=try (row["work_id"] as String?).map { value -> V2OperationWork in
            guard let id=UUID(uuidString:value) else { throw V2OperationWorkError.invalidRecord };return try requireOperationWork(id,db:db)
        }
        if let command,let work { guard command.intent==intent,command.identity==work.identity,try command.fingerprint==work.fingerprint else { throw V2OperationWorkError.identityConflict } }
        let attempts:Int=row["preparation_attempts"]
        guard (0...5).contains(attempts),(command != nil)==(work != nil),(work != nil)==(state == .frozen) else { throw V2OperationWorkError.invalidRecord }
        return .init(id:id,intent:intent,command:command,work:work,preparationState:state,preparationAttempts:attempts,nextPreparationAt:Date(timeIntervalSince1970:row["preparation_next_at"]),confirmationActivationID:activation,preparationCode:row["last_preparation_code"])
    }
    func groupCapabilityPending(id:UUID) throws -> V2GroupCapabilityPending {
        try databasePool.read { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_group_capability_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord };return try Self.decodeGroupCapability(row,db:db) }
    }
    func beginGroupCapabilityPreparation(now:Date=Date()) throws -> V2GroupCapabilityPending? {
        let time=try Self.commandRetryTimestamp(now)
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_group_capability_intents WHERE preparation_state='ready' AND preparation_next_at<=? ORDER BY local_sequence LIMIT 1",arguments:[time]) else { return nil }
            let pending=try Self.decodeGroupCapability(row,db:db),deadline:Double?=row["preparation_deadline"]
            guard pending.preparationAttempts<5,deadline.map({$0>time}) ?? true,Double(pending.intent.confirmedUntilMilliseconds)/1_000>time else {
                try db.execute(sql:"UPDATE v2_group_capability_intents SET preparation_state='paused',last_preparation_code='CONFIRMATION_REQUIRED' WHERE intent_id=?",arguments:[pending.id.uuidString]);return nil
            }
            let end=min(deadline ?? time+60,Double(pending.intent.confirmedUntilMilliseconds)/1_000)
            try db.execute(sql:"UPDATE v2_group_capability_intents SET preparation_attempts=preparation_attempts+1,preparation_deadline=? WHERE intent_id=?",arguments:[end,pending.id.uuidString])
            return try Self.decodeGroupCapability(Row.fetchOne(db,sql:"SELECT * FROM v2_group_capability_intents WHERE intent_id=?",arguments:[pending.id.uuidString])!,db:db)
        }
    }
    func pauseGroupCapabilityPreparation(id:UUID,until:Date=Date(),code:String,paused:Bool=true) throws {
        let time=try Self.commandRetryTimestamp(until)
        try databasePool.write { db in try db.execute(sql:"UPDATE v2_group_capability_intents SET preparation_state=?,preparation_next_at=MAX(preparation_next_at,?),last_preparation_code=? WHERE intent_id=? AND preparation_state='ready' AND work_id IS NULL",arguments:[paused ? "paused":"ready",time,code,id.uuidString]) }
    }
    func freezeGroupCapability(id:UUID,admission:V2GroupCapabilityAdmission,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID? {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_group_capability_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeGroupCapability(row,db:db)
            guard pending.preparationState == .ready,pending.work==nil else { return nil }
            let command=try V2GroupCapabilityCommand(intent:pending.intent,admission:admission),encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let bytes=try encoder.encode(command)
            guard bytes.count<=32_768 else { throw V2OperationWorkError.invalidRecord }
            let workID=UUID()
            _ = try Self.insertOperationWork(.init(id:workID,intentID:id,identity:command.identity,fingerprint:command.fingerprint,orderingKey:row["ordering_key"],payloadBytes:Self.groupCapabilityReservation,admissionDeadline:Date(timeIntervalSince1970:Double(admission.expiresAtMilliseconds)/1_000)),now:now,limits:limits,db:db)
            try db.execute(sql:"UPDATE v2_group_capability_intents SET command=?,work_id=?,preparation_state='frozen' WHERE intent_id=?",arguments:[bytes,workID.uuidString,id.uuidString])
            return workID
        }
    }
    func groupCapabilityCommand(workID:UUID) throws -> V2GroupCapabilityCommand {
        try databasePool.read { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_group_capability_intents WHERE work_id=?",arguments:[workID.uuidString]),let command=try Self.decodeGroupCapability(row,db:db).command else { throw V2OperationWorkError.invalidRecord };return command }
    }
    func completeGroupCapability(_ receipt:V2GroupCapabilityReceipt,command:V2GroupCapabilityCommand,now:Date=Date()) throws {
        guard receipt.validates(command:command) else { throw V2GroupCapabilityValidationError.invalidReceipt }
        let state:V2OperationExecutionState
        switch receipt.outcome { case .applied,.alreadySatisfied:state = .committed;case .closed:state = .closed;case .rejected(.revisionChanged):state = .conflicted;case .rejected:state = .rejected }
        try completeOperationWork(.init(identity:receipt.identity,fingerprint:receipt.fingerprint,state:state,receipt:receipt),now:now)
    }
    // Reconfirmation can refresh a displayed baseline, never silently change the proposal.
    static func sameGroupCapabilityProposal(_ old:V2GroupCapabilityAction,_ new:V2GroupCapabilityAction) -> Bool {
        switch (old,new) {
        case let (.pin(a,b,_),.pin(c,d,_)): return a==c && b==d
        case let (.announcement(a,_),.announcement(b,_)): return a==b
        case let (.rolePermissions(a,b,_),.rolePermissions(c,d,_)): return a==c && b==d
        case let (.memberRole(a,b,_),.memberRole(c,d,_)): return a==c && b==d
        default: return false
        }
    }
    func replaceGroupCapabilityDraft(id:UUID,intent:V2GroupCapabilityIntent,activationID:UUID,now:Date) throws -> UUID {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(intent),identity=intent.identity,key=try Self.groupCapabilityOrderingKey(intent),time=try Self.commandRetryTimestamp(now)
        guard bytes.count<=32768,Double(intent.confirmedUntilMilliseconds)/1000>time,Double(intent.confirmedUntilMilliseconds)/1000-time<=120.001 else { throw V2GroupCapabilityValidationError.invalidIntent }
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_group_capability_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let previous=try Self.decodeGroupCapability(row,db:db)
            guard previous.work==nil,previous.preparationState == .paused,previous.intent.identity.accountID==intent.identity.accountID,previous.intent.roomID==intent.roomID,Self.sameGroupCapabilityProposal(previous.intent.action,intent.action) else { throw V2OperationWorkError.invalidTransition }
            try Self.requireOperationCapacity(adding:Self.groupCapabilityReservation,excludingIntent:id,limits:.init(),db:db)
            let replacement=UUID()
            try db.execute(sql:"UPDATE v2_group_capability_intents SET preparation_state='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
            try db.execute(sql:"INSERT INTO v2_group_capability_intents(intent_id,identity_key,account_id,room_id,ordering_key,intent,payload_bytes,confirmation_activation_id,preparation_state,preparation_next_at) VALUES(?,?,?,?,?,?,?,?,'ready',?)",arguments:[replacement.uuidString,identity.storageKey,intent.identity.accountID.rawValue,intent.roomID.rawValue,key,bytes,Self.groupCapabilityReservation,activationID.uuidString,max(previous.nextPreparationAt.timeIntervalSince1970,time)])
            return replacement
        }
    }
    func discardGroupCapabilityDraft(id:UUID,accountID:UserID) throws {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_group_capability_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeGroupCapability(row,db:db)
            guard pending.intent.identity.accountID==accountID,pending.work==nil else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql:"UPDATE v2_group_capability_intents SET preparation_state='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
        }
    }
}

extension GRDBV2LocalSyncStore {
    public nonisolated func groupCapabilityUpdates(roomID:RoomID) -> AsyncThrowingStream<[V2GroupCapabilityPending],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"SELECT i.* FROM v2_group_capability_intents i LEFT JOIN v2_operation_work w USING(work_id) WHERE i.room_id=? AND i.preparation_state<>'cancelled' ORDER BY CASE WHEN w.scheduling_state='finished' THEN 1 ELSE 0 END,i.local_sequence DESC LIMIT 2200",arguments:[roomID.rawValue]).map { try Self.decodeGroupCapability($0,db:db) }
                    }.removeDuplicates()
                    for try await value in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
    func groupCapabilityPreparationSchedule() -> V2CommandRetrySchedule {
        let pool=databasePool,query="SELECT MIN(preparation_next_at) FROM v2_group_capability_intents WHERE preparation_state='ready'"
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
