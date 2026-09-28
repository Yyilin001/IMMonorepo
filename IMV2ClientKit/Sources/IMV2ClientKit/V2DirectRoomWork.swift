import Foundation
import GRDB
import IMV2Core

public struct V2DirectRoomPending:Equatable,Sendable {
    public let work:V2OperationWork
    public let command:V2DirectRoomOperationCommand
    public let receipt:V2DirectRoomOperationReceipt?
}
extension GRDBV2LocalSyncStore {
    static let directRoomWorkSchemaSQL="""
    CREATE TABLE v2_direct_room_operations (
      work_id TEXT PRIMARY KEY REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
      target_user_id TEXT NOT NULL,
      public_identity BLOB NOT NULL CHECK(length(public_identity)>0 AND length(public_identity)<=16384),
      command BLOB NOT NULL CHECK(length(command)>0 AND length(command)<=4096)
    );
    CREATE INDEX v2_direct_room_operations_target ON v2_direct_room_operations(target_user_id);
    """
    @discardableResult public func enqueueDirectRoomOperation(_ command:V2DirectRoomOperationCommand,publicIdentity:V2PublicIdentity,now:Date=Date()) throws -> UUID {
        let identity=try command.identity,fingerprint=try command.fingerprint
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(command),profile=try encoder.encode(publicIdentity)
        guard publicIdentity.userID==command.targetUserID,profile.count<=16384,bytes.count<=4096 else { throw V2OperationWorkError.invalidRecord }
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==command.actorUserID.rawValue else { throw V2OperationWorkError.accountMismatch }
            if let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_operation_work WHERE identity_key=?",arguments:[identity.storageKey]) {
                let work=try Self.decodeOperationWork(row)
                guard work.fingerprint==fingerprint else { throw V2OperationWorkError.identityConflict };return work.id
            }
            // Repeated taps reuse the original unknown operation, including its deadline.
            if let active=try String.fetchOne(db,sql:"SELECT w.work_id FROM v2_direct_room_operations s JOIN v2_operation_work w USING(work_id) WHERE s.target_user_id=? AND w.scheduling_state<>'finished' ORDER BY w.local_sequence LIMIT 1",arguments:[command.targetUserID.rawValue]) {
                guard let id=UUID(uuidString:active) else { throw V2OperationWorkError.invalidRecord }
                return id
            }
            let id=UUID()
            try Self.insertOperationWork(.init(id:id,intentID:id,identity:identity,fingerprint:fingerprint,orderingKey:"directRoom:"+command.actorUserID.rawValue+":"+command.targetUserID.rawValue,payloadBytes:Int64(bytes.count+profile.count)+65_536,admissionDeadline:Date(timeIntervalSince1970:Double(command.firstSubmissionDeadlineMilliseconds)/1000)),now:now,limits:.init(),db:db)
            try db.execute(sql:"INSERT INTO v2_direct_room_operations(work_id,target_user_id,command,public_identity) VALUES(?,?,?,?)",arguments:[id.uuidString,command.targetUserID.rawValue,bytes,profile])
            return id
        }
    }
    func directRoomCommand(workID:UUID) throws -> V2DirectRoomOperationCommand {
        try databasePool.read { db in
            guard let bytes=try Data.fetchOne(db,sql:"SELECT command FROM v2_direct_room_operations WHERE work_id=?",arguments:[workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            return try JSONDecoder().decode(V2DirectRoomOperationCommand.self,from:bytes)
        }
    }
    func completeDirectRoom(_ receipt:V2DirectRoomOperationReceipt,workID:UUID,now:Date=Date()) throws {
        try databasePool.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT w.*,s.command,s.public_identity,s.target_user_id FROM v2_direct_room_operations s JOIN v2_operation_work w USING(work_id) WHERE w.work_id=?",arguments:[workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let work=try Self.decodeOperationWork(row)
            let command=try JSONDecoder().decode(V2DirectRoomOperationCommand.self,from:row["command"])
            guard try command.identity==work.identity,try command.fingerprint==work.fingerprint,receipt.validates(command:command) else { throw V2OperationWorkError.identityConflict }
            let state:V2OperationExecutionState
            switch receipt.outcome { case .opened:state = .committed;case .closed:state = .closed;case .rejected:state = .rejected }
            let outcome=try V2VerifiedOperationOutcome(identity:work.identity,fingerprint:work.fingerprint,state:state,receipt:receipt)
            // Duplicate callbacks must not republish a room after later authorization changes.
            if !work.execution.isTerminal,case .opened(let roomID,let created)=receipt.outcome {
                let profile=try JSONDecoder().decode(V2PublicIdentity.self,from:row["public_identity"])
                guard profile.userID==command.targetUserID else { throw V2OperationWorkError.identityConflict }
                try Self.cacheDirectRoomIdentity(roomID:roomID,publicIdentity:profile,roomCreatedAt:Date(timeIntervalSince1970:Double(created)/1000),updatedAt:now,db:db)
            }
            try Self.completeOperationWork(outcome,now:now,db:db)
        }
    }
    func directRoomReceipt(workID:UUID,accountID:UserID) throws -> V2DirectRoomOperationReceipt? {
        try databasePool.read { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT w.*,s.command FROM v2_direct_room_operations s JOIN v2_operation_work w USING(work_id) WHERE w.work_id=?",arguments:[workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let work=try Self.decodeOperationWork(row)
            guard work.identity.accountID==accountID else { throw V2OperationWorkError.accountMismatch }
            let command=try JSONDecoder().decode(V2DirectRoomOperationCommand.self,from:row["command"])
            guard try command.identity==work.identity,try command.fingerprint==work.fingerprint else { throw V2OperationWorkError.identityConflict }
            guard let bytes:Data=row["terminal_receipt"] else { return nil }
            let receipt=try JSONDecoder().decode(V2DirectRoomOperationReceipt.self,from:bytes)
            guard receipt.validates(command:command) else { throw V2DirectRoomOperationValidationError.invalidReceipt }
            return receipt
        }
    }
    public nonisolated func directRoomUpdates() -> AsyncThrowingStream<[V2DirectRoomPending],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try Row.fetchAll(db,sql:"SELECT w.*,s.command,s.target_user_id FROM v2_direct_room_operations s JOIN v2_operation_work w USING(work_id) ORDER BY CASE WHEN w.scheduling_state<>'finished' THEN 0 ELSE 1 END,w.local_sequence DESC LIMIT 2200").map { row in
                            let work=try Self.decodeOperationWork(row),command=try JSONDecoder().decode(V2DirectRoomOperationCommand.self,from:row["command"])
                            guard try command.identity==work.identity,try command.fingerprint==work.fingerprint,command.targetUserID.rawValue==row["target_user_id"] as String else { throw V2OperationWorkError.identityConflict }
                            let receipt=try (row["terminal_receipt"] as Data?).map { try JSONDecoder().decode(V2DirectRoomOperationReceipt.self,from:$0) }
                            guard receipt?.validates(command:command) != false else { throw V2DirectRoomOperationValidationError.invalidReceipt }
                            return V2DirectRoomPending(work:work,command:command,receipt:receipt)
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
