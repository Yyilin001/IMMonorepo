import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let groupAvatarIntentsSchemaSQL = """
        CREATE TABLE v2_group_avatar_intents (
            operation_id TEXT PRIMARY KEY NOT NULL,
            actor_user_id TEXT NOT NULL, room_id TEXT NOT NULL, command BLOB NOT NULL,
            upload_job_id TEXT REFERENCES v2_resource_transfer_jobs(job_id),
            import_job_id TEXT REFERENCES v2_resource_import_jobs(job_id),
            stage TEXT NOT NULL CHECK(stage IN ('preparing','submitted','needsAttention','committed','cancelled','closed')),
            submission_started INTEGER NOT NULL DEFAULT 0 CHECK(submission_started IN (0,1)),
            attempts INTEGER NOT NULL DEFAULT 0 CHECK(typeof(attempts)='integer' AND attempts>=0),
            retry_at REAL NOT NULL DEFAULT 0, server_retry_not_before REAL NOT NULL DEFAULT 0, issue TEXT,
            claim_id TEXT, claim_until REAL, receipt BLOB, created_at REAL NOT NULL,
            recovery_action TEXT CHECK(recovery_action IN ('query','closeIfAbsent')),
            closure_proof BLOB,
            closed_disposition TEXT NOT NULL DEFAULT 'awaitingDecision' CHECK(closed_disposition IN ('awaitingDecision','abandoned','replaced')),
            replacement_of TEXT,
            CHECK(upload_job_id IS NULL OR import_job_id IS NULL),
            CHECK((claim_id IS NULL)=(claim_until IS NULL)),
            CHECK((stage='committed')=(receipt IS NOT NULL)),
            CHECK((stage='closed')=(closure_proof IS NOT NULL)),
            CHECK(stage='closed' OR closed_disposition='awaitingDecision'),
            CHECK(stage NOT IN ('submitted','committed','closed') OR submission_started=1),
            CHECK(stage<>'cancelled' OR submission_started=0),
            CHECK(stage<>'preparing' OR submission_started=0)
        );
        CREATE UNIQUE INDEX v2_group_avatar_active_room ON v2_group_avatar_intents(room_id)
            WHERE stage NOT IN ('committed','cancelled','closed');
        CREATE INDEX v2_group_avatar_intent_due ON v2_group_avatar_intents(retry_at,created_at)
            WHERE stage IN ('preparing','submitted');
        CREATE INDEX v2_group_avatar_intent_upload ON v2_group_avatar_intents(upload_job_id,stage);
        CREATE INDEX v2_group_avatar_intent_import ON v2_group_avatar_intents(import_job_id,stage);
        CREATE UNIQUE INDEX v2_group_avatar_replacement ON v2_group_avatar_intents(replacement_of) WHERE replacement_of IS NOT NULL;
        CREATE INDEX v2_group_avatar_pending_account ON v2_group_avatar_intents(actor_user_id,created_at,operation_id)
            WHERE stage NOT IN ('committed','cancelled','closed')
                OR (stage='closed' AND closed_disposition='awaitingDecision');
        """

    /// Persist before any upload or command I/O. A replay must match every frozen field.
    @discardableResult
    public func freezeGroupAvatarIntent(actorUserID: UserID, command: V2GroupAvatarCommand,
                                        uploadJobID: UUID?, now: Date = Date()) throws -> V2GroupAvatarIntent {
        try databasePool.write { db in
            try Self.freezeGroupAvatarIntent(actorUserID: actorUserID, command: command, preparation: uploadJobID.map(V2GroupAvatarPreparation.upload), now: now, db: db)
        }
    }

    /// The initial upload job and its only intended consumer commit together.
    /// A crash cannot leave a permanently retained prepared job with no intent.
    @discardableResult
    public func freezeGroupAvatarUploadIntent(actorUserID: UserID, command: V2GroupAvatarCommand,
                                               uploadJobID: UUID, request: V2ResourceUploadRequest,
                                               localAssetID: V2LocalResourceAssetID, now: Date = Date()) throws -> V2GroupAvatarIntent {
        try Task.checkCancellation()
        guard command.mutation.mediaID == request.mediaID, request.usage == .groupAvatar(command.roomID) else {
            throw V2GroupAvatarIntentError.conflict
        }
        return try databasePool.write { db in
            _ = try Self.prepareResourceTransfer(id: uploadJobID, request: request, localAssetID: localAssetID, now: now, db: db)
            return try Self.freezeGroupAvatarIntent(actorUserID: actorUserID, command: command, preparation: .upload(uploadJobID), now: now, db: db)
        }
    }

    /// The target import and its consumer are admitted atomically. No orphan
    /// import can race the avatar command's persistence boundary.
    @discardableResult
    public func freezeGroupAvatarImportIntent(actorUserID: UserID, command: V2GroupAvatarCommand,
                                              importJobID: UUID, request: V2ResourceImportRequest, now: Date = Date()) throws -> V2GroupAvatarIntent {
        try Task.checkCancellation()
        guard command.mutation.mediaID == request.targetMediaID, request.targetUsage == .groupAvatar(command.roomID) else { throw V2GroupAvatarIntentError.conflict }
        return try databasePool.write { db in
            try Self.prepareResourceImport(id: importJobID, request: request, now: now, db: db)
            return try Self.freezeGroupAvatarIntent(actorUserID: actorUserID, command: command, preparation: .serverImport(importJobID), now: now, db: db)
        }
    }

    private static func freezeGroupAvatarIntent(actorUserID: UserID, command: V2GroupAvatarCommand,
                                                preparation: V2GroupAvatarPreparation?, now: Date, db: Database) throws -> V2GroupAvatarIntent {
        try Self.requireGroupAvatarAccount(actorUserID, db: db)
        if let prior = try Self.readGroupAvatarIntent(command.operationID, db: db) {
            guard prior.actorUserID == actorUserID, prior.command == command, prior.preparation == preparation
            else { throw V2GroupAvatarIntentError.conflict }
            return prior
        }
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_group_avatar_intents WHERE room_id=? AND stage NOT IN ('committed','cancelled','closed'))",
            arguments: [command.roomID.rawValue]) != true else { throw V2GroupAvatarIntentError.conflict }
        switch command.mutation {
        case .remove:
            guard preparation == nil else { throw V2GroupAvatarIntentError.conflict }
        case .set(let media):
            switch preparation {
            case .upload(let jobID):
            guard let job = try Self.readResourceTransfer(jobID, db: db),
                  job.request.mediaID == media, job.request.usage == .groupAvatar(command.roomID),
                  !job.cancellationRequested, ![.cancelled, .expired, .rejected].contains(job.stage),
                  try Bool.fetchOne(db, sql: "SELECT source_released=0 FROM v2_resource_transfer_jobs WHERE job_id=?",
                    arguments: [jobID.uuidString]) == true else { throw V2GroupAvatarIntentError.conflict }
            case .serverImport(let jobID):
                guard let job = try Self.readResourceImport(jobID, db: db), job.request.targetMediaID == media,
                      job.request.targetUsage == .groupAvatar(command.roomID), !job.cancellationRequested,
                      job.status.map({ ![.cancelled,.failed].contains($0.state) }) ?? true else { throw V2GroupAvatarIntentError.conflict }
            case nil: throw V2GroupAvatarIntentError.conflict
            }
        }
        let uploadJobID: UUID? = if case .upload(let id) = preparation { id } else { nil }
        let importJobID: UUID? = if case .serverImport(let id) = preparation { id } else { nil }
        try db.execute(sql: """
            INSERT INTO v2_group_avatar_intents(operation_id,actor_user_id,room_id,command,upload_job_id,import_job_id,stage,created_at)
            VALUES(?,?,?,?,?,?,'preparing',?)
            """, arguments: [command.operationID.rawValue, actorUserID.rawValue, command.roomID.rawValue,
                try JSONEncoder().encode(command), uploadJobID?.uuidString, importJobID?.uuidString, try Self.commandRetryTimestamp(now)])
        return try Self.requireGroupAvatarIntent(command.operationID, db: db)
    }

    public func groupAvatarIntent(_ id: GroupAvatarOperationID) throws -> V2GroupAvatarIntent? {
        try databasePool.read { try Self.readGroupAvatarIntent(id, db: $0) }
    }

    public func groupAvatarIntents(in roomID: RoomID, limit: Int = 16) throws -> [V2GroupAvatarIntent] {
        guard (1...64).contains(limit) else { throw V2GroupAvatarIntentError.invalidRecord }
        return try databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT operation_id FROM v2_group_avatar_intents WHERE room_id=? ORDER BY created_at DESC,operation_id LIMIT ?",
                arguments: [roomID.rawValue, limit]).map { try Self.requireGroupAvatarIntent(.init($0), db: db) }
        }
    }

    /// Filter before LIMIT so completed history cannot hide an older operation
    /// that still owns source bytes or needs an explicit user decision.
    public func pendingGroupAvatarIntents(in roomID: RoomID, limit: Int = 16) throws -> [V2GroupAvatarIntent] {
        guard (1...64).contains(limit) else { throw V2GroupAvatarIntentError.invalidRecord }
        return try databasePool.read { db in
            try String.fetchAll(db, sql: """
                SELECT operation_id FROM v2_group_avatar_intents
                WHERE room_id=? AND (stage NOT IN ('committed','cancelled','closed')
                    OR (stage='closed' AND closed_disposition='awaitingDecision'))
                ORDER BY CASE WHEN stage='closed' THEN 1 ELSE 0 END,created_at,operation_id LIMIT ?
                """, arguments: [roomID.rawValue, limit]).map { try Self.requireGroupAvatarIntent(.init($0), db: db) }
        }
    }

    /// Keyset pagination avoids skipping unresolved operations when earlier
    /// entries complete between reads. No room projection is needed after leave.
    public func pendingGroupAvatarOperations(actorUserID: UserID, after: V2PendingGroupAvatarPage.Cursor? = nil,
                                             limit: Int = 32) throws -> V2PendingGroupAvatarPage {
        try Task.checkCancellation()
        guard (1...64).contains(limit) else { throw V2GroupAvatarIntentError.invalidRecord }
        if let after {
            guard after.actorUserID == actorUserID else { throw V2GroupAvatarIntentError.accountMismatch }
            guard after.createdAt.isFinite else { throw V2GroupAvatarIntentError.invalidRecord }
        }
        return try databasePool.read { db in
            try Self.requireGroupAvatarAccount(actorUserID, db: db)
            var arguments: StatementArguments = [actorUserID.rawValue]
            let cursorPredicate: String
            if let after {
                cursorPredicate = "AND (created_at,operation_id) > (?,?)"
                arguments += [after.createdAt, after.operationID.rawValue]
            } else { cursorPredicate = "" }
            arguments += [limit + 1]
            let rows = try Row.fetchAll(db, sql: """
                SELECT operation_id,created_at FROM v2_group_avatar_intents
                WHERE actor_user_id=? AND (stage NOT IN ('committed','cancelled','closed')
                    OR (stage='closed' AND closed_disposition='awaitingDecision'))
                \(cursorPredicate) ORDER BY created_at,operation_id LIMIT ?
                """, arguments: arguments)
            let entries = try rows.prefix(limit).map { row -> V2PendingGroupAvatarPage.Entry in
                let created: Double = row["created_at"]
                guard created.isFinite else { throw V2GroupAvatarIntentError.invalidRecord }
                return try .init(intent: Self.requireGroupAvatarIntent(.init(row["operation_id"]), db: db),
                    createdAt: Date(timeIntervalSince1970: created))
            }
            let next = rows.count > limit ? entries.last.map {
                V2PendingGroupAvatarPage.Cursor(actorUserID: actorUserID, createdAt: rows[limit - 1]["created_at"], operationID: $0.id)
            } : nil
            return .init(entries: entries, next: next)
        }
    }

    func dueGroupAvatarIntents(now: Date, limit: Int = 16) throws -> [GroupAvatarOperationID] {
        guard (1...64).contains(limit) else { throw V2GroupAvatarIntentError.invalidRecord }
        let time = try Self.commandRetryTimestamp(now)
        return try databasePool.write { db in
            // An app crash may leave the fifth attempt without a failure callback.
            // Lease expiry still consumes that attempt; never restart an endless loop.
            try db.execute(sql: """
                UPDATE v2_group_avatar_intents SET stage='needsAttention',issue='outcomeUnknown',claim_id=NULL,claim_until=NULL
                WHERE stage='submitted' AND attempts>=5 AND (claim_until IS NULL OR claim_until<=?)
                """, arguments: [time])
            return try String.fetchAll(db, sql: """
                SELECT operation_id FROM v2_group_avatar_intents g
                WHERE stage IN ('preparing','submitted') AND retry_at<=? AND (claim_until IS NULL OR claim_until<=?)
                AND (submission_started=1 OR (upload_job_id IS NULL AND import_job_id IS NULL) OR EXISTS (SELECT 1 FROM v2_resource_transfer_jobs r WHERE r.job_id=g.upload_job_id AND (r.stage IN ('ready','cancelled','rejected','expired') OR r.needs_attention=1)) OR EXISTS(SELECT 1 FROM v2_resource_import_jobs r WHERE r.job_id=g.import_job_id AND (r.stage IN ('ready','cancelled','failed') OR r.attempts>=5)))
                ORDER BY retry_at,created_at,operation_id LIMIT ?
                """, arguments: [time, time, limit]).map(GroupAvatarOperationID.init)
        }
    }

    /// The write-ahead boundary. A crash after this returns always recovers the
    /// exact command, even if no network bytes were ultimately sent.
    func claimGroupAvatarSubmission(_ id: GroupAvatarOperationID, now: Date) throws -> V2GroupAvatarSubmissionClaim {
        let time = try Self.commandRetryTimestamp(now), until = try Self.commandRetryTimestamp(now.addingTimeInterval(30))
        return try databasePool.write { db in
            let value = try Self.requireGroupAvatarIntent(id, db: db)
            guard value.stage == .preparing || value.stage == .submitted else { throw V2GroupAvatarIntentError.conflict }
            guard value.retryAt.timeIntervalSince1970 <= time,
                  try Double.fetchOne(db, sql: "SELECT claim_until FROM v2_group_avatar_intents WHERE operation_id=?", arguments: [id.rawValue]).map({ $0 <= time }) ?? true
            else { throw V2GroupAvatarIntentError.busy }
            if !value.submissionStarted, let jobID = value.uploadJobID {
                guard let job = try Self.readResourceTransfer(jobID, db: db), job.stage == .ready, !job.cancellationRequested else {
                    throw V2ResourceJournalError.dependencyNotReady
                }
                guard let until = job.session?.bindableUntil, until > now else { throw V2ResourceJournalError.bindingExpired }
            }
            if !value.submissionStarted, let jobID = value.importJobID {
                guard let job = try Self.readResourceImport(jobID, db: db), let status = job.status,
                      status.state == .ready, !job.cancellationRequested else { throw V2ResourceJournalError.dependencyNotReady }
                guard let expiry = status.bindableUntilUnixMilliseconds,
                      Double(expiry) / 1000 > now.timeIntervalSince1970 else { throw V2ResourceJournalError.bindingExpired }
            }
            guard value.attempts < 5 else { throw V2GroupAvatarIntentError.busy }
            let claim = UUID()
            try db.execute(sql: """
                UPDATE v2_group_avatar_intents SET stage='submitted',submission_started=1,attempts=attempts+1,
                    claim_id=?,claim_until=?,issue=NULL WHERE operation_id=?
                """, arguments: [claim.uuidString, until, id.rawValue])
            return try .init(id: claim, intent: Self.requireGroupAvatarIntent(id, db: db))
        }
    }

    func finishGroupAvatarSubmission(_ claim: V2GroupAvatarSubmissionClaim, response: V2GroupAvatarCommandResponse, now: Date) throws {
        try databasePool.write { db in
            let current = try Self.requireGroupAvatarIntent(claim.intent.id, db: db)
            guard response.command == current.command, response.actorUserID == current.actorUserID,
                  current.submissionStarted else { throw V2GroupAvatarIntentError.conflict }
            if case .committed(let receipt) = response.outcome {
                try Self.commitGroupAvatarReceipt(receipt, current: current, db: db)
            } else {
                let issue: V2GroupAvatarIntent.Issue
                switch response.outcome {
                case .revisionConflict: issue = .revisionConflict
                case .idempotencyConflict: issue = .idempotencyConflict
                case .resourceUnavailable: issue = .resourceUnavailable
                case .forbidden: issue = .forbidden
                case .committed: throw V2GroupAvatarIntentError.invalidRecord
                }
                try Self.failGroupAvatarClaim(claim, issue: issue, retryAt: now, attention: true, db: db)
            }
        }
    }

    func failGroupAvatarSubmission(_ claim: V2GroupAvatarSubmissionClaim, issue: V2GroupAvatarIntent.Issue,
                                   retryAt: Date, attention: Bool) throws {
        try databasePool.write { db in
            _ = try Self.requireGroupAvatarIntent(claim.intent.id, db: db)
            if issue == .throttled {
                try db.execute(sql: "UPDATE v2_group_avatar_intents SET server_retry_not_before=MAX(server_retry_not_before,?) WHERE operation_id=? AND claim_id=?", arguments: [try Self.commandRetryTimestamp(retryAt),claim.intent.id.rawValue,claim.id.uuidString])
            }
            try Self.failGroupAvatarClaim(claim, issue: issue, retryAt: retryAt, attention: attention || claim.intent.attempts >= 5, db: db)
        }
    }

    func pauseGroupAvatarPreparation(_ id: GroupAvatarOperationID) throws {
        try databasePool.write { db in
            _ = try Self.requireGroupAvatarIntent(id, db: db)
            try db.execute(sql: "UPDATE v2_group_avatar_intents SET stage='needsAttention',issue='preparationUnavailable' WHERE operation_id=? AND stage='preparing'",
                arguments: [id.rawValue])
        }
    }

    public func retryGroupAvatarIntent(_ id: GroupAvatarOperationID) throws {
        try databasePool.write { db in
            _ = try Self.requireGroupAvatarIntent(id, db: db)
            try db.execute(sql: """
                UPDATE v2_group_avatar_intents SET stage=CASE WHEN submission_started=1 THEN 'submitted' ELSE 'preparing' END,
                    attempts=0,retry_at=server_retry_not_before,issue=NULL WHERE operation_id=? AND stage='needsAttention' AND claim_id IS NULL
                """, arguments: [id.rawValue])
        }
    }

    public func cancelGroupAvatarIntent(_ id: GroupAvatarOperationID) throws {
        try databasePool.write { db in
            let value = try Self.requireGroupAvatarIntent(id, db: db)
            if value.stage == .cancelled { return }
            guard !value.submissionStarted else { throw V2GroupAvatarIntentError.alreadySubmitted }
            try db.execute(sql: "UPDATE v2_group_avatar_intents SET stage='cancelled',issue=NULL WHERE operation_id=?", arguments: [id.rawValue])
            if let job = value.importJobID { try Self.requestUnboundAvatarImportCancellation(job, db: db) }
            if let job = value.uploadJobID {
                // Persist cleanup demand in the same transaction as local cancellation.
                try Self.requestUnboundAvatarUploadCancellation(job, db: db)
            }
        }
    }

    static func commitGroupAvatarReceipt(_ receipt: V2GroupAvatarChange, current: V2GroupAvatarIntent, db: Database) throws {
        guard current.stage != .closed else { throw V2GroupAvatarIntentError.conflict }
        if let prior = current.receipt {
            guard prior == receipt else { throw V2GroupAvatarIntentError.conflict }; return
        }
        // A late positive receipt is still proof. A stale failure never is.
        try db.execute(sql: """
            UPDATE v2_group_avatar_intents SET stage='committed',receipt=?,issue=NULL,claim_id=NULL,claim_until=NULL
            WHERE operation_id=?
            """, arguments: [try JSONEncoder().encode(receipt), current.id.rawValue])
    }

    /// True only if this claim still owned the requested mode. Callers may then
    /// apply mode-specific transitions within this same SQLite transaction.
    @discardableResult
    static func failGroupAvatarClaim(_ claim: V2GroupAvatarSubmissionClaim, issue: V2GroupAvatarIntent.Issue,
                                    retryAt: Date, attention: Bool, db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT recovery_action FROM v2_group_avatar_intents WHERE operation_id=? AND claim_id=? AND stage='submitted'",
            arguments: [claim.intent.id.rawValue, claim.id.uuidString]) else { return false }
        let action: String? = row["recovery_action"]
        if action != claim.intent.recoveryAction?.rawValue {
            // A requested query/closure supersedes an older failure or denial.
            try db.execute(sql: """
                UPDATE v2_group_avatar_intents SET attempts=0,retry_at=server_retry_not_before,issue=NULL,claim_id=NULL,claim_until=NULL
                WHERE operation_id=? AND claim_id=?
                """, arguments: [claim.intent.id.rawValue, claim.id.uuidString])
            return false
        }
        try db.execute(sql: """
            UPDATE v2_group_avatar_intents SET stage=?,issue=?,retry_at=?,claim_id=NULL,claim_until=NULL
            WHERE operation_id=? AND claim_id=? AND stage='submitted'
            """, arguments: [attention || claim.intent.attempts >= 5 ? "needsAttention" : "submitted", issue.rawValue, try commandRetryTimestamp(retryAt),
                claim.intent.id.rawValue, claim.id.uuidString])
        return true
    }
    static func requireGroupAvatarAccount(_ actor: UserID, db: Database) throws {
        guard actor.uuidValue != nil, try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == actor.rawValue
        else { throw V2GroupAvatarIntentError.accountMismatch }
    }
    static func requireGroupAvatarIntent(_ id: GroupAvatarOperationID, db: Database) throws -> V2GroupAvatarIntent {
        guard let value = try readGroupAvatarIntent(id, db: db) else { throw V2GroupAvatarIntentError.missing }
        return value
    }
    static func readGroupAvatarIntent(_ id: GroupAvatarOperationID, db: Database) throws -> V2GroupAvatarIntent? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_group_avatar_intents WHERE operation_id=?", arguments: [id.rawValue]) else { return nil }
        let actor = try UserID(row["actor_user_id"])
        try requireGroupAvatarAccount(actor, db: db)
        let command = try JSONDecoder().decode(V2GroupAvatarCommand.self, from: row["command"])
        let rawImport: String? = row["import_job_id"]
        let rawJob: String? = row["upload_job_id"], rawIssue: String? = row["issue"]
        let bytes: Data? = row["receipt"]
        let receipt = try bytes.map { try JSONDecoder().decode(V2GroupAvatarChange.self, from: $0) }
        let rawAction: String? = row["recovery_action"], proofBytes: Data? = row["closure_proof"]
        let proof = try proofBytes.map { try JSONDecoder().decode(V2GroupAvatarRecoveryResponse.self, from: $0) }
        let retry: Double = row["retry_at"]
        guard command.operationID == id, command.roomID.rawValue == row["room_id"],
              let stage = V2GroupAvatarIntent.Stage(rawValue: row["stage"]),
              let disposition = V2GroupAvatarIntent.ClosedDisposition(rawValue: row["closed_disposition"]),
              rawAction == nil || rawAction.flatMap(V2GroupAvatarRecoveryRequest.Action.init(rawValue:)) != nil,
              rawJob == nil || rawJob.flatMap(UUID.init(uuidString:)) != nil,
              rawImport == nil || rawImport.flatMap(UUID.init(uuidString:)) != nil,
              rawJob == nil || rawImport == nil,
              rawIssue == nil || rawIssue.flatMap(V2GroupAvatarIntent.Issue.init(rawValue:)) != nil,
              retry.isFinite, (command.mutation.mediaID == nil) == (rawJob == nil && rawImport == nil),
              (stage == .closed) == (proof != nil), (stage == .committed) == (receipt != nil),
              stage == .closed || disposition == .awaitingDecision
        else { throw V2GroupAvatarIntentError.invalidRecord }
        if let receipt {
            guard receipt.state.roomID == command.roomID, receipt.state.mediaID == command.mutation.mediaID,
                  receipt.state.revision == command.expectedRevision + 1 else { throw V2GroupAvatarIntentError.invalidRecord }
        }
        if let proof {
            guard proof.actorUserID == actor, proof.request.command == command, proof.result == .closed
            else { throw V2GroupAvatarIntentError.invalidRecord }
        }
        return .init(actorUserID: actor, command: command, preparation: rawJob.flatMap(UUID.init(uuidString:)).map(V2GroupAvatarPreparation.upload) ?? rawImport.flatMap(UUID.init(uuidString:)).map(V2GroupAvatarPreparation.serverImport), stage: stage,
            submissionStarted: row["submission_started"], recoveryAction: rawAction.flatMap(V2GroupAvatarRecoveryRequest.Action.init(rawValue:)),
            closedDisposition: disposition, attempts: row["attempts"], retryAt: Date(timeIntervalSince1970: retry),
            issue: rawIssue.flatMap(V2GroupAvatarIntent.Issue.init(rawValue:)), receipt: receipt, closureProof: proof)
    }
}
