import Foundation
import GRDB
import IMV2Core

public enum V2MemberAdministrationAdmissionError:Error,Sendable { case confirmationRequired }
public enum V2MemberAdministrationPreparationState:String,Sendable { case ready,paused,cancelled,frozen }
public struct V2MemberAdministrationPending:Equatable,Sendable {
    public let id:UUID
    public let intent:V2MemberAdministrationIntent
    public let command:V2MemberAdministrationCommand?
    public let work:V2OperationWork?
    public let preparationState:V2MemberAdministrationPreparationState
    public let preparationAttempts:Int
    public let nextPreparationAt:Date
    public let confirmationActivationID:UUID
    public let preparationCode:String?
    public var confirmationRequired:Bool { preparationState == .paused }
}
extension GRDBV2LocalSyncStore {
    static let memberAdministrationReservation:Int64=2*4_096+65_536
    static let memberAdministrationWorkSchemaSQL="""
        CREATE TABLE v2_member_administration_intents (
            local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            intent_id TEXT NOT NULL UNIQUE,identity_key TEXT NOT NULL UNIQUE,
            account_id TEXT NOT NULL,room_id TEXT NOT NULL,target_user_id TEXT NOT NULL,ordering_key TEXT NOT NULL,
            intent BLOB NOT NULL CHECK(length(intent)<=4096),command BLOB CHECK(length(command)<=4096),
            work_id TEXT UNIQUE REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            payload_bytes INTEGER NOT NULL CHECK(payload_bytes=73728),confirmation_activation_id TEXT NOT NULL,
            preparation_state TEXT NOT NULL CHECK(preparation_state IN ('ready','paused','cancelled','frozen')),
            preparation_attempts INTEGER NOT NULL DEFAULT 0 CHECK(preparation_attempts BETWEEN 0 AND 5),
            preparation_next_at REAL NOT NULL,preparation_deadline REAL,last_preparation_code TEXT,
            CHECK((work_id IS NOT NULL)=(command IS NOT NULL)),CHECK((work_id IS NOT NULL)=(preparation_state='frozen'))
        );
        CREATE INDEX v2_member_administration_ready ON v2_member_administration_intents(preparation_next_at,local_sequence) WHERE preparation_state='ready';
        CREATE INDEX v2_member_administration_order ON v2_member_administration_intents(ordering_key,local_sequence);
        """
    static func memberAdministrationOrderingKey(_ intent:V2MemberAdministrationIntent) throws -> String {
        "member-admin:"+String(decoding:try JSONEncoder().encode([intent.actorUserID.rawValue,intent.roomID.rawValue,intent.targetUserID.rawValue]),as:UTF8.self)
    }
    func enqueueMemberAdministration(_ intent:V2MemberAdministrationIntent,activationID:UUID,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(intent),identity=try intent.identity,key=try Self.memberAdministrationOrderingKey(intent),time=try Self.commandRetryTimestamp(now)
        guard bytes.count<=4_096,Double(intent.confirmedUntilMilliseconds)/1_000>time,
            Double(intent.confirmedUntilMilliseconds)/1_000-time<=120.001 else { throw V2MemberAdministrationValidationError.invalidIntent }
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==intent.actorUserID.rawValue else { throw V2OperationWorkError.accountMismatch }
            if let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_member_administration_intents WHERE identity_key=?",arguments:[identity.storageKey]) {
                let existing=try Self.decodeMemberAdministration(row,db:db)
                guard existing.intent==intent else { throw V2OperationWorkError.identityConflict };return existing.id
            }
            guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM v2_member_administration_intents i LEFT JOIN v2_operation_work w USING(work_id) WHERE i.ordering_key=? AND i.preparation_state<>'cancelled' AND (i.work_id IS NULL OR w.scheduling_state<>'finished'))",arguments:[key])==false else { throw V2MemberAdministrationAdmissionError.confirmationRequired }
            try Self.requireOperationCapacity(adding:Self.memberAdministrationReservation,limits:limits,db:db)
            let id=UUID()
            try db.execute(sql:"INSERT INTO v2_member_administration_intents(intent_id,identity_key,account_id,room_id,target_user_id,ordering_key,intent,payload_bytes,confirmation_activation_id,preparation_state,preparation_next_at) VALUES(?,?,?,?,?,?,?,?,?,'ready',?)",arguments:[id.uuidString,identity.storageKey,intent.actorUserID.rawValue,intent.roomID.rawValue,intent.targetUserID.rawValue,key,bytes,Self.memberAdministrationReservation,activationID.uuidString,time])
            return id
        }
    }
    static func decodeMemberAdministration(_ row:Row,db:Database) throws -> V2MemberAdministrationPending {
        guard let id=UUID(uuidString:row["intent_id"]),let activation=UUID(uuidString:row["confirmation_activation_id"]),
            let state=V2MemberAdministrationPreparationState(rawValue:row["preparation_state"]) else { throw V2OperationWorkError.invalidRecord }
        let intent=try JSONDecoder().decode(V2MemberAdministrationIntent.self,from:row["intent"])
        guard try intent.identity.storageKey==row["identity_key"] as String,intent.actorUserID.rawValue==row["account_id"] as String,
            intent.roomID.rawValue==row["room_id"] as String,intent.targetUserID.rawValue==row["target_user_id"] as String,
            try memberAdministrationOrderingKey(intent)==row["ordering_key"] as String else { throw V2OperationWorkError.identityConflict }
        let command=try (row["command"] as Data?).map { try JSONDecoder().decode(V2MemberAdministrationCommand.self,from:$0) }
        let work=try (row["work_id"] as String?).map { value -> V2OperationWork in
            guard let id=UUID(uuidString:value) else { throw V2OperationWorkError.invalidRecord };return try requireOperationWork(id,db:db)
        }
        if let command,let work { guard command.intent==intent,try command.identity==work.identity,try command.fingerprint==work.fingerprint else { throw V2OperationWorkError.identityConflict } }
        let attempts:Int=row["preparation_attempts"]
        guard (0...5).contains(attempts),(command != nil)==(work != nil),(work != nil)==(state == .frozen) else { throw V2OperationWorkError.invalidRecord }
        return .init(id:id,intent:intent,command:command,work:work,preparationState:state,preparationAttempts:attempts,nextPreparationAt:Date(timeIntervalSince1970:row["preparation_next_at"]),confirmationActivationID:activation,preparationCode:row["last_preparation_code"])
    }
    func memberAdministrationPending(id:UUID) throws -> V2MemberAdministrationPending {
        try databasePool.read { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_member_administration_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord };return try Self.decodeMemberAdministration(row,db:db) }
    }
    func beginMemberAdministrationPreparation(now:Date=Date()) throws -> V2MemberAdministrationPending? {
        let time=try Self.commandRetryTimestamp(now)
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_member_administration_intents WHERE preparation_state='ready' AND preparation_next_at<=? ORDER BY local_sequence LIMIT 1",arguments:[time]) else { return nil }
            let pending=try Self.decodeMemberAdministration(row,db:db),deadline:Double?=row["preparation_deadline"]
            guard pending.preparationAttempts<5,deadline.map({$0>time}) ?? true,Double(pending.intent.confirmedUntilMilliseconds)/1_000>time else {
                try db.execute(sql:"UPDATE v2_member_administration_intents SET preparation_state='paused',last_preparation_code='CONFIRMATION_REQUIRED' WHERE intent_id=?",arguments:[pending.id.uuidString]);return nil
            }
            let end=min(deadline ?? time+60,Double(pending.intent.confirmedUntilMilliseconds)/1_000)
            try db.execute(sql:"UPDATE v2_member_administration_intents SET preparation_attempts=preparation_attempts+1,preparation_deadline=? WHERE intent_id=?",arguments:[end,pending.id.uuidString])
            return try Self.decodeMemberAdministration(Row.fetchOne(db,sql:"SELECT * FROM v2_member_administration_intents WHERE intent_id=?",arguments:[pending.id.uuidString])!,db:db)
        }
    }
    func pauseMemberAdministrationPreparation(id:UUID,until:Date=Date(),code:String,paused:Bool=true) throws {
        let time=try Self.commandRetryTimestamp(until)
        try databasePool.write { db in try db.execute(sql:"UPDATE v2_member_administration_intents SET preparation_state=?,preparation_next_at=MAX(preparation_next_at,?),last_preparation_code=? WHERE intent_id=? AND preparation_state='ready' AND work_id IS NULL",arguments:[paused ? "paused":"ready",time,code,id.uuidString]) }
    }
    func freezeMemberAdministration(id:UUID,admission:V2MemberAdministrationAdmission,now:Date=Date(),limits:V2OperationWorkLimits = .init()) throws -> UUID? {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_member_administration_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeMemberAdministration(row,db:db)
            guard pending.preparationState == .ready,pending.work==nil else { return nil }
            let command=try V2MemberAdministrationCommand(intent:pending.intent,admission:admission),encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let bytes=try encoder.encode(command)
            guard bytes.count<=4_096 else { throw V2OperationWorkError.invalidRecord }
            let workID=UUID()
            _ = try Self.insertOperationWork(.init(id:workID,intentID:id,identity:command.identity,fingerprint:command.fingerprint,orderingKey:row["ordering_key"],payloadBytes:Self.memberAdministrationReservation,admissionDeadline:Date(timeIntervalSince1970:Double(admission.expiresAtMilliseconds)/1_000)),now:now,limits:limits,db:db)
            try db.execute(sql:"UPDATE v2_member_administration_intents SET command=?,work_id=?,preparation_state='frozen' WHERE intent_id=?",arguments:[bytes,workID.uuidString,id.uuidString])
            return workID
        }
    }
    func memberAdministrationCommand(workID:UUID) throws -> V2MemberAdministrationCommand {
        try databasePool.read { db in guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_member_administration_intents WHERE work_id=?",arguments:[workID.uuidString]),let command=try Self.decodeMemberAdministration(row,db:db).command else { throw V2OperationWorkError.invalidRecord };return command }
    }
    func completeMemberAdministration(_ receipt:V2MemberAdministrationReceipt,command:V2MemberAdministrationCommand,now:Date=Date()) throws {
        guard receipt.validates(command:command) else { throw V2MemberAdministrationValidationError.invalidReceipt }
        let state:V2OperationExecutionState
        switch receipt.outcome { case .applied,.alreadySatisfied:state = .committed;case .closed:state = .closed;case .rejected(.membershipChanged):state = .conflicted;case .rejected:state = .rejected }
        try completeOperationWork(.init(identity:receipt.identity,fingerprint:receipt.fingerprint,state:state,receipt:receipt),now:now)
    }
    func replaceMemberAdministrationDraft(id:UUID,intent:V2MemberAdministrationIntent,activationID:UUID,now:Date) throws -> UUID {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(intent),identity=try intent.identity,key=try Self.memberAdministrationOrderingKey(intent),time=try Self.commandRetryTimestamp(now)
        guard bytes.count<=4096,Double(intent.confirmedUntilMilliseconds)/1000>time,Double(intent.confirmedUntilMilliseconds)/1000-time<=120.001 else { throw V2MemberAdministrationValidationError.invalidIntent }
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_member_administration_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let previous=try Self.decodeMemberAdministration(row,db:db)
            guard previous.work==nil,previous.preparationState == .paused,previous.intent.actorUserID==intent.actorUserID,previous.intent.targetUserID==intent.targetUserID,previous.intent.roomID==intent.roomID,previous.intent.action==intent.action else { throw V2OperationWorkError.invalidTransition }
            try Self.requireOperationCapacity(adding:Self.memberAdministrationReservation,excludingIntent:id,limits:.init(),db:db)
            let replacement=UUID()
            try db.execute(sql:"UPDATE v2_member_administration_intents SET preparation_state='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
            try db.execute(sql:"INSERT INTO v2_member_administration_intents(intent_id,identity_key,account_id,room_id,target_user_id,ordering_key,intent,payload_bytes,confirmation_activation_id,preparation_state,preparation_next_at) VALUES(?,?,?,?,?,?,?,?,?,'ready',?)",arguments:[replacement.uuidString,identity.storageKey,intent.actorUserID.rawValue,intent.roomID.rawValue,intent.targetUserID.rawValue,key,bytes,Self.memberAdministrationReservation,activationID.uuidString,max(previous.nextPreparationAt.timeIntervalSince1970,time)])
            return replacement
        }
    }
    func discardMemberAdministrationDraft(id:UUID,accountID:UserID) throws {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_member_administration_intents WHERE intent_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeMemberAdministration(row,db:db)
            guard pending.intent.actorUserID==accountID,pending.work==nil else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql:"UPDATE v2_member_administration_intents SET preparation_state='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
        }
    }
}

extension GRDBV2LocalSyncStore {
    public nonisolated func memberAdministrationUpdates(roomID:RoomID) -> AsyncThrowingStream<[V2MemberAdministrationPending],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"SELECT i.* FROM v2_member_administration_intents i LEFT JOIN v2_operation_work w USING(work_id) WHERE i.room_id=? AND i.preparation_state<>'cancelled' ORDER BY CASE WHEN w.scheduling_state='finished' THEN 1 ELSE 0 END,i.local_sequence DESC LIMIT 2200",arguments:[roomID.rawValue]).map { try Self.decodeMemberAdministration($0,db:db) }
                    }.removeDuplicates()
                    for try await value in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
    func memberAdministrationPreparationSchedule() -> V2CommandRetrySchedule {
        let pool=databasePool,query="SELECT MIN(preparation_next_at) FROM v2_member_administration_intents WHERE preparation_state='ready'"
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
