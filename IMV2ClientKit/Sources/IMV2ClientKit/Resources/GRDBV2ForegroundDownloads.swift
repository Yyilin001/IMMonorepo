import Foundation
import GRDB
import IMV2Core

enum V2ResourceDownloadIssue: String, Sendable { case interrupted, network, integrity, space, unavailable, policy }
enum V2ResourceDownloadControl: String, Sendable { case run, pause, cancel }
public enum V2ResourceDownloadControlError: Error, Equatable, Sendable { case paused }
enum V2ResourceDownloadOutcome: Equatable, Sendable {
    case completed, cancelled, failed(V2ResourceDownloadIssue)
    var state: String { switch self { case .completed: "completed"; case .cancelled: "stopped"; case .failed: "failed" } }
    var issue: String? { if case .failed(let issue) = self { issue.rawValue } else { nil } }
}

extension V2ResourceFileJournal {
    /// Joining an owned flight upgrades recovery intent without resetting its
    /// attempts, controls or writer claim. Never revives a paused/cancelled job.
    func promoteForegroundDownload(_ id: UUID, owner: UUID, priority: V2NetworkWorkPriority) throws {
        try databasePool.write { db in
            try db.execute(sql: """
                UPDATE v2_resource_download_jobs SET work_priority=MIN(work_priority,?)
                WHERE job_id=? AND transport='foreground' AND execution_owner=?
                    AND control='run' AND finished_at IS NULL
                """, arguments: [priority.rawValue,id.uuidString,owner.uuidString])
        }
    }

    func recoverForegroundDownloads(owner: UUID) throws {
        try databasePool.write { db in
            try db.execute(sql: """
                UPDATE v2_resource_download_jobs SET state=CASE control WHEN 'cancel' THEN 'cancelled' ELSE 'paused' END,
                    issue=CASE control WHEN 'pause' THEN NULL ELSE 'interrupted' END,
                    resume_requested=CASE control WHEN 'run' THEN resume_requested ELSE 0 END,execution_owner=NULL
                WHERE transport='foreground' AND finished_at IS NULL AND execution_owner IS NOT NULL AND execution_owner<>?
                """, arguments: [owner.uuidString])
            try GRDBV2LocalSyncStore.pruneResourceTransferHistory(db: db, now: Date())
        }
    }

    func beginForegroundDownload(identity: String, mediaID: MediaID, message: V2MediaMessageLocation?,
                                 bytes: Int64, checksum: V2ResourceChecksum, owner: UUID, now: Date = Date(), priority: V2NetworkWorkPriority = .interactive) throws -> UUID {
        guard identity == checksum.value + ":" + String(bytes), bytes > 0 else { throw V2ResourceStorageError.invalidRecord }
        return try databasePool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT job_id,byte_count,sha256,execution_owner,state,control FROM v2_resource_download_jobs WHERE transport='foreground' AND identity=? AND finished_at IS NULL", arguments: [identity]) {
                if row["control"] as String == "pause" { throw V2ResourceDownloadControlError.paused }
                guard let id = UUID(uuidString: row["job_id"]), row["byte_count"] as Int64 == bytes,
                      row["sha256"] as String == checksum.value,
                      row["state"] as String != "cancelled", row["control"] as String == "run",
                      (row["execution_owner"] as String?).map({ $0 == owner.uuidString }) ?? true else { throw V2ResourceStorageError.conflict }
                // This private cache owner starts at most one physical flight
                // per identity and drains it before another can begin. Its own
                // leftover claim can be resumed after a locked-DB release failed.
                try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='transferring',execution_owner=?,issue=NULL,work_priority=MIN(work_priority,?) WHERE job_id=?", arguments: [owner.uuidString,priority.rawValue,id.uuidString])
                return id
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_download_jobs WHERE finished_at IS NULL") ?? 0 < 16 else {
                throw V2ResourceStorageError.capacityExceeded
            }
            let id = UUID()
            try db.execute(sql: """
                INSERT INTO v2_resource_download_jobs(job_id,media_id,room_id,message_id,transport,identity,byte_count,sha256,execution_owner,resume_requested,state,created_at,work_priority)
                VALUES(?,?,?,?,'foreground',?,?,?,?,?,'transferring',?,?)
                """, arguments: [id.uuidString,mediaID.rawValue,message?.roomID.rawValue,message?.messageID.rawValue,
                    identity,bytes,checksum.value,owner.uuidString,message != nil,now.timeIntervalSince1970,priority.rawValue])
            return id
        }
    }

    func foregroundDownloadAwaitingVerification(_ id: UUID, owner: UUID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='downloaded' WHERE job_id=? AND transport='foreground' AND execution_owner=? AND state='transferring' AND control='run'", arguments: [id.uuidString,owner.uuidString])
            guard db.changesCount == 1 else { throw V2ResourceStorageError.conflict }
        }
    }

    func completeForegroundDownload(_ id: UUID, owner: UUID, fileID: V2LocalResourceFileID, now: Date = Date()) throws {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT state,byte_count,sha256,execution_owner,control FROM v2_resource_download_jobs WHERE job_id=? AND transport='foreground'", arguments: [id.uuidString]),
                  row["state"] as String == "downloaded", row["control"] as String == "run",
                  row["execution_owner"] as String? == owner.uuidString,
                  try Self.publishedDownloadFile(fileID, bytes: row["byte_count"], checksum: row["sha256"], db: db) else { throw V2ResourceStorageError.conflict }
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='completed',finished_at=?,execution_owner=NULL,resume_requested=0,issue=NULL WHERE job_id=?", arguments: [now.timeIntervalSince1970,id.uuidString])
            try GRDBV2LocalSyncStore.pruneResourceTransferHistory(db: db, now: now)
        }
    }

    /// Crash after byte publication but before the terminal task commit: a
    /// fresh authorized caller's verified cache hit can close the old record.
    func completeCachedForegroundDownloads(identity: String, fileID: V2LocalResourceFileID, idleOwner: UUID? = nil, now: Date = Date()) throws {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT job_id,byte_count,sha256 FROM v2_resource_download_jobs WHERE transport='foreground' AND identity=? AND control='run' AND finished_at IS NULL AND ((state='paused' AND execution_owner IS NULL) OR (execution_owner=? AND state IN ('transferring','downloaded')))", arguments: [identity,idleOwner?.uuidString]),
                  try Self.publishedDownloadFile(fileID, bytes: row["byte_count"], checksum: row["sha256"], db: db) else { return }
            let id: String = row["job_id"]
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='completed',finished_at=?,issue=NULL,resume_requested=0,execution_owner=NULL WHERE job_id=?", arguments: [now.timeIntervalSince1970,id])
            try GRDBV2LocalSyncStore.pruneResourceTransferHistory(db: db, now: now)
        }
    }

    private static func publishedDownloadFile(_ id: V2LocalResourceFileID, bytes: Int64, checksum: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_files WHERE file_id=? AND state='published' AND byte_count=? AND checksum=?)", arguments: [id.value.uuidString,bytes,checksum]) ?? false
    }

    @discardableResult
    func pauseForegroundDownload(_ id: UUID, owner: UUID, issue: V2ResourceDownloadIssue) throws -> V2ResourceDownloadControl? {
        try databasePool.write { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT control FROM v2_resource_download_jobs WHERE job_id=? AND transport='foreground' AND execution_owner=? AND finished_at IS NULL", arguments: [id.uuidString,owner.uuidString]) else { return nil }
            guard let control = V2ResourceDownloadControl(rawValue: raw) else { throw V2ResourceStorageError.invalidRecord }
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state=?,issue=?,resume_requested=0,execution_owner=NULL WHERE job_id=?", arguments: [control == .cancel ? "cancelled" : "paused",control == .pause ? nil : issue.rawValue,id.uuidString])
            return control
        }
    }

    /// A live mutation requires proof from this cache's actual operation map.
    /// The intent is durable before runtime cancellation is requested.
    func requestForegroundDownloadControl(_ id: UUID, control: V2ResourceDownloadControl, liveOwner: UUID?) throws -> Bool {
        guard control != .run else { throw V2ResourceTransferManagementError.actionUnavailable }
        return try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT execution_owner,state,control,resume_requested,room_id,message_id,media_id FROM v2_resource_download_jobs WHERE job_id=? AND transport='foreground' AND finished_at IS NULL", arguments: [id.uuidString]) else { throw V2ResourceTransferManagementError.actionUnavailable }
            let owner: String? = row["execution_owner"], current: String = row["control"]
            if control == .cancel, current == "cancel", owner == nil, row["state"] as String == "cancelled" { return true }
            guard current != "cancel", control == .cancel || current == "run",
                  owner == nil || owner == liveOwner?.uuidString else { throw V2ResourceTransferManagementError.actionUnavailable }
            let state: String = row["state"]
            guard ["preparing","transferring","downloaded","paused"].contains(state), owner != nil || state == "paused" else { throw V2ResourceTransferManagementError.actionUnavailable }
            if control == .pause {
                guard state != "paused" || row["resume_requested"] as Bool,
                      try Self.messageMayResolve(.init(roomID: .init(row["room_id"]), messageID: .init(row["message_id"])), mediaID: .init(row["media_id"]), db: db) else { throw V2ResourceTransferManagementError.actionUnavailable }
            }
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET control=?,resume_requested=0,state=CASE WHEN execution_owner IS NULL THEN ? ELSE state END,issue=CASE WHEN execution_owner IS NULL THEN NULL ELSE issue END WHERE job_id=?",
                arguments: [control.rawValue,control == .pause ? "paused" : "cancelled",id.uuidString])
            return owner == nil
        }
    }

    func requestForegroundDownloadCancellation(_ id: UUID) throws -> String {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT identity FROM v2_resource_download_jobs WHERE job_id=? AND transport='foreground' AND state IN ('paused','cancelled') AND execution_owner IS NULL", arguments: [id.uuidString]) else { throw V2ResourceTransferManagementError.actionUnavailable }
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='cancelled',control='cancel',resume_requested=0 WHERE job_id=?", arguments: [id.uuidString])
            return row["identity"]
        }
    }
    func cancelledForegroundDownloads() throws -> [(id: UUID, identity: String)] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT job_id,identity FROM v2_resource_download_jobs WHERE transport='foreground' AND state='cancelled' AND execution_owner IS NULL LIMIT 16").map {
                guard let id = UUID(uuidString: $0["job_id"]) else { throw V2ResourceStorageError.invalidRecord }
                return (id,$0["identity"])
            }
        }
    }
    func finishForegroundDownloadCancellation(_ id: UUID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='stopped',finished_at=?,issue=NULL WHERE job_id=? AND transport='foreground' AND state='cancelled' AND execution_owner IS NULL", arguments: [Date().timeIntervalSince1970,id.uuidString])
            guard db.changesCount == 1 else { throw V2ResourceTransferManagementError.actionUnavailable }
            try GRDBV2LocalSyncStore.pruneResourceTransferHistory(db: db, now: Date())
        }
    }
}
