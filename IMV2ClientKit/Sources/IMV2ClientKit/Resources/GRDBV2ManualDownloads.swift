import Foundation
import GRDB
import IMV2Core

extension V2ResourceFileJournal {
    /// The request has a business source, but no trusted byte version yet.
    /// Its logical identity is never used to authorize or deduplicate bytes.
    func enqueueUnresolvedDownload(mediaID: MediaID, message: V2MediaMessageLocation, now: Date = Date()) throws -> UUID {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw V2ResourceStorageError.invalidRecord }
        return try databasePool.write { db in
            guard try Self.messageMayResolve(message, mediaID: mediaID, db: db) else { throw V2ResourceStorageError.unavailable }
            if let row = try Row.fetchOne(db, sql: "SELECT job_id,control FROM v2_resource_download_jobs WHERE media_id=? AND room_id=? AND message_id=? AND finished_at IS NULL ORDER BY created_at,job_id LIMIT 1",
                arguments: [mediaID.rawValue,message.roomID.rawValue,message.messageID.rawValue]) {
                if row["control"] as String == "pause" { throw V2ResourceDownloadControlError.paused }
                guard row["control"] as String == "run", let id = UUID(uuidString: row["job_id"]) else { throw V2ResourceTransferManagementError.actionUnavailable }
                return id
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_download_jobs WHERE finished_at IS NULL") ?? 0 < 16 else { throw V2ResourceStorageError.capacityExceeded }
            let id = UUID()
            try db.execute(sql: "INSERT INTO v2_resource_download_jobs(job_id,media_id,room_id,message_id,transport,identity,work_priority,resume_requested,state,created_at) VALUES(?,?,?,?,'foreground',?,?,1,'paused',?)",
                arguments: [id.uuidString,mediaID.rawValue,message.roomID.rawValue,message.messageID.rawValue,"demand:" + id.uuidString,V2NetworkWorkPriority.interactive.rawValue,now.timeIntervalSince1970])
            return id
        }
    }

    /// Bind trusted network metadata without minting another task. Another
    /// source may already own these bytes; keep its writer and this demand separate.
    func resolveDownloadDemand(mediaID: MediaID, message: V2MediaMessageLocation?, bytes: Int64, checksum: V2ResourceChecksum) throws -> Bool {
        guard let message else { return false }
        return try databasePool.write { db in
            guard try Self.messageMayResolve(message, mediaID: mediaID, db: db) else { throw V2ResourceStorageError.unavailable }
            guard let row = try Row.fetchOne(db, sql: "SELECT job_id,control,byte_count,sha256 FROM v2_resource_download_jobs WHERE transport='foreground' AND media_id=? AND room_id=? AND message_id=? AND finished_at IS NULL ORDER BY created_at,job_id LIMIT 1",
                arguments: [mediaID.rawValue,message.roomID.rawValue,message.messageID.rawValue]) else { return false }
            if row["control"] as String == "pause" { throw V2ResourceDownloadControlError.paused }
            guard row["control"] as String == "run" else { throw V2ResourceTransferManagementError.actionUnavailable }
            if let known: Int64 = row["byte_count"] {
                guard known == bytes, row["sha256"] as String? == checksum.value else { throw V2ResourceStorageError.integrityMismatch }
            } else {
                let id: String = row["job_id"], identity = checksum.value + ":" + String(bytes)
                let shared = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_download_jobs WHERE identity=? AND finished_at IS NULL AND job_id<>?)", arguments: [identity,id]) ?? false
                try db.execute(sql: "UPDATE v2_resource_download_jobs SET identity=CASE WHEN ? THEN identity ELSE ? END,byte_count=?,sha256=? WHERE job_id=?",
                    arguments: [shared,identity,bytes,checksum.value,id])
            }
            return true
        }
    }

    static func messageMayResolve(_ message: V2MediaMessageLocation, mediaID: MediaID, db: Database) throws -> Bool {
        guard try !GRDBV2LocalSyncStore.resourceRoomIsDenied(message.roomID, db: db),
              try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_message_tombstones WHERE room_id=? AND message_id=?)", arguments: [message.roomID.rawValue,message.messageID.rawValue]) != true else { return false }
        if let row = try Row.fetchOne(db, sql: "SELECT is_withdrawn,media_ids FROM v2_message_projections WHERE room_id=? AND message_id=?", arguments: [message.roomID.rawValue,message.messageID.rawValue]) {
            guard row["is_withdrawn"] as Bool == false,
                  try GRDBV2LocalSyncStore.decodeMedia(row["media_ids"]).contains(where: { $0.mediaID == mediaID }) else { return false }
        }
        let args: StatementArguments = [message.roomID.rawValue,message.messageID.rawValue,mediaID.rawValue]
        let base = " FROM v2_resource_references r WHERE r.context_kind='message' AND r.home_kind='room' AND r.home_id=? AND r.context_id=? AND r.media_id=?"
        let known = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1" + base + ")", arguments: args) ?? false
        if !known { return true }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1" + base + " AND " + GRDBV2LocalSyncStore.visibleResourceMessageReferenceSQL + ")", arguments: args) ?? false
    }

    func completeResolvedMessageDemand(mediaID: MediaID, message: V2MediaMessageLocation?, fileID: V2LocalResourceFileID, owner: UUID, now: Date = Date()) throws {
        guard let message else { return }
        try databasePool.write { db in
            // Only logical demands are closed here. A physical writer keeps
            // its own completion/drain protocol even when another reader wins.
            try db.execute(sql: """
                UPDATE v2_resource_download_jobs SET state='completed',execution_owner=NULL,resume_requested=0,issue=NULL,finished_at=?
                WHERE transport='foreground' AND media_id=? AND room_id=? AND message_id=? AND identity LIKE 'demand:%'
                  AND finished_at IS NULL AND control='run' AND (execution_owner IS NULL OR execution_owner=?)
                  AND EXISTS(SELECT 1 FROM v2_resource_files f WHERE f.file_id=? AND f.state='published'
                    AND f.byte_count=v2_resource_download_jobs.byte_count AND f.checksum=v2_resource_download_jobs.sha256)
                """, arguments: [now.timeIntervalSince1970,mediaID.rawValue,message.roomID.rawValue,message.messageID.rawValue,owner.uuidString,fileID.value.uuidString])
            try GRDBV2LocalSyncStore.pruneResourceTransferHistory(db: db, now: now)
        }
    }

    /// Persist before network authorization or physical admission. This is a
    /// user command, never an access grant; recovery authorizes the source anew.
    func enqueueManualDownload(_ key: V2ResourceKey, source: V2ResourceMessageSource, now: Date = Date()) throws -> UUID {
        guard key.home == .room(source.location.roomID), (0..<V2MessageCommandLimits.maxMediaAttachments).contains(source.ordinal),
              now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw V2ResourceStorageError.invalidRecord }
        return try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT e.byte_count,e.checksum FROM v2_resource_entries e
                WHERE e.home_kind='room' AND e.home_id=? AND e.media_id=? AND e.state='ready' AND e.checksum IS NOT NULL
                  AND EXISTS(SELECT 1 FROM v2_resource_references r WHERE r.home_kind=e.home_kind AND r.home_id=e.home_id
                    AND r.media_id=e.media_id AND r.context_id=? AND r.ordinal=? AND
                """ + " " + GRDBV2LocalSyncStore.visibleResourceMessageReferenceSQL + ")",
                arguments: [source.location.roomID.rawValue,key.mediaID.rawValue,source.location.messageID.rawValue,source.ordinal]) else { throw V2ResourceStorageError.unavailable }
            let bytes: Int64 = row["byte_count"]
            let checksum = try V2ResourceChecksum(value: row["checksum"])
            let identity = checksum.value + ":" + String(bytes)
            if let existing = try Row.fetchOne(db, sql: """
                SELECT job_id,control,state,byte_count,sha256 FROM v2_resource_download_jobs
                WHERE finished_at IS NULL AND (identity=? OR (media_id=? AND room_id=?)) ORDER BY created_at,job_id LIMIT 1
                """, arguments: [identity,key.mediaID.rawValue,source.location.roomID.rawValue]) {
                if existing["control"] as String == "pause" { throw V2ResourceDownloadControlError.paused }
                guard existing["control"] as String == "run", existing["state"] as String != "cancelled",
                      let id = UUID(uuidString: existing["job_id"]) else { throw V2ResourceTransferManagementError.actionUnavailable }
                if let expected: Int64 = existing["byte_count"] {
                    guard expected == bytes, existing["sha256"] as String? == checksum.value else { throw V2ResourceStorageError.integrityMismatch }
                }
                // Keep its source, controls, retry floor and charged attempts.
                // A repeated click cannot revive or reset a stopped round.
                try db.execute(sql: "UPDATE v2_resource_download_jobs SET work_priority=MIN(work_priority,?) WHERE job_id=?",
                    arguments: [V2NetworkWorkPriority.interactive.rawValue,id.uuidString])
                return id
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_download_jobs WHERE finished_at IS NULL") ?? 0 < 16 else { throw V2ResourceStorageError.capacityExceeded }
            let id = UUID()
            try db.execute(sql: """
                INSERT INTO v2_resource_download_jobs(job_id,media_id,room_id,message_id,transport,work_priority,
                    identity,byte_count,sha256,resume_requested,state,created_at)
                VALUES(?,?,?,?,'foreground',?,?,?, ?,1,'paused',?)
                """, arguments: [id.uuidString,key.mediaID.rawValue,source.location.roomID.rawValue,source.location.messageID.rawValue,
                    V2NetworkWorkPriority.interactive.rawValue,identity,bytes,checksum.value,now.timeIntervalSince1970])
            return id
        }
    }
}
