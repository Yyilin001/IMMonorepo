import Foundation
import GRDB
import IMV2Core

public struct V2MessageModerationPending:Equatable,Sendable {
    public let work:V2OperationWork
    public let intent:V2MessageModerationIntent
    public let activationID:UUID
    public let admission:V2MessageModerationAdmission?
    public let receipt:V2MessageModerationReceipt?
}
extension GRDBV2LocalSyncStore {
    static let messageModerationWorkSchemaSQL="""
    CREATE TABLE v2_message_moderation_operations (
      work_id TEXT PRIMARY KEY REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
      activation_id TEXT NOT NULL,
      intent BLOB NOT NULL CHECK(length(intent)>0 AND length(intent)<=4096),
      admission BLOB CHECK(admission IS NULL OR length(admission)<=4096)
    );
    """
    func enqueueMessageModeration(_ intent:V2MessageModerationIntent,activationID:UUID,now:Date=Date()) throws -> UUID {
        let identity=try intent.identity,fingerprint=try intent.fingerprint
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(intent)
        guard bytes.count<=4096 else { throw V2OperationWorkError.invalidRecord }
        return try databasePool.write { db in
            if let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_operation_work WHERE identity_key=?",arguments:[identity.storageKey]) {
                let work=try Self.decodeOperationWork(row)
                guard work.identity==identity,work.fingerprint==fingerprint else { throw V2OperationWorkError.identityConflict }
                return work.id
            }
            let key="messageModeration:"+intent.roomID.rawValue+":"+intent.messageID.rawValue
            guard try Int.fetchOne(db,sql:"SELECT count(*) FROM v2_operation_work WHERE ordering_key=? AND scheduling_state<>'finished'",arguments:[key])==0 else { throw V2OperationWorkError.invalidTransition }
            let id=UUID()
            try Self.insertOperationWork(.init(id:id,intentID:id,identity:identity,fingerprint:fingerprint,orderingKey:key,payloadBytes:73_728,admissionDeadline:Date(timeIntervalSince1970:Double(intent.confirmedUntilMilliseconds)/1000)),now:now,db:db)
            try db.execute(sql:"INSERT INTO v2_message_moderation_operations(work_id,activation_id,intent) VALUES(?,?,?)",arguments:[id.uuidString,activationID.uuidString,bytes])
            return id
        }
    }
    static func decodeMessageModerationPending(_ row:Row) throws -> V2MessageModerationPending {
        let work=try Self.decodeOperationWork(row)
        let intent=try JSONDecoder().decode(V2MessageModerationIntent.self,from:row["intent"])
        guard let activation=UUID(uuidString:row["activation_id"]),try intent.identity==work.identity,try intent.fingerprint==work.fingerprint else { throw V2OperationWorkError.identityConflict }
        let admission=try (row["admission"] as Data?).map { try JSONDecoder().decode(V2MessageModerationAdmission.self,from:$0) }
        let receipt=try (row["terminal_receipt"] as Data?).map { try JSONDecoder().decode(V2MessageModerationReceipt.self,from:$0) }
        guard admission?.validates(intent:intent) != false,receipt?.validates(intent:intent) != false else { throw V2OperationWorkError.identityConflict }
        return .init(work:work,intent:intent,activationID:activation,admission:admission,receipt:receipt)
    }
    public func messageModerationPending(id:UUID) throws -> V2MessageModerationPending {
        try databasePool.read { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT w.*,s.intent,s.activation_id,s.admission FROM v2_message_moderation_operations s JOIN v2_operation_work w USING(work_id) WHERE w.work_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            return try Self.decodeMessageModerationPending(row)
        }
    }
    func saveMessageModerationAdmission(_ admission:V2MessageModerationAdmission,claim:V2OperationWorkClaim) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(admission)
        guard bytes.count<=4096 else { throw V2OperationWorkError.invalidRecord }
        try databasePool.write { db in
            try Self.requireOperationClaim(claim,db:db)
            guard let row=try Row.fetchOne(db,sql:"SELECT w.*,s.intent,s.activation_id,s.admission FROM v2_message_moderation_operations s JOIN v2_operation_work w USING(work_id) WHERE w.work_id=?",arguments:[claim.work.id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeMessageModerationPending(row)
            guard admission.validates(intent:pending.intent),pending.admission==nil || pending.admission==admission else { throw V2OperationWorkError.identityConflict }
            try db.execute(sql:"UPDATE v2_message_moderation_operations SET admission=? WHERE work_id=?",arguments:[bytes,claim.work.id.uuidString])
        }
    }
    func completeMessageModeration(_ receipt:V2MessageModerationReceipt,id:UUID,now:Date=Date()) throws {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT w.*,s.intent,s.activation_id,s.admission FROM v2_message_moderation_operations s JOIN v2_operation_work w USING(work_id) WHERE w.work_id=?",arguments:[id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let pending=try Self.decodeMessageModerationPending(row)
            guard receipt.validates(intent:pending.intent) else { throw V2MessageModerationValidationError.invalidReceipt }
            let state:V2OperationExecutionState
            switch receipt.outcome {
            case .redacted,.alreadySatisfied:state = .committed
            case .closed:state = .closed
            case .rejected(.messageChanged),.rejected(.membershipChanged):state = .conflicted
            case .rejected:state = .rejected
            }
            try Self.completeOperationWork(.init(identity:pending.work.identity,fingerprint:pending.work.fingerprint,state:state,receipt:receipt),now:now,db:db)
        }
    }
    public nonisolated func messageModerationUpdates() -> AsyncThrowingStream<[V2MessageModerationPending],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"SELECT w.*,s.intent,s.activation_id,s.admission FROM v2_message_moderation_operations s JOIN v2_operation_work w USING(work_id) ORDER BY CASE WHEN w.scheduling_state<>'finished' THEN 0 ELSE 1 END,w.local_sequence DESC LIMIT 2200").map(Self.decodeMessageModerationPending)
                    }.removeDuplicates()
                    for try await values in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(values) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={_ in task.cancel()}
        }
    }
}
