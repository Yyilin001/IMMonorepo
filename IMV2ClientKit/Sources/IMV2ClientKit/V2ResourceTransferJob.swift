import Foundation
import IMV2Core

/// Durable metadata only. Neither this value nor its SQLite row contains a signed plan.
public struct V2ResourceTransferJob: Equatable, Sendable {
    public enum Stage: String, Sendable { case prepared, transferring, processing, ready, paused, cancelled, rejected, expired }
    public let id: UUID
    public let request: V2ResourceUploadRequest
    public let localFileToken: String
    public let session: V2ResourceUploadSession?
    public let stage: Stage
    public let cancellationRequested: Bool
    public let attempts: Int
    public let retryAt: Date
    public let lastError: String?
}

extension GRDBV2LocalSyncStore {
    public func prepareResourceTransfer(id: UUID, request: V2ResourceUploadRequest, localFileToken: String, now: Date = Date()) throws -> V2ResourceTransferJob {
        try databasePool.write { db in
            try Self.prepareResourceTransfer(id: id, request: request, localFileToken: localFileToken, now: now, db: db)
        }
    }

    static func prepareResourceTransfer(id: UUID, request: V2ResourceUploadRequest, localFileToken: String,
                                        now: Date, db: Database) throws -> V2ResourceTransferJob {
        guard UUID(uuidString: localFileToken) != nil else { throw V2ResourceJournalError.invalidRecord }
        if let existing = try Self.readResourceTransfer(id, db: db) {
            guard existing.request == request, existing.localFileToken == localFileToken else { throw V2ResourceJournalError.conflict }
            return existing
        }
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_transfer_jobs WHERE local_file_token=? AND (staging_release_started=1 OR staging_released=1))",
            arguments: [localFileToken]) != true else { throw V2ResourceJournalError.conflict }
        try db.execute(sql: """
            INSERT INTO v2_resource_transfer_jobs(job_id,operation_id,media_id,request,local_file_token,stage,created_at)
            VALUES(?,?,?,?,?,'prepared',?)
            """, arguments: [id.uuidString, request.operationID.rawValue, request.mediaID.rawValue,
                              try JSONEncoder().encode(request), localFileToken, try Self.commandRetryTimestamp(now)])
        return try Self.readResourceTransfer(id, db: db)!
    }

    public func resourceTransfer(id: UUID) throws -> V2ResourceTransferJob? {
        try databasePool.read { try Self.readResourceTransfer(id, db: $0) }
    }

    public func releasableResourceFileToken(id: UUID) throws -> String? {
        try databasePool.read { db in
            try String.fetchOne(db, sql: """
                SELECT local_file_token FROM v2_resource_transfer_jobs j WHERE job_id=? AND \(Self.resourceStagingReleasePredicate)
                """, arguments: [id.uuidString])
        }
    }

    /// Freeze every consumer of the same local file before deleting it outside
    /// SQLite. Once claimed, new consumers cannot race with the filesystem step.
    func claimReleasableResourceFileToken(id: UUID) throws -> String? {
        try databasePool.write { db in
            guard let token = try String.fetchOne(db, sql: "SELECT local_file_token FROM v2_resource_transfer_jobs j WHERE job_id=? AND \(Self.resourceStagingReleasePredicate)",
                arguments: [id.uuidString]) else { return nil }
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET staging_release_started=1 WHERE local_file_token=?", arguments: [token])
            return token
        }
    }

    public func releasableResourceJobs(limit: Int = 64) throws -> [UUID] {
        guard (1...256).contains(limit) else { throw V2ResourceJournalError.invalidRecord }
        return try databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT job_id FROM v2_resource_transfer_jobs j WHERE \(Self.resourceStagingReleasePredicate) ORDER BY job_id LIMIT ?", arguments: [limit]).map {
                guard let id=UUID(uuidString:$0) else { throw V2ResourceJournalError.invalidRecord }; return id
            }
        }
    }

    public func confirmResourceStagingReleased(id: UUID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs AS j SET staging_released=1 WHERE job_id=? AND staging_release_started=1 AND \(Self.resourceStagingReleasePredicate)", arguments: [id.uuidString])
        }
    }

    // Handoff is only a local fact. Keep the original file until every consumer
    // has been accepted, or the user has cancelled a still-unsubmitted intent.
    private static let resourceStagingReleasePredicate = """
        j.stage IN ('ready','cancelled','rejected','expired') AND j.staging_released=0
        AND (EXISTS(SELECT 1 FROM v2_send_intent_dependencies d WHERE d.job_id=j.job_id)
          OR EXISTS(SELECT 1 FROM v2_group_avatar_intents i WHERE i.upload_job_id=j.job_id))
        AND NOT EXISTS(
            SELECT 1 FROM v2_resource_transfer_jobs shared
            JOIN v2_send_intent_dependencies d ON d.job_id=shared.job_id
            JOIN v2_send_intents i USING(intent_id)
            LEFT JOIN v2_pending_message_commands c ON c.client_message_id=i.client_message_id
            WHERE shared.local_file_token=j.local_file_token AND i.stage<>'cancelled'
              AND (i.stage<>'handedOff' OR c.state IS NULL OR c.state<>'accepted')
        )
        AND NOT EXISTS(
            SELECT 1 FROM v2_resource_transfer_jobs shared JOIN v2_group_avatar_intents i ON i.upload_job_id=shared.job_id
            WHERE shared.local_file_token=j.local_file_token
              AND (i.stage NOT IN ('committed','cancelled','closed') OR (i.stage='closed' AND i.closed_disposition='awaitingDecision'))
        )
        AND NOT EXISTS(
            SELECT 1 FROM v2_resource_transfer_jobs shared WHERE shared.local_file_token=j.local_file_token
              AND shared.staging_released=0 AND shared.stage NOT IN ('cancelled','rejected','expired')
              AND NOT EXISTS(SELECT 1 FROM v2_send_intent_dependencies d WHERE d.job_id=shared.job_id)
              AND NOT EXISTS(SELECT 1 FROM v2_group_avatar_intents i WHERE i.upload_job_id=shared.job_id)
        )
        """

    public func retainedResourceFileTokens() throws -> Set<String> {
        try databasePool.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT local_file_token FROM v2_resource_transfer_jobs j WHERE staging_released=0
                AND (stage NOT IN ('cancelled','rejected','expired')
                    OR EXISTS(SELECT 1 FROM v2_group_avatar_intents i WHERE i.upload_job_id=j.job_id
                        AND (i.stage NOT IN ('committed','cancelled','closed') OR (i.stage='closed' AND i.closed_disposition='awaitingDecision'))))
                """))
        }
    }

    public func saveResourceSession(_ session: V2ResourceUploadSession, for id: UUID) throws {
        try databasePool.write { db in
            guard let job = try Self.readResourceTransfer(id, db: db), job.request.mediaID == session.mediaID,
                  !job.cancellationRequested,
                  ![.cancelled, .rejected, .expired].contains(job.stage),
                  job.session.map({ $0.locator == session.locator && $0.generation <= session.generation }) ?? true else { throw V2ResourceJournalError.conflict }
            let stage: V2ResourceTransferJob.Stage
            switch session.state {
            case .cancelled: stage = .cancelled
            case .expired: stage = .expired
            case .failed: stage = .rejected
            default:
                if session.resourceState == .ready { stage = .ready }
                else if session.resourceState == .rejected || session.resourceState == .deleted || session.resourceState == .deletionPending { stage = .rejected }
                else if session.state == .finalizing || session.state == .completed { stage = .processing }
                else { stage = .transferring }
            }
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET session=?,stage=?,bindable_until=?,retry_at=?,last_error=NULL WHERE job_id=?", arguments: [try JSONEncoder().encode(session), stage.rawValue, session.bindableUntil?.timeIntervalSince1970, session.retryNotBefore?.timeIntervalSince1970 ?? 0, id.uuidString])
        }
    }

    public func retryResourceTransfer(id: UUID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET attempts=0,retry_at=0,last_error=NULL WHERE job_id=? AND stage='paused' AND cancellation_requested=0", arguments: [id.uuidString])
        }
    }

    public func requestResourceCancellation(id: UUID) throws -> V2ResourceTransferJob? {
        try databasePool.write { db in
            let stillUsed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_send_intent_dependencies d JOIN v2_send_intents i ON i.intent_id=d.intent_id WHERE d.job_id=? AND i.stage IN ('preparing','handedOff'))", arguments: [id.uuidString]) ?? false
            let avatarUsed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_group_avatar_intents WHERE upload_job_id=? AND stage NOT IN ('cancelled','closed'))", arguments: [id.uuidString]) ?? false
            guard !stillUsed, !avatarUsed else { return nil }
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET cancellation_requested=1 WHERE job_id=?", arguments: [id.uuidString])
            return try Self.readResourceTransfer(id, db: db)
        }
    }

    public func confirmResourceCancellation(id: UUID, session: V2ResourceUploadSession) throws {
        try databasePool.write { db in
            guard let job = try Self.readResourceTransfer(id, db: db), job.cancellationRequested,
                  job.request.mediaID == session.mediaID else { throw V2ResourceJournalError.conflict }
            // Completed means cancellation lost to completion; retain that fact,
            // without reactivating the cancelled send intent.
            guard [.cancelled, .completed, .expired, .failed].contains(session.state) else { throw V2ResourceJournalError.conflict }
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET session=?,stage=? WHERE job_id=?", arguments: [try JSONEncoder().encode(session), session.state == .completed ? "ready" : "cancelled", id.uuidString])
        }
    }

    public func pauseResourceTransfer(id: UUID, code: String, retryAt: Date) throws {
        guard ["network", "processing", "fileUnavailable", "rejected"].contains(code) else { throw V2ResourceJournalError.invalidRecord }
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET stage='paused',attempts=attempts+1,last_error=?,retry_at=? WHERE job_id=? AND stage NOT IN ('cancelled','rejected','expired','ready')", arguments: [code, try Self.commandRetryTimestamp(retryAt), id.uuidString])
        }
    }
}

import GRDB
extension GRDBV2LocalSyncStore {
    static func readResourceTransfer(_ id: UUID, db: Database) throws -> V2ResourceTransferJob? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_transfer_jobs WHERE job_id=?", arguments: [id.uuidString]),
              let stage = V2ResourceTransferJob.Stage(rawValue: row["stage"]) else { return nil }
        let bytes: Data? = row["session"]
        return try .init(id: id, request: JSONDecoder().decode(V2ResourceUploadRequest.self, from: row["request"]), localFileToken: row["local_file_token"], session: bytes.map { try JSONDecoder().decode(V2ResourceUploadSession.self, from: $0) }, stage: stage, cancellationRequested: row["cancellation_requested"], attempts: row["attempts"], retryAt: Date(timeIntervalSince1970: row["retry_at"]), lastError: row["last_error"])
    }
}

extension GRDBV2LocalSyncStore {
    public func pendingResourceCancellations() throws -> [UUID] {
        try databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT job_id FROM v2_resource_transfer_jobs WHERE cancellation_requested=1 AND stage NOT IN ('cancelled','ready','expired','rejected') ORDER BY created_at LIMIT 16").map {
                guard let id = UUID(uuidString: $0) else { throw V2ResourceJournalError.invalidRecord }; return id
            }
        }
    }
}
