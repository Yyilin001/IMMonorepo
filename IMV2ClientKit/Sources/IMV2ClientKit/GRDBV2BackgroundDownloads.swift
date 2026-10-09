import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let backgroundDownloadSchemaSQL = """
        CREATE TABLE v2_background_download_jobs (
            job_id TEXT PRIMARY KEY NOT NULL,
            media_id TEXT NOT NULL,
            room_id TEXT,
            message_id TEXT,
            state TEXT NOT NULL CHECK(state IN ('preparing','paused','transferring','downloaded','cancelled')),
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
            CHECK((mapping_id IS NULL AND session_id IS NULL AND task_identifier IS NULL AND grant_id IS NULL
                AND expected_bytes IS NULL AND checksum IS NULL AND origin_digest IS NULL AND expires_at_milliseconds IS NULL)
                OR (mapping_id IS NOT NULL AND session_id IS NOT NULL AND task_identifier IS NOT NULL AND grant_id IS NOT NULL
                AND expected_bytes IS NOT NULL AND checksum IS NOT NULL AND origin_digest IS NOT NULL AND expires_at_milliseconds IS NOT NULL)),
            CHECK(state NOT IN ('preparing','paused') OR session_id IS NULL),
            CHECK(state NOT IN ('transferring','downloaded') OR session_id IS NOT NULL),
            UNIQUE(session_id, task_identifier)
        );
        """

    /// Persist intent before creating the OS task. A restart keeps this exact UUID.
    func beginBackgroundDownload(id: UUID, mediaID: MediaID, message: V2MediaMessageLocation?, accountID: UserID, adoptMatching: Bool = false, retryPaused: Bool = false) throws -> V2BackgroundDownloadJob {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            let matching = adoptMatching ? try Row.fetchOne(db,
                sql: "SELECT * FROM v2_background_download_jobs WHERE media_id=? AND room_id IS ? AND message_id IS ? AND state!='cancelled' LIMIT 1",
                arguments: [mediaID.rawValue, message?.roomID.rawValue, message?.messageID.rawValue]) : nil
            if let row = try matching ?? Row.fetchOne(db, sql: "SELECT * FROM v2_background_download_jobs WHERE job_id=?", arguments: [id.uuidString]) {
                let existing = try Self.readBackgroundDownload(row)
                guard existing.mediaID == mediaID, existing.message == message else { throw V2BackgroundTransferError.mappingConflict }
                // A fresh user request may restart a paused intent. Automatic
                // reconciliation never resets the bounded failure counter.
                if retryPaused, case .paused = existing.state {
                    try db.execute(sql: "UPDATE v2_background_download_jobs SET state='preparing',attempt_count=0,retry_at_milliseconds=0 WHERE job_id=? AND state='paused'", arguments: [existing.id.uuidString])
                    return .init(id: existing.id, mediaID: existing.mediaID, message: existing.message, state: .preparing)
                }
                return existing
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_background_download_jobs") ?? 0 < 16,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_background_download_jobs WHERE state != 'cancelled'") ?? 0 < 4
            else { throw V2BackgroundTransferError.capacityExceeded }
            try db.execute(sql: "INSERT INTO v2_background_download_jobs(job_id,media_id,room_id,message_id,state,created_at) VALUES(?,?,?,?,'preparing',?)",
                arguments: [id.uuidString, mediaID.rawValue, message?.roomID.rawValue, message?.messageID.rawValue, Date().timeIntervalSince1970])
            return .init(id: id, mediaID: mediaID, message: message, state: .preparing)
        }
    }

    func backgroundDownloads(accountID: UserID) throws -> [V2BackgroundDownloadJob] {
        try databasePool.read { db in
            try Self.requireDownloadAccount(accountID, db: db)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM v2_background_download_jobs ORDER BY created_at LIMIT 17")
            guard rows.count <= 16 else { throw V2BackgroundTransferError.capacityExceeded }
            return try rows.map(Self.readBackgroundDownload)
        }
    }

    /// Called after creating a suspended task and before resuming it.
    func installBackgroundDownloadTask(id: UUID, task: V2BackgroundDownloadTask, accountID: UserID) throws {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: """
                UPDATE v2_background_download_jobs SET state='transferring',mapping_id=?,session_id=?,task_identifier=?,grant_id=?,
                    expected_bytes=?,checksum=?,origin_digest=?,expires_at_milliseconds=? WHERE job_id=? AND state='preparing'
                """, arguments: [task.id.uuidString, task.sessionID.uuidString, task.identifier, task.grantID.uuidString, task.expectedByteCount,
                    task.checksum.value, task.originDigest, task.expiresAtMilliseconds, id.uuidString])
            guard db.changesCount == 1 else { throw V2BackgroundTransferError.mappingConflict }
        }
    }

    /// A late callback cannot overwrite a new attempt with a different OS identity.
    @discardableResult
    func finishBackgroundDownloadTask(id: UUID, mappingID: UUID, sessionID: UUID, identifier: Int, success: Bool, accountID: UserID) throws -> Bool {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            let retry = Int64((Date().addingTimeInterval(2).timeIntervalSince1970 * 1_000).rounded(.down))
            let fields = success ? "state='downloaded'" : "state=CASE WHEN attempt_count>=4 THEN 'paused' ELSE 'preparing' END,attempt_count=MIN(5,attempt_count+1),retry_at_milliseconds=\(retry),mapping_id=NULL,session_id=NULL,task_identifier=NULL,grant_id=NULL,expected_bytes=NULL,checksum=NULL,origin_digest=NULL,expires_at_milliseconds=NULL"
            try db.execute(sql: "UPDATE v2_background_download_jobs SET " + fields + " WHERE job_id=? AND state='transferring' AND mapping_id=? AND session_id=? AND task_identifier=?",
                arguments: [id.uuidString, mappingID.uuidString, sessionID.uuidString, identifier])
            return db.changesCount == 1
        }
    }

    /// Keep actual task identity until its cancellation has drained.
    func cancelBackgroundDownload(id: UUID, accountID: UserID) throws {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: "UPDATE v2_background_download_jobs SET state='cancelled' WHERE job_id=?", arguments: [id.uuidString])
        }
    }

    func failBackgroundDownloadPreparation(id: UUID, accountID: UserID) throws {
        let retry = Int64((Date().addingTimeInterval(2).timeIntervalSince1970 * 1_000).rounded(.down))
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: "UPDATE v2_background_download_jobs SET state=CASE WHEN attempt_count>=4 THEN 'paused' ELSE 'preparing' END,attempt_count=MIN(5,attempt_count+1),retry_at_milliseconds=? WHERE job_id=? AND state='preparing'",
                arguments: [retry, id.uuidString])
        }
    }

    /// Only after the actual OS task has drained, or its verified file was published.
    @discardableResult
    func retireBackgroundDownload(id: UUID, mappingID: UUID?, accountID: UserID) throws -> Bool {
        try databasePool.write { db in
            try Self.requireDownloadAccount(accountID, db: db)
            try db.execute(sql: "DELETE FROM v2_background_download_jobs WHERE job_id=? AND mapping_id IS ? AND state IN ('cancelled','downloaded')",
                arguments: [id.uuidString, mappingID?.uuidString])
            return db.changesCount == 1
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
        case "paused": guard task == nil else { throw V2BackgroundTransferError.mappingConflict }; state = .paused
        case "transferring": guard let task else { throw V2BackgroundTransferError.mappingConflict }; state = .transferring(task)
        case "downloaded": guard let task else { throw V2BackgroundTransferError.mappingConflict }; state = .downloaded(task)
        case "cancelled": state = .cancelled(task)
        default: throw V2BackgroundTransferError.mappingConflict
        }
        return try .init(id: id, mediaID: .init(row["media_id"]), message: location, state: state,
            attemptCount: row["attempt_count"], retryAtMilliseconds: row["retry_at_milliseconds"])
    }
}
