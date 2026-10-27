import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let resourceDownloadSchemaSQL = """
        CREATE TABLE v2_resource_download_jobs (
            job_id TEXT PRIMARY KEY NOT NULL,
            media_id TEXT NOT NULL,
            room_id TEXT,
            message_id TEXT,
            transport TEXT NOT NULL CHECK(transport IN ('foreground','background')),
            work_priority INTEGER NOT NULL DEFAULT 1 CHECK(work_priority BETWEEN 0 AND 3),
            identity TEXT,
            byte_count INTEGER CHECK(byte_count>0),
            sha256 TEXT CHECK(length(sha256)=64),
            execution_owner TEXT,
            issue TEXT CHECK(issue IN ('interrupted','network','integrity','space','unavailable','policy')),
            automatic_retry_allowed INTEGER NOT NULL DEFAULT 0 CHECK(automatic_retry_allowed IN (0,1)),
            resume_requested INTEGER NOT NULL DEFAULT 0 CHECK(resume_requested IN (0,1)),
            control TEXT NOT NULL DEFAULT 'run' CHECK(control IN ('run','pause','cancel')),
            history_retired INTEGER NOT NULL DEFAULT 0 CHECK(history_retired IN (0,1)),
            finished_at REAL,
            state TEXT NOT NULL CHECK(state IN ('preparing','paused','pausing','transferring','downloaded','cancelled','completed','stopped','failed')),
            mapping_id TEXT UNIQUE,
            session_id TEXT,
            task_identifier INTEGER CHECK(task_identifier >= 0),
            grant_id TEXT,
            expected_bytes INTEGER CHECK(expected_bytes > 0 AND expected_bytes <= 536870912),
            checksum TEXT CHECK(length(checksum) = 64),
            origin_digest TEXT CHECK(length(origin_digest) = 64),
            expires_at_milliseconds INTEGER CHECK(expires_at_milliseconds > 0),
            attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count BETWEEN 0 AND 5),
            retry_at_milliseconds INTEGER NOT NULL DEFAULT 0 CHECK(retry_at_milliseconds >= 0),
            created_at REAL NOT NULL,
            CHECK((room_id IS NULL) = (message_id IS NULL)),
            CHECK((byte_count IS NULL)=(sha256 IS NULL)),
            CHECK(transport='background' OR (identity IS NOT NULL AND session_id IS NULL AND
                (byte_count IS NOT NULL OR (room_id IS NOT NULL AND state IN ('preparing','paused','cancelled','stopped','failed'))))),
            CHECK((state IN ('completed','stopped','failed'))=(finished_at IS NOT NULL)),
            CHECK(finished_at IS NULL OR execution_owner IS NULL),
            CHECK(state<>'completed' OR byte_count IS NOT NULL),
            CHECK(resume_requested=0 OR (room_id IS NOT NULL AND finished_at IS NULL AND state<>'cancelled' AND (byte_count IS NOT NULL OR transport='foreground'))),
            CHECK(transport='foreground' OR control='run' OR (control='pause' AND state IN ('pausing','paused','cancelled','stopped'))),
            CHECK(resume_requested=0 OR control='run'),
            CHECK(state<>'pausing' OR (transport='background' AND control='pause')),
            CHECK(control<>'pause' OR transport='foreground' OR byte_count IS NOT NULL),
            CHECK(state<>'completed' OR control='run'),
            CHECK((mapping_id IS NULL AND session_id IS NULL AND task_identifier IS NULL AND grant_id IS NULL
                AND expected_bytes IS NULL AND checksum IS NULL AND origin_digest IS NULL AND expires_at_milliseconds IS NULL)
                OR (mapping_id IS NOT NULL AND session_id IS NOT NULL AND task_identifier IS NOT NULL AND grant_id IS NOT NULL
                AND expected_bytes IS NOT NULL AND checksum IS NOT NULL AND origin_digest IS NOT NULL AND expires_at_milliseconds IS NOT NULL)),
            CHECK(state NOT IN ('preparing','paused') OR session_id IS NULL),
            CHECK(transport='foreground' OR state NOT IN ('transferring','downloaded') OR session_id IS NOT NULL),
            UNIQUE(session_id, task_identifier)
        );
        CREATE INDEX v2_resource_download_created ON v2_resource_download_jobs(created_at DESC,job_id DESC);
        CREATE UNIQUE INDEX v2_resource_download_live_identity ON v2_resource_download_jobs(identity)
            WHERE transport='foreground' AND state NOT IN ('completed','stopped','failed');
        CREATE INDEX v2_resource_download_history ON v2_resource_download_jobs(finished_at DESC,job_id DESC)
            WHERE finished_at IS NOT NULL;
        CREATE INDEX v2_resource_download_resume ON v2_resource_download_jobs(created_at,job_id)
            WHERE resume_requested=1 AND execution_owner IS NULL;
        """

    /// Persist intent before creating the OS task. A restart keeps this exact UUID.
    func beginBackgroundDownload(id: UUID, mediaID: MediaID, message: V2MediaMessageLocation?, accountID: UserID, adoptMatching: Bool = false, retryPaused: Bool = false, requireExisting: Bool = false, priority: V2NetworkWorkPriority = .interactive) throws -> V2BackgroundDownloadJob {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            let matching = adoptMatching ? try Row.fetchOne(db,
                sql: "SELECT * FROM v2_resource_download_jobs WHERE transport='background' AND media_id=? AND room_id IS ? AND message_id IS ? AND state NOT IN ('cancelled','completed','stopped','failed') LIMIT 1",
                arguments: [mediaID.rawValue, message?.roomID.rawValue, message?.messageID.rawValue]) : nil
            if let row = try matching ?? Row.fetchOne(db, sql: "SELECT * FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]) {
                guard row["transport"] as String == "background" else { throw V2BackgroundTransferError.mappingConflict }
                let existing = try Self.readBackgroundDownload(row)
                guard row["control"] as String == "run" else { throw V2ResourceDownloadControlError.paused }
                guard existing.mediaID == mediaID, existing.message == message else { throw V2BackgroundTransferError.mappingConflict }
                // A fresh user request may restart a paused intent. Automatic
                // reconciliation never resets the bounded failure counter.
                if retryPaused, case .paused = existing.state {
                    try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='preparing',attempt_count=0,retry_at_milliseconds=0,work_priority=? WHERE job_id=? AND state='paused'", arguments: [priority.rawValue,existing.id.uuidString])
                    return .init(id: existing.id, mediaID: existing.mediaID, message: existing.message, state: .preparing, priority: priority)
                }
                return existing
            }
            guard !requireExisting else { throw CancellationError() }
            try Self.pruneResourceTransferHistory(db: db, now: Date())
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_download_jobs WHERE state NOT IN ('completed','stopped','failed')") ?? 0 < 16,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_download_jobs WHERE transport='background' AND state NOT IN ('cancelled','completed','stopped','failed')") ?? 0 < 4
            else { throw V2BackgroundTransferError.capacityExceeded }
            try db.execute(sql: "INSERT INTO v2_resource_download_jobs(job_id,media_id,room_id,message_id,transport,work_priority,state,created_at) VALUES(?,?,?,?,'background',?,'preparing',?)",
                arguments: [id.uuidString, mediaID.rawValue, message?.roomID.rawValue, message?.messageID.rawValue,priority.rawValue,Date().timeIntervalSince1970])
            return .init(id: id, mediaID: mediaID, message: message, state: .preparing, priority: priority)
        }
    }

    /// Promotion changes only demand. It neither retries nor revives a stopped
    /// or manually paused job, and must not reset its bounded recovery budget.
    func promoteBackgroundDownload(id: UUID, accountID: UserID, priority: V2NetworkWorkPriority) throws -> V2NetworkWorkPriority? {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: """
                UPDATE v2_resource_download_jobs SET work_priority=MIN(work_priority,?)
                WHERE job_id=? AND transport='background' AND control='run'
                    AND state IN ('preparing','transferring','downloaded') AND finished_at IS NULL
                """, arguments: [priority.rawValue,id.uuidString])
            guard db.changesCount == 1 else { return nil }
            guard let raw = try Int.fetchOne(db, sql: "SELECT work_priority FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]),
                  let result = V2NetworkWorkPriority(rawValue: raw) else { throw V2BackgroundTransferError.mappingConflict }
            return result
        }
    }

    func backgroundDownloads(accountID: UserID) throws -> [V2BackgroundDownloadJob] {
        try databasePool.read { db in
            try Self.requireDownloadAccount(accountID, db: db)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM v2_resource_download_jobs WHERE transport='background' AND state NOT IN ('completed','stopped','failed') ORDER BY created_at LIMIT 17")
            guard rows.count <= 16 else { throw V2BackgroundTransferError.capacityExceeded }
            return try rows.map(Self.readBackgroundDownload)
        }
    }

    /// Freeze bytes before native creation. New authorization may rotate the
    /// URL/grant, but it cannot silently change the resource being retried.
    func bindBackgroundDownloadBytes(id: UUID, target: V2ClientMediaTransferTarget, accountID: UserID) throws {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            guard let row = try Row.fetchOne(db, sql: "SELECT byte_count,sha256 FROM v2_resource_download_jobs WHERE job_id=? AND transport='background' AND state NOT IN ('cancelled','completed','stopped','failed')", arguments: [id.uuidString]) else { throw V2BackgroundTransferError.mappingConflict }
            if let bytes: Int64 = row["byte_count"] {
                guard bytes == target.expectedByteCount, row["sha256"] as String == target.checksum.value else { throw V2ResourceStorageError.integrityMismatch }
            } else {
                try db.execute(sql: "UPDATE v2_resource_download_jobs SET byte_count=?,sha256=? WHERE job_id=?", arguments: [target.expectedByteCount,target.checksum.value,id.uuidString])
            }
        }
    }

    func requestBackgroundDownloadCancellation(id: UUID, accountID: UserID) throws {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='cancelled',control='run',resume_requested=0 WHERE job_id=? AND transport='background' AND finished_at IS NULL", arguments: [id.uuidString])
            guard db.changesCount == 1 else { throw V2ResourceTransferManagementError.actionUnavailable }
        }
    }

    /// Persist pause intent before signalling any runtime owner. Mapping stays
    /// attached until the actual OS task and its preparation have drained.
    func requestBackgroundDownloadPause(id: UUID, accountID: UserID) throws {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            guard try Self.managedBackgroundDownloadMayPause(id, db: db) else { throw V2ResourceTransferManagementError.actionUnavailable }
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='pausing',control='pause',resume_requested=0,issue=NULL WHERE job_id=?", arguments: [id.uuidString])
        }
    }

    private static func managedBackgroundDownloadMayPause(_ id: UUID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM v2_resource_download_jobs j WHERE job_id=? AND transport='background'
                AND state IN ('preparing','transferring') AND control='run' AND byte_count IS NOT NULL
                AND EXISTS(SELECT 1 FROM v2_resource_references r WHERE r.home_kind='room' AND r.home_id=j.room_id
                    AND r.context_id=j.message_id AND r.media_id=j.media_id AND
            """ + " " + visibleResourceMessageReferenceSQL + "))", arguments: [id.uuidString]) ?? false
    }

    func finishBackgroundDownloadPause(id: UUID, mappingID: UUID?, accountID: UserID) throws {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: """
                UPDATE v2_resource_download_jobs SET state='paused',issue=NULL,execution_owner=NULL,mapping_id=NULL,session_id=NULL,
                    task_identifier=NULL,grant_id=NULL,expected_bytes=NULL,checksum=NULL,origin_digest=NULL,expires_at_milliseconds=NULL
                WHERE job_id=? AND transport='background' AND state='pausing' AND control='pause' AND mapping_id IS ?
                """, arguments: [id.uuidString,mappingID?.uuidString])
        }
    }

    /// Called after creating a suspended task and before resuming it.
    func installBackgroundDownloadTask(id: UUID, task: V2BackgroundDownloadTask, accountID: UserID) throws {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: """
                UPDATE v2_resource_download_jobs SET state='transferring',mapping_id=?,session_id=?,task_identifier=?,grant_id=?,
                    expected_bytes=?,checksum=?,origin_digest=?,expires_at_milliseconds=?,byte_count=?,sha256=? WHERE job_id=? AND transport='background' AND state='preparing'
                """, arguments: [task.id.uuidString, task.sessionID.uuidString, task.identifier, task.grantID.uuidString, task.expectedByteCount,
                    task.checksum.value, task.originDigest, task.expiresAtMilliseconds,task.expectedByteCount,task.checksum.value,id.uuidString])
            guard db.changesCount == 1 else { throw V2BackgroundTransferError.mappingConflict }
        }
    }

    /// A late callback cannot overwrite a new attempt with a different OS identity.
    @discardableResult
    func finishBackgroundDownloadTask(id: UUID, mappingID: UUID, sessionID: UUID, identifier: Int, success: Bool, accountID: UserID) throws -> Bool {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            let retry = Int64((Date().addingTimeInterval(2).timeIntervalSince1970 * 1_000).rounded(.down))
            let fields = success ? "state='downloaded',resume_requested=CASE WHEN room_id IS NOT NULL THEN 1 ELSE 0 END" : "state=CASE WHEN attempt_count>=4 THEN 'paused' ELSE 'preparing' END,attempt_count=MIN(5,attempt_count+1),retry_at_milliseconds=\(retry),mapping_id=NULL,session_id=NULL,task_identifier=NULL,grant_id=NULL,expected_bytes=NULL,checksum=NULL,origin_digest=NULL,expires_at_milliseconds=NULL"
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET " + fields + " WHERE job_id=? AND state='transferring' AND mapping_id=? AND session_id=? AND task_identifier=?",
                arguments: [id.uuidString, mappingID.uuidString, sessionID.uuidString, identifier])
            return db.changesCount == 1
        }
    }

    /// Keep actual task identity until its cancellation has drained.
    func cancelBackgroundDownload(id: UUID, accountID: UserID) throws {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='cancelled',control='run',resume_requested=0 WHERE job_id=? AND transport='background' AND state NOT IN ('completed','stopped','failed')", arguments: [id.uuidString])
        }
    }

    func restrictAutomaticBackgroundDownload(id: UUID, accountID: UserID) throws {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='paused',resume_requested=0,issue='policy' WHERE job_id=? AND transport='background' AND state='preparing' AND control='run'", arguments: [id.uuidString])
        }
    }

    func failBackgroundDownloadPreparation(id: UUID, accountID: UserID) throws {
        let retry = Int64((Date().addingTimeInterval(2).timeIntervalSince1970 * 1_000).rounded(.down))
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state=CASE WHEN attempt_count>=4 THEN 'paused' ELSE 'preparing' END,attempt_count=MIN(5,attempt_count+1),retry_at_milliseconds=? WHERE job_id=? AND state='preparing'",
                arguments: [retry, id.uuidString])
        }
    }

    /// Only after the actual OS task has drained, or its verified file was published.
    @discardableResult
    func retireBackgroundDownload(id: UUID, mappingID: UUID?, accountID: UserID, outcome: V2ResourceDownloadOutcome) throws -> Bool {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            let expected = outcome == .cancelled ? "cancelled" : "downloaded"
            try db.execute(sql: """
                UPDATE v2_resource_download_jobs SET state=?,finished_at=?,issue=?,execution_owner=NULL,resume_requested=0,mapping_id=NULL,session_id=NULL,task_identifier=NULL,
                    grant_id=NULL,expected_bytes=NULL,checksum=NULL,origin_digest=NULL,expires_at_milliseconds=NULL
                WHERE job_id=? AND transport='background' AND mapping_id IS ? AND state=?
                """, arguments: [outcome.state,Date().timeIntervalSince1970,outcome.issue,id.uuidString,mappingID?.uuidString,expected])
            let changed = db.changesCount == 1
            try Self.pruneResourceTransferHistory(db: db, now: Date())
            return changed
        }
    }

    func backgroundDownloadIsCompleted(id: UUID, accountID: UserID) throws -> Bool {
        try databasePool.read { db in
            try Self.requireDownloadAccount(accountID, db: db)
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_download_jobs WHERE job_id=? AND transport='background' AND state='completed')", arguments: [id.uuidString]) ?? false
        }
    }

    private static func requireDownloadAccount(_ account: UserID, db: Database) throws {
        guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == account.rawValue
        else { throw V2ClientLocalStorageError.installationBindingMismatch }
    }

    private static func readBackgroundDownload(_ row: Row) throws -> V2BackgroundDownloadJob {
        guard let id = UUID(uuidString: row["job_id"]) else { throw V2BackgroundTransferError.mappingConflict }
        let room: String? = row["room_id"], message: String? = row["message_id"]
        let location: V2MediaMessageLocation?
        if let room, let message { location = try .init(roomID: .init(room), messageID: .init(message)) }
        else { guard room == nil && message == nil else { throw V2BackgroundTransferError.mappingConflict }; location = nil }
        let task: V2BackgroundDownloadTask?
        if let session: String = row["session_id"] {
            guard let mappingID = UUID(uuidString: row["mapping_id"]), let sessionID = UUID(uuidString: session), let grantID = UUID(uuidString: row["grant_id"])
            else { throw V2BackgroundTransferError.mappingConflict }
            task = try .init(id: mappingID, sessionID: sessionID, identifier: row["task_identifier"], grantID: grantID,
                expectedByteCount: row["expected_bytes"], checksum: .init(value: row["checksum"]),
                originDigest: row["origin_digest"], expiresAtMilliseconds: row["expires_at_milliseconds"])
        } else { task = nil }
        let state: V2BackgroundDownloadJob.State
        switch row["state"] as String {
        case "preparing": guard task == nil else { throw V2BackgroundTransferError.mappingConflict }; state = .preparing
        case "pausing": state = .pausing(task)
        case "paused": guard task == nil else { throw V2BackgroundTransferError.mappingConflict }; state = .paused
        case "transferring": guard let task else { throw V2BackgroundTransferError.mappingConflict }; state = .transferring(task)
        case "downloaded": guard let task else { throw V2BackgroundTransferError.mappingConflict }; state = .downloaded(task)
        case "cancelled": state = .cancelled(task)
        default: throw V2BackgroundTransferError.mappingConflict
        }
        guard let priority = V2NetworkWorkPriority(rawValue: row["work_priority"]) else { throw V2BackgroundTransferError.mappingConflict }
        return try .init(id: id, mediaID: .init(row["media_id"]), message: location, state: state,
            attemptCount: row["attempt_count"], retryAtMilliseconds: row["retry_at_milliseconds"], priority: priority)
    }
}
