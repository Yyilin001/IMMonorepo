import Foundation
import GRDB
import IMV2Core

public struct V2AccountPreferencePending:Equatable,Sendable {
    public let work:V2OperationWork
    public let command:V2AccountPreferenceCommand
}
extension GRDBV2LocalSyncStore {
    static let accountPreferenceWorkSchemaSQL="""
    CREATE TABLE v2_account_preference_operations (
      work_id TEXT PRIMARY KEY REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
      preference_kind TEXT NOT NULL,
      command BLOB NOT NULL CHECK(length(command)>0 AND length(command)<=4096)
    );
    CREATE INDEX v2_account_preference_operations_target ON v2_account_preference_operations(preference_kind);
    """
    @discardableResult public func enqueueAccountPreference(_ command:V2AccountPreferenceCommand,now:Date=Date()) throws -> UUID {
        let identity=command.identity,fingerprint=try command.fingerprint
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(command)
        guard bytes.count<=4096 else { throw V2OperationWorkError.invalidRecord }
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==command.identity.accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            if let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_operation_work WHERE identity_key=?",arguments:[identity.storageKey]) {
                let work=try Self.decodeOperationWork(row)
                guard work.fingerprint==fingerprint else { throw V2OperationWorkError.identityConflict };return work.id
            }
            // A frozen operation cannot be merged with a later click or silently rebased.
            guard try Int.fetchOne(db,sql:"SELECT count(*) FROM v2_account_preference_operations s JOIN v2_operation_work w USING(work_id) WHERE s.preference_kind=? AND w.scheduling_state<>'finished'",arguments:[command.identity.kind.rawValue])==0 else { throw V2OperationWorkError.invalidTransition }
            let id=UUID()
            try Self.insertOperationWork(.init(id:id,intentID:id,identity:identity,fingerprint:fingerprint,orderingKey:"accountPreference:"+command.identity.accountID.rawValue+":"+command.identity.kind.rawValue,payloadBytes:Int64(bytes.count)+65_536,admissionDeadline:Date(timeIntervalSince1970:Double(command.firstSubmissionDeadlineMilliseconds)/1000)),now:now,limits:.init(),db:db)
            try db.execute(sql:"INSERT INTO v2_account_preference_operations(work_id,preference_kind,command) VALUES(?,?,?)",arguments:[id.uuidString,command.identity.kind.rawValue,bytes])
            return id
        }
    }
    func accountPreferenceCommand(workID:UUID) throws -> V2AccountPreferenceCommand {
        try databasePool.read { db in
            guard let bytes=try Data.fetchOne(db,sql:"SELECT command FROM v2_account_preference_operations WHERE work_id=?",arguments:[workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            return try JSONDecoder().decode(V2AccountPreferenceCommand.self,from:bytes)
        }
    }
    public nonisolated func accountPreferenceUpdates() -> AsyncThrowingStream<[V2AccountPreferencePending],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"SELECT w.*,s.command,s.preference_kind FROM v2_account_preference_operations s JOIN v2_operation_work w USING(work_id) ORDER BY CASE WHEN w.scheduling_state<>'finished' THEN 0 ELSE 1 END,w.local_sequence DESC LIMIT 2200").map { row in
                            let work=try Self.decodeOperationWork(row),command=try JSONDecoder().decode(V2AccountPreferenceCommand.self,from:row["command"])
                            guard command.identity==work.identity,try command.fingerprint==work.fingerprint,command.identity.kind.rawValue==row["preference_kind"] as String else { throw V2OperationWorkError.identityConflict }
                            return V2AccountPreferencePending(work:work,command:command)
                        }
                    }.removeDuplicates()
                    for try await values in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(values) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
}
