import Foundation
import GRDB
import IMV2Core

/// Only fields explicitly changed by this click. Baseline preparation preserves the rest.
public enum V2AccountPreferencePatch:Codable,Equatable,Sendable {
    case strangerMessage(V2StrangerMessagePermission),userAdd(V2UserAddPermission)
    case readReceipt(direct:Bool?,group:Bool?)
    case liveActivity(online:Bool?,typing:Bool?)
    public var kind:V2OperationKind { switch self { case .strangerMessage:.strangerMessagePreference;case .userAdd:.userAddPreference;case .readReceipt:.readReceiptPreference;case .liveActivity:.liveActivityPreference } }
    func applying(to snapshot:V2AccountPreferenceSnapshot) throws -> V2AccountPreferenceValue {
        switch (self,snapshot.value) {
        case (.strangerMessage(let value),.strangerMessage):return .strangerMessage(value)
        case (.userAdd(let value),.userAdd):return .userAdd(value)
        case (.readReceipt(let direct,let group),.readReceipt(let oldDirect,let oldGroup)) where direct != nil || group != nil:return .readReceipt(allowsDirectReadReceipts:direct ?? oldDirect,allowsGroupReadReceipts:group ?? oldGroup)
        case (.liveActivity(let online,let typing),.liveActivity(let oldOnline,let oldTyping)) where online != nil || typing != nil:return .liveActivity(allowsOnlinePresence:online ?? oldOnline,allowsTypingIndicators:typing ?? oldTyping)
        default:throw V2AccountPreferenceValidationError.invalidCommand
        }
    }
}
public struct V2AccountPreferenceDraft:Equatable,Sendable {
    public let id:UUID
    public let patch:V2AccountPreferencePatch
    public let activationID:UUID
    public let deadline:Date
    public let attempts:Int
    public let nextAt:Date
    public let paused:Bool
}
extension GRDBV2LocalSyncStore {
    static let accountPreferenceDraftReservation:Int64=73_728
    static let accountPreferenceDraftSchemaSQL="""
    CREATE TABLE v2_account_preference_intents (
      local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,intent_id TEXT UNIQUE NOT NULL,
      account_id TEXT NOT NULL,preference_kind TEXT NOT NULL,patch BLOB NOT NULL CHECK(length(patch)<=4096),
      activation_id TEXT NOT NULL,deadline REAL NOT NULL,payload_bytes INTEGER NOT NULL CHECK(payload_bytes=73728),
      work_id TEXT UNIQUE REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
      state TEXT NOT NULL CHECK(state IN ('ready','paused','frozen','cancelled')),
      attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),next_at REAL NOT NULL,round_deadline REAL
    );
    CREATE INDEX v2_account_preference_intents_ready ON v2_account_preference_intents(next_at,local_sequence) WHERE state='ready';
    """
    func enqueueAccountPreferenceDraft(accountID:UserID,patch:V2AccountPreferencePatch,activationID:UUID,id:UUID=UUID(),now:Date=Date()) throws -> UUID {
        let bytes=try JSONEncoder().encode(patch);guard bytes.count<=4096 else { throw V2OperationWorkError.invalidRecord }
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            // Frozen unknowns are never superseded; their original proof must be reconciled.
            guard try Int.fetchOne(db,sql:"SELECT count(*) FROM v2_account_preference_operations s JOIN v2_operation_work w USING(work_id) WHERE preference_kind=? AND w.scheduling_state<>'finished'",arguments:[patch.kind.rawValue])==0,
                  try Int.fetchOne(db,sql:"SELECT count(*) FROM v2_account_preference_intents WHERE preference_kind=? AND work_id IS NULL AND state<>'cancelled'",arguments:[patch.kind.rawValue])==0 else { throw V2OperationWorkError.invalidTransition }
            try Self.requireOperationCapacity(adding:Self.accountPreferenceDraftReservation,db:db)
            try db.execute(sql:"INSERT INTO v2_account_preference_intents(intent_id,account_id,preference_kind,patch,activation_id,deadline,payload_bytes,state,next_at) VALUES(?,?,?,?,?,?,?,'ready',?)",arguments:[id.uuidString,accountID.rawValue,patch.kind.rawValue,bytes,activationID.uuidString,now.addingTimeInterval(120).timeIntervalSince1970,Self.accountPreferenceDraftReservation,now.timeIntervalSince1970]);return id
        }
    }
    static func decodeAccountPreferenceDraft(_ row:Row) throws -> V2AccountPreferenceDraft {
        guard let id=UUID(uuidString:row["intent_id"]),let activation=UUID(uuidString:row["activation_id"]) else { throw V2OperationWorkError.invalidRecord }
        let patch=try JSONDecoder().decode(V2AccountPreferencePatch.self,from:row["patch"])
        guard patch.kind.rawValue==row["preference_kind"] as String else { throw V2OperationWorkError.invalidRecord }
        return .init(id:id,patch:patch,activationID:activation,deadline:Date(timeIntervalSince1970:row["deadline"]),attempts:row["attempts"],nextAt:Date(timeIntervalSince1970:row["next_at"]),paused:row["state"] as String == "paused")
    }
    func beginAccountPreferenceDraft(now:Date=Date()) throws -> V2AccountPreferenceDraft? {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_account_preference_intents WHERE state='ready' AND next_at<=? ORDER BY local_sequence LIMIT 1",arguments:[now.timeIntervalSince1970]) else { return nil }
            let draft=try Self.decodeAccountPreferenceDraft(row)
            let round=(row["round_deadline"] as Double?) ?? min(draft.deadline.timeIntervalSince1970,now.addingTimeInterval(60).timeIntervalSince1970)
            guard draft.attempts<5,now.timeIntervalSince1970<round else { try db.execute(sql:"UPDATE v2_account_preference_intents SET state='paused' WHERE intent_id=?",arguments:[draft.id.uuidString]);return nil }
            try db.execute(sql:"UPDATE v2_account_preference_intents SET attempts=attempts+1,round_deadline=? WHERE intent_id=?",arguments:[round,draft.id.uuidString])
            return try Row.fetchOne(db,sql:"SELECT * FROM v2_account_preference_intents WHERE intent_id=?",arguments:[draft.id.uuidString]).map(Self.decodeAccountPreferenceDraft)
        }
    }
    func deferAccountPreferenceDraft(id:UUID,until:Date,paused:Bool) throws {
        try databasePool.write { db in try db.execute(sql:"UPDATE v2_account_preference_intents SET state=?,next_at=MAX(next_at,?) WHERE intent_id=? AND state='ready'",arguments:[paused ? "paused" : "ready",until.timeIntervalSince1970,id.uuidString]) }
    }
    func freezeAccountPreferenceDraft(_ draft:V2AccountPreferenceDraft,command:V2AccountPreferenceCommand) throws -> UUID {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let bytes=try encoder.encode(command)
        return try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_account_preference_intents WHERE intent_id=? AND state='ready' AND work_id IS NULL",arguments:[draft.id.uuidString]),try Self.decodeAccountPreferenceDraft(row)==draft,command.identity.operation.rawOperationID.lowercased()==draft.id.uuidString.lowercased(),command.value.kind==draft.patch.kind,command.identity.accountID.rawValue==row["account_id"] as String,command.firstSubmissionDeadlineMilliseconds<=UInt64(draft.deadline.timeIntervalSince1970*1000) else { throw V2OperationWorkError.invalidTransition }
            let id=UUID()
            try Self.insertOperationWork(.init(id:id,intentID:draft.id,identity:command.identity,fingerprint:command.fingerprint,orderingKey:"accountPreference:"+command.identity.accountID.rawValue+":"+command.value.kind.rawValue,payloadBytes:Self.accountPreferenceDraftReservation,admissionDeadline:draft.deadline),now:Date(),limits:.init(),db:db)
            try db.execute(sql:"INSERT INTO v2_account_preference_operations(work_id,preference_kind,command) VALUES(?,?,?)",arguments:[id.uuidString,command.value.kind.rawValue,bytes])
            try db.execute(sql:"UPDATE v2_account_preference_intents SET state='frozen',work_id=? WHERE intent_id=?",arguments:[id.uuidString,draft.id.uuidString]);return id
        }
    }
    public nonisolated func accountPreferenceDraftUpdates() -> AsyncThrowingStream<[V2AccountPreferenceDraft],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task { do {
                let observation=ValueObservation.tracking { db in try Row.fetchAll(db,sql:"SELECT * FROM v2_account_preference_intents WHERE work_id IS NULL AND state<>'cancelled' ORDER BY local_sequence LIMIT 2000").map(Self.decodeAccountPreferenceDraft) }.removeDuplicates()
                for try await values in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(values) };continuation.finish()
            } catch { continuation.finish(throwing:error) } };continuation.onTermination={_ in task.cancel()}
        }
    }
    func accountPreferencePreparationSchedule() -> V2CommandRetrySchedule {
        let pool=databasePool
        return .init(nextAttemptAt:{ try await pool.read { db in try Double.fetchOne(db,sql:"SELECT MIN(next_at) FROM v2_account_preference_intents WHERE state='ready'").map(Date.init(timeIntervalSince1970:)) } },updates:{ AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task { do { let observation=ValueObservation.tracking { db in try Double.fetchOne(db,sql:"SELECT MIN(next_at) FROM v2_account_preference_intents WHERE state='ready'") }.removeDuplicates();for try await _ in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(()) };continuation.finish() } catch { continuation.finish(throwing:error) } };continuation.onTermination={_ in task.cancel()}
        } })
    }
    func reconfirmAccountPreferenceDraft(id:UUID,accountID:UserID,activationID:UUID,replacement:UUID=UUID(),now:Date=Date()) throws -> UUID {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_account_preference_intents WHERE intent_id=? AND account_id=? AND state='paused' AND work_id IS NULL",arguments:[id.uuidString,accountID.rawValue]) else { throw V2OperationWorkError.invalidTransition }
            let floor=max(now.timeIntervalSince1970,row["next_at"] as Double)
            try db.execute(sql:"UPDATE v2_account_preference_intents SET intent_id=?,activation_id=?,deadline=?,state='ready',attempts=0,next_at=?,round_deadline=NULL WHERE intent_id=?",arguments:[replacement.uuidString,activationID.uuidString,now.addingTimeInterval(120).timeIntervalSince1970,floor,id.uuidString]);return replacement
        }
    }
}

extension GRDBV2LocalSyncStore {
    /// Local tightening suppresses typing immediately; unconfirmed loosening never grants publication.
    public func allowsLocalTypingPublication() throws -> Bool {
        try databasePool.read {try Self.localPublicationPolicy(db:$0).allowsTypingIndicators}
    }
}

extension GRDBV2LocalSyncStore {
    func discardAccountPreferenceDraft(id:UUID,accountID:UserID) throws {
        try databasePool.write { db in
            guard try Int.fetchOne(db,sql:"SELECT count(*) FROM v2_account_preference_intents WHERE intent_id=? AND account_id=? AND work_id IS NULL AND state IN ('ready','paused')",arguments:[id.uuidString,accountID.rawValue])==1 else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql:"UPDATE v2_account_preference_intents SET state='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
        }
    }
}
