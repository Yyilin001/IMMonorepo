import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    public func backgroundSessionID() throws -> UUID {
        try databasePool.write { db in
            if let raw=try String.fetchOne(db,sql:"SELECT session_id FROM v2_background_transfer_session WHERE singleton=1"),let id=UUID(uuidString:raw) { return id }
            let id=UUID();try db.execute(sql:"INSERT INTO v2_background_transfer_session(singleton,session_id) VALUES(1,?)",arguments:[id.uuidString]);return id
        }
    }
    func activeBackgroundMappings(session:UUID) throws -> [V2BackgroundTaskMapping] {
        try databasePool.read { db in
            try Row.fetchAll(db,sql:"SELECT * FROM v2_background_transfer_tasks WHERE session_id=? AND state='active' ORDER BY created_at LIMIT 64",arguments:[session.uuidString]).map { row in
                guard let id=UUID(uuidString:row["mapping_id"]),let job=UUID(uuidString:row["job_id"]),let activation=UUID(uuidString:row["activation_id"]),let source=UUID(uuidString:row["source_token"]) else { throw V2BackgroundTransferError.mappingConflict }
                return .init(id:id,sessionID:session,jobID:job,activationID:activation,sourceToken:source,taskIdentifier:row["task_identifier"],partNumber:row["part_number"],expectedBytes:row["expected_bytes"],expiresAt:Date(timeIntervalSince1970:row["expires_at"]),originDigest:row["origin_digest"])
            }
        }
    }
    func installBackgroundMapping(_ mapping:V2BackgroundTaskMapping,resourceOwner:UUID) throws {
        try databasePool.write { db in
            guard let job=try Self.readResourceTransfer(mapping.jobID,db:db),job.nextAction == .status || job.nextAction == .upload,
                  !job.cancellationRequested, job.control == .run,
                  try String.fetchOne(db,sql:"SELECT execution_owner FROM v2_resource_transfer_jobs WHERE job_id=?",arguments:[job.id.uuidString]) == resourceOwner.uuidString,
                  try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM v2_background_transfer_tasks WHERE state='active'") ?? 0 < 16
            else { throw V2BackgroundTransferError.mappingConflict }
            try db.execute(sql:"DELETE FROM v2_background_transfer_tasks WHERE session_id=? AND task_identifier=? AND state='completed'",arguments:[mapping.sessionID.uuidString,mapping.taskIdentifier])
            try db.execute(sql:"""
                INSERT INTO v2_background_transfer_tasks(mapping_id,session_id,job_id,activation_id,task_identifier,source_token,part_number,expected_bytes,expires_at,origin_digest,state,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,'active',?)
                """,arguments:[mapping.id.uuidString,mapping.sessionID.uuidString,mapping.jobID.uuidString,mapping.activationID.uuidString,mapping.taskIdentifier,mapping.sourceToken.uuidString,mapping.partNumber,mapping.expectedBytes,mapping.expiresAt.timeIntervalSince1970,mapping.originDigest,Date().timeIntervalSince1970])
            try db.execute(sql:"UPDATE v2_resource_transfer_jobs SET next_action='awaitingBackground',execution_owner=NULL WHERE job_id=?",arguments:[mapping.jobID.uuidString])
        }
    }
    /// A receipt only wakes same-ID reconciliation. Even HTTP 2xx is not a Ready/business proof.
    @discardableResult
    func completeBackgroundMapping(_ mapping:V2BackgroundTaskMapping,result:V2BackgroundTransferResult?,now:Date=Date()) throws -> Bool {
        try databasePool.write { db in
            guard try Bool.fetchOne(db,sql:"SELECT state='active' AND task_identifier=? AND session_id=? FROM v2_background_transfer_tasks WHERE mapping_id=?",arguments:[mapping.taskIdentifier,mapping.sessionID.uuidString,mapping.id.uuidString]) == true else { return false }
            if try Bool.fetchOne(db, sql: "SELECT user_control='pause' AND cancellation_requested=0 FROM v2_resource_transfer_jobs WHERE job_id=?", arguments: [mapping.jobID.uuidString]) == true {
                // Stopping the local OS attempt is not a remote abort or a
                // transport failure. Continue reconciles the original session.
                try db.execute(sql: "UPDATE v2_background_transfer_tasks SET state='completed' WHERE mapping_id=?", arguments: [mapping.id.uuidString])
                try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET execution_owner=NULL,next_action='status',round_deadline=NULL WHERE job_id=? AND stage NOT IN ('ready','cancelled','rejected','expired')", arguments: [mapping.jobID.uuidString])
                try db.execute(sql: "DELETE FROM v2_background_transfer_tasks WHERE state<>'active' AND mapping_id NOT IN (SELECT mapping_id FROM v2_background_transfer_tasks ORDER BY created_at DESC LIMIT 128)")
                return true
            }
            let sameAttempt = result.map { $0.mappingID == mapping.id && $0.taskIdentifier == mapping.taskIdentifier
                && $0.errorCode == nil && $0.originDigest == mapping.originDigest } ?? false
            let success = sameAttempt && result.map { (200...299).contains($0.statusCode ?? 0) && $0.sentBytes == mapping.expectedBytes } == true
            // Whole PUT has no provider part receipt to discover through status.
            // Verify the original session immediately after success or immutable
            // object conflict; finalize checks actual length/hash before ready.
            let verifyWhole = mapping.partNumber == nil && (success || (sameAttempt && result?.statusCode == 409))
            let reconciled = success || verifyWhole
            let failures=try Int.fetchOne(db,sql:"SELECT background_attempts FROM v2_resource_transfer_jobs WHERE job_id=?",arguments:[mapping.jobID.uuidString]) ?? 0
            let attempt=reconciled ? 0 : failures+1
            let retry=max(now,result?.retryNotBefore ?? now).addingTimeInterval(reconciled ? 0 : Double.random(in:0.5...1)*min(30,pow(2,Double(min(5,attempt)))))
            try db.execute(sql:"UPDATE v2_background_transfer_tasks SET state='completed' WHERE mapping_id=?",arguments:[mapping.id.uuidString])
            try db.execute(sql:"""
                UPDATE v2_resource_transfer_jobs SET next_action=CASE WHEN cancellation_requested=1 THEN 'cancel' ELSE ? END,
                background_attempts=?,needs_attention=CASE WHEN cancellation_requested=1 THEN 0 ELSE ? END,
                stage=CASE WHEN ? AND cancellation_requested=0 THEN 'paused' ELSE stage END,
                last_error=?,action_attempts=0,round_deadline=NULL,execution_owner=NULL,
                server_retry_not_before=MAX(server_retry_not_before,?),retry_at=MAX(server_retry_not_before,?)
                WHERE job_id=? AND stage NOT IN ('ready','cancelled','rejected','expired')
                """,arguments:[verifyWhole ? "finalize" : "status",attempt,attempt>=5,attempt>=5,reconciled ? nil : "backgroundOutcomeUnknown",result?.retryNotBefore?.timeIntervalSince1970 ?? 0,retry.timeIntervalSince1970,mapping.jobID.uuidString])
            // Terminal mappings are harmless tombstones; keep a bounded recent set for late callbacks.
            try db.execute(sql:"DELETE FROM v2_background_transfer_tasks WHERE state<>'active' AND mapping_id NOT IN (SELECT mapping_id FROM v2_background_transfer_tasks ORDER BY created_at DESC LIMIT 128)")
            return true
        }
    }
}
