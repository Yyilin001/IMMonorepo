import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    /// Persist the requested action before I/O. Closing is monotonic: a later
    /// status query must never turn recovery back into a new submission.
    public func requestGroupAvatarRecovery(_ id: GroupAvatarOperationID, action: V2GroupAvatarRecoveryRequest.Action) throws {
        try databasePool.write { db in
            let value = try Self.requireGroupAvatarIntent(id, db: db)
            if [.committed, .cancelled, .closed].contains(value.stage) { return }
            guard value.recoveryAction != .closeIfAbsent || action == .closeIfAbsent else { return }
            if value.recoveryAction == action && value.stage != .needsAttention { return }
            try db.execute(sql: """
                UPDATE v2_group_avatar_intents SET stage='submitted',submission_started=1,recovery_action=?,
                    attempts=0,retry_at=server_retry_not_before,issue=NULL WHERE operation_id=?
                """, arguments: [action.rawValue, id.rawValue])
        }
    }

    func finishGroupAvatarRecovery(_ claim: V2GroupAvatarSubmissionClaim, response: V2GroupAvatarRecoveryResponse, now: Date) throws {
        try databasePool.write { db in
            let value = try Self.requireGroupAvatarIntent(claim.intent.id, db: db)
            guard response.actorUserID == value.actorUserID, response.request.command == value.command,
                  response.request.action == claim.intent.recoveryAction, value.submissionStarted
            else { throw V2GroupAvatarIntentError.conflict }
            switch response.result {
            case .committed(let receipt):
                try Self.commitGroupAvatarReceipt(receipt, current: value, db: db)
            case .closed:
                guard value.stage != .committed else { throw V2GroupAvatarIntentError.conflict }
                if value.stage == .closed { return }
                try db.execute(sql: """
                    UPDATE v2_group_avatar_intents SET stage='closed',closure_proof=?,issue=NULL,claim_id=NULL,claim_until=NULL
                    WHERE operation_id=?
                    """, arguments: [try JSONEncoder().encode(response), value.id.rawValue])
            case .idempotencyConflict:
                try Self.failGroupAvatarClaim(claim, issue: .idempotencyConflict, retryAt: now, attention: true, db: db)
            case .unresolved:
                // A query's absence is not permanent. Preserve the original intent,
                // including a close request that arrived while this query was away.
                let owned = try Self.failGroupAvatarClaim(claim, issue: .outcomeUnknown, retryAt: now.addingTimeInterval(5), attention: false, db: db)
                if owned && value.recoveryAction == .query {
                    try db.execute(sql: "UPDATE v2_group_avatar_intents SET recovery_action=NULL WHERE operation_id=? AND recovery_action='query' AND claim_id IS NULL AND stage IN ('submitted','needsAttention')",
                        arguments: [value.id.rawValue])
                }
            }
        }
    }

    /// Keep the closed proof, but release local source bytes after the explicit
    /// user decision. An already-created replacement can never be abandoned here.
    public func abandonClosedGroupAvatarIntent(_ id: GroupAvatarOperationID) throws {
        try databasePool.write { db in
            let value = try Self.requireGroupAvatarIntent(id, db: db)
            guard value.stage == .closed, value.closedDisposition != .replaced else { throw V2GroupAvatarIntentError.conflict }
            try db.execute(sql: "UPDATE v2_group_avatar_intents SET closed_disposition='abandoned' WHERE operation_id=?", arguments: [id.rawValue])
            if let job = value.uploadJobID { try Self.requestUnboundAvatarUploadCancellation(job, db: db) }
            if let job = value.importJobID { try Self.requestUnboundAvatarImportCancellation(job, db: db) }
        }
    }

    /// A new revision comes from a fresh authorized group presentation. Allocate
    /// fresh operation/media/upload identities atomically, while retaining the file.
    public func replaceClosedGroupAvatarIntent(_ id: GroupAvatarOperationID, expectedRevision: UInt64,
                                              now: Date = Date()) throws -> GroupAvatarOperationID {
        try databasePool.write { db in
            let original = try Self.requireGroupAvatarIntent(id, db: db)
            if let prior = try String.fetchOne(db, sql: "SELECT operation_id FROM v2_group_avatar_intents WHERE replacement_of=?", arguments: [id.rawValue]) {
                return try .init(prior)
            }
            guard original.stage == .closed, original.closedDisposition == .awaitingDecision,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_group_avatar_intents WHERE room_id=? AND stage NOT IN ('committed','cancelled','closed'))",
                    arguments: [original.command.roomID.rawValue]) != true else { throw V2GroupAvatarIntentError.conflict }
            let operation = GroupAvatarOperationID(uuid: UUID()), time = try Self.commandRetryTimestamp(now)
            let jobID: UUID?, importID: UUID?, mutation: V2GroupAvatarMutation
            if let previous = original.uploadJobID {
                guard let job = try Self.readResourceTransfer(previous, db: db),
                      job.request.mediaID == original.command.mutation.mediaID,
                      job.request.usage == .groupAvatar(original.command.roomID),
                      try Bool.fetchOne(db, sql: "SELECT source_released=0 FROM v2_resource_transfer_jobs WHERE job_id=?",
                        arguments: [previous.uuidString]) == true else { throw V2GroupAvatarIntentError.conflict }
                let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
                    usage: job.request.usage, contentType: job.request.contentType, byteCount: job.request.byteCount,
                    checksum: job.request.checksum, clientModes: job.request.clientModes, displayName: job.request.displayName, clientImageDimensions: job.request.clientImageDimensions)
                let newJobID = UUID()
                _ = try Self.prepareResourceTransfer(id: newJobID, request: request, localAssetID: job.localAssetID, adoptingFrom: .upload(job.id), now: now, db: db)
                jobID = newJobID; importID = nil; mutation = .set(request.mediaID)
            } else if let previous = original.importJobID {
                guard let job = try Self.readResourceImport(previous, db: db),
                      job.request.targetMediaID == original.command.mutation.mediaID,
                      job.request.targetUsage == .groupAvatar(original.command.roomID) else { throw V2GroupAvatarIntentError.conflict }
                let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: job.request.source,
                    targetUsage: job.request.targetUsage, targetMediaID: .init(uuid: UUID()))
                let newJobID = UUID()
                try Self.prepareResourceImport(id: newJobID, request: request, now: now, db: db)
                jobID = nil; importID = newJobID; mutation = .set(request.targetMediaID)
            } else { jobID = nil; importID = nil; mutation = .remove }
            let command = try V2GroupAvatarCommand(operationID: operation, roomID: original.command.roomID,
                expectedRevision: expectedRevision, mutation: mutation)
            try db.execute(sql: """
                INSERT INTO v2_group_avatar_intents(operation_id,actor_user_id,room_id,command,upload_job_id,import_job_id,stage,created_at,replacement_of)
                VALUES(?,?,?,?,?,?,'preparing',?,?)
                """, arguments: [operation.rawValue, original.actorUserID.rawValue, command.roomID.rawValue,
                    try JSONEncoder().encode(command), jobID?.uuidString, importID?.uuidString, time, id.rawValue])
            try db.execute(sql: "UPDATE v2_group_avatar_intents SET closed_disposition='replaced' WHERE operation_id=?", arguments: [id.rawValue])
            if let job = original.uploadJobID { try Self.requestUnboundAvatarUploadCancellation(job, db: db) }
            if let job = original.importJobID { try Self.requestUnboundAvatarImportCancellation(job, db: db) }
            return operation
        }
    }

    static func requestUnboundAvatarImportCancellation(_ job: UUID, db: Database) throws {
        try db.execute(sql: """
            UPDATE v2_resource_import_jobs SET cancellation_requested=1,user_control='run',retry_at=server_retry_not_before,attempts=0,round_deadline=NULL
            WHERE job_id=? AND cancellation_requested=0 AND stage NOT IN ('ready','cancelled','failed')
              AND NOT EXISTS(SELECT 1 FROM v2_send_intent_import_dependencies d JOIN v2_send_intents i USING(intent_id) WHERE d.job_id=v2_resource_import_jobs.job_id AND i.stage<>'cancelled')
              AND NOT EXISTS(SELECT 1 FROM v2_profile_intents p WHERE p.import_job_id=v2_resource_import_jobs.job_id AND p.source_released=0)
              AND NOT EXISTS(SELECT 1 FROM v2_group_avatar_intents g WHERE g.import_job_id=v2_resource_import_jobs.job_id
                AND (g.stage NOT IN ('committed','cancelled','closed') OR (g.stage='closed' AND g.closed_disposition='awaitingDecision')))
            """, arguments: [job.uuidString])
    }

    static func requestUnboundAvatarUploadCancellation(_ job: UUID, db: Database) throws {
        guard try !uploadHasLiveResourceConsumer(job, db: db) else { return }
        try db.execute(sql: """
            UPDATE v2_resource_transfer_jobs SET cancellation_requested=1,user_control='run',
                next_action=CASE WHEN EXISTS(SELECT 1 FROM v2_background_transfer_tasks b WHERE b.job_id=v2_resource_transfer_jobs.job_id AND b.state='active') THEN 'awaitingBackground' ELSE 'cancel' END,
                retry_at=server_retry_not_before,needs_attention=0,action_attempts=0,round_deadline=NULL
            WHERE job_id=? AND cancellation_requested=0
            """, arguments: [job.uuidString])
    }
}
