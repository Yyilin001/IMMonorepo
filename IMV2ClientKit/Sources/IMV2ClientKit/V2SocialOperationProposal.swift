import Foundation
import GRDB
import IMV2Core

/// A durable proposal has no authorization, expected revision or execution claim.
public struct V2SocialOperationProposal:Equatable,Sendable {
    public let id:UUID
    public let targetUserID:UserID
    public let action:V2SocialOperationAction
}
extension GRDBV2LocalSyncStore {
    static let socialProposalSchemaSQL="""
    CREATE TABLE v2_social_operation_proposals (
      local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,intent_id TEXT UNIQUE NOT NULL,account_id TEXT NOT NULL,
      target_user_id TEXT NOT NULL,action BLOB NOT NULL CHECK(length(action)<=4096),
      payload_bytes INTEGER NOT NULL CHECK(payload_bytes=73728),
      state TEXT NOT NULL CHECK(state IN ('pending','frozen','cancelled')),
      work_id TEXT UNIQUE REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
      CHECK((state='frozen')=(work_id IS NOT NULL))
    );
    CREATE INDEX v2_social_proposals_pending ON v2_social_operation_proposals(local_sequence) WHERE state='pending';
    """
    func enqueueSocialProposal(accountID:UserID,target:UserID,action:V2SocialOperationAction) throws -> UUID {
        let bytes=try JSONEncoder().encode(action)
        guard target.uuidValue != nil,target != accountID,bytes.count<=4096 else { throw V2SocialOperationValidationError.invalidCommand }
        return try databasePool.write { db in
            guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            if let row=try Row.fetchOne(db,sql:"SELECT intent_id,action FROM v2_social_operation_proposals WHERE account_id=? AND target_user_id=? AND state='pending' ORDER BY local_sequence DESC LIMIT 1",arguments:[accountID.rawValue,target.rawValue]) {
                guard try JSONDecoder().decode(V2SocialOperationAction.self,from:row["action"])==action,let id=UUID(uuidString:row["intent_id"]) else { throw V2OperationWorkError.invalidTransition };return id
            }
            try Self.requireOperationCapacity(adding:73_728,db:db)
            let id=UUID();try db.execute(sql:"INSERT INTO v2_social_operation_proposals(intent_id,account_id,target_user_id,action,payload_bytes,state) VALUES(?,?,?,?,73728,'pending')",arguments:[id.uuidString,accountID.rawValue,target.rawValue,bytes]);return id
        }
    }
    func socialProposal(id:UUID,accountID:UserID) throws -> V2SocialOperationProposal {
        try databasePool.read { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT * FROM v2_social_operation_proposals WHERE intent_id=? AND account_id=? AND state='pending'",arguments:[id.uuidString,accountID.rawValue]) else { throw V2OperationWorkError.invalidTransition }
            return try Self.decodeSocialProposal(row)
        }
    }
    static func decodeSocialProposal(_ row:Row) throws -> V2SocialOperationProposal {
        guard let id=UUID(uuidString:row["intent_id"]) else { throw V2OperationWorkError.invalidRecord }
        return .init(id:id,targetUserID:try .init(row["target_user_id"]),action:try JSONDecoder().decode(V2SocialOperationAction.self,from:row["action"]))
    }
    func discardSocialProposal(id:UUID,accountID:UserID) throws {
        try databasePool.write { db in
            guard try Int.fetchOne(db,sql:"SELECT count(*) FROM v2_social_operation_proposals WHERE intent_id=? AND account_id=? AND state='pending'",arguments:[id.uuidString,accountID.rawValue])==1 else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql:"UPDATE v2_social_operation_proposals SET state='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
        }
    }
    public nonisolated func socialProposalUpdates() -> AsyncThrowingStream<[V2SocialOperationProposal],any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task { do {
                let observation=ValueObservation.tracking { db in try Row.fetchAll(db,sql:"SELECT * FROM v2_social_operation_proposals WHERE state='pending' ORDER BY local_sequence LIMIT 2000").map(Self.decodeSocialProposal) }.removeDuplicates()
                for try await value in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(value) };continuation.finish()
            } catch { continuation.finish(throwing:error) } };continuation.onTermination={_ in task.cancel()}
        }
    }
}
