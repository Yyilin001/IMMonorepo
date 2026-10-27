import Foundation
import GRDB
import IMV2Core

struct V2ResourceDownloadResume: Sendable {
    enum Transport: String, Sendable { case foreground, background }
    let id: UUID
    let transport: Transport
    let priority: V2NetworkWorkPriority
    let mediaID: MediaID
    let message: V2MediaMessageLocation
    let bytes: Int64?
    let checksum: V2ResourceChecksum?
    var identity: String? { guard let checksum, let bytes else { return nil }; return checksum.value + ":" + String(bytes) }
}

extension V2ResourceFileJournal {
    func activeMessageDownload(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> UUID? {
        guard let message else { return nil }
        return try databasePool.read {
            try String.fetchOne($0, sql: "SELECT job_id FROM v2_resource_download_jobs WHERE media_id=? AND room_id=? AND message_id=? AND finished_at IS NULL ORDER BY created_at,job_id LIMIT 1",
                arguments: [mediaID.rawValue,message.roomID.rawValue,message.messageID.rawValue]).flatMap(UUID.init(uuidString:))
        }
    }
    func automaticNetworkWaitingJobs() throws -> [UUID] {
        try databasePool.read {
            try String.fetchAll($0, sql: "SELECT job_id FROM v2_resource_download_jobs WHERE work_priority=3 AND control='run' AND resume_requested=1 AND execution_owner IS NULL AND finished_at IS NULL AND state IN ('preparing','paused') ORDER BY created_at,job_id LIMIT 16").compactMap(UUID.init(uuidString:))
        }
    }
    func currentDownloadIdentity(_ id: UUID) throws -> String? {
        try databasePool.read { try String.fetchOne($0, sql: "SELECT identity FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]) }
    }
    private struct ResumeHead: Equatable, Sendable { let id: String; let priority: Int; let due: Int64 }
    private static let requestedDownloadPredicate = "control='run' AND resume_requested=1 AND execution_owner IS NULL AND ((transport='foreground' AND state='paused') OR (transport='background' AND state IN ('paused','preparing','downloaded')))"

    func downloadIsBackground(_ id: UUID) throws -> Bool {
        try databasePool.read { db in
            guard let transport = try String.fetchOne(db, sql: "SELECT transport FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]) else { throw V2ResourceTransferManagementError.actionUnavailable }
            return transport == "background"
        }
    }

    func recoverBackgroundResumeOwners(owner: UUID) throws {
        try databasePool.write {
            try $0.execute(sql: "UPDATE v2_resource_download_jobs SET execution_owner=NULL WHERE transport='background' AND execution_owner IS NOT NULL AND execution_owner<>? AND finished_at IS NULL", arguments: [owner.uuidString])
        }
    }

    func releaseBackgroundResume(_ id: UUID, owner: UUID, issue: V2ResourceDownloadIssue) throws {
        try databasePool.write {
            try $0.execute(sql: "UPDATE v2_resource_download_jobs SET execution_owner=NULL,resume_requested=0,issue=CASE WHEN issue='policy' THEN issue ELSE ? END WHERE job_id=? AND transport='background' AND execution_owner=? AND finished_at IS NULL", arguments: [issue.rawValue,id.uuidString,owner.uuidString])
        }
    }

    func downloadResumeSchedule() -> V2CommandRetrySchedule {
        let pool = databasePool
        let sql = "SELECT MIN(CASE WHEN transport='foreground' THEN retry_at_milliseconds ELSE 0 END) FROM v2_resource_download_jobs WHERE " + Self.requestedDownloadPredicate
        return .init(nextAttemptAt: {
            try await pool.read { db in try Int64.fetchOne(db, sql: sql).map { Date(timeIntervalSince1970: Double($0) / 1000) } }
        }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let observer = Task {
                    do {
                        for try await _ in ValueObservation.tracking({ db in
                            try Row.fetchAll(db, sql: "SELECT job_id,work_priority,retry_at_milliseconds FROM v2_resource_download_jobs WHERE " + Self.requestedDownloadPredicate + " ORDER BY work_priority,created_at,job_id LIMIT 64")
                                .map { ResumeHead(id: $0["job_id"], priority: $0["work_priority"], due: $0["retry_at_milliseconds"]) }
                                + Self.automaticDownloadCandidates(db: db).map { ResumeHead(id: "automatic:" + $0.mediaID.rawValue, priority: V2NetworkWorkPriority.background.rawValue, due: 0) }
                                + [ResumeHead(id: "policy:" + (try Self.readDownloadNetworkPreferences(db: db).automaticDownloads.categories.map(\.rawValue).sorted().joined(separator: ",")), priority: 0,
                                    due: try Self.readDownloadNetworkPreferences(db: db).automaticDownloads.maximumByteCount)]
                        }).removeDuplicates()
                            .values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(()) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in observer.cancel() }
            }
        })
    }

    func requestedDownloads(limit: Int = 4, excluding: Set<UUID> = [], now: Date = Date(), allowingAutomatic: Bool = true) throws -> [UUID] {
        guard (1...64).contains(limit), excluding.count <= 64 else { throw V2ResourceStorageError.invalidRecord }
        return try databasePool.read { db in
            let excluded = excluding.isEmpty ? "" : " AND job_id NOT IN (" + Array(repeating: "?", count: excluding.count).joined(separator: ",") + ")"
            var arguments = StatementArguments(excluding.map(\.uuidString)); arguments += [Int64((now.timeIntervalSince1970 * 1000).rounded(.down)),limit]
            let automatic = allowingAutomatic ? "" : " AND (work_priority<>3 OR (transport='background' AND state='downloaded'))"
            return try String.fetchAll(db, sql: "SELECT job_id FROM v2_resource_download_jobs WHERE " + Self.requestedDownloadPredicate + excluded + automatic + " AND (transport<>'foreground' OR retry_at_milliseconds<=?) ORDER BY work_priority,created_at,job_id LIMIT ?", arguments: arguments).map {
                guard let id = UUID(uuidString: $0) else { throw V2ResourceStorageError.invalidRecord }; return id
            }
        }
    }

    func nextRequestedDownloadAttempt(excluding: Set<UUID>, allowingAutomatic: Bool) throws -> Date? {
        try databasePool.read { db in
            let excluded = excluding.isEmpty ? "" : " AND job_id NOT IN (" + Array(repeating: "?", count: excluding.count).joined(separator: ",") + ")"
            let automatic = allowingAutomatic ? "" : " AND (work_priority<>3 OR (transport='background' AND state='downloaded'))"
            return try Int64.fetchOne(db, sql: "SELECT MIN(CASE WHEN transport='foreground' THEN retry_at_milliseconds ELSE 0 END) FROM v2_resource_download_jobs WHERE " + Self.requestedDownloadPredicate + excluded + automatic,
                arguments: StatementArguments(excluding.map(\.uuidString))).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        }
    }

    /// Runtime ownership proves that these claims have no live writer. Never
    /// reclaim a same-cache foreground identity still doing physical work.
    func recoverIdleDownloadClaims(owner: UUID, liveJobs: Set<UUID>, liveIdentities: Set<String>) throws {
        guard liveJobs.count <= 64, liveIdentities.count <= 64 else { throw V2ResourceStorageError.invalidRecord }
        try databasePool.write { db in
            let jobs = liveJobs.isEmpty ? "" : " AND job_id NOT IN (" + Array(repeating: "?", count: liveJobs.count).joined(separator: ",") + ")"
            let identities = liveIdentities.isEmpty ? "" : " AND identity NOT IN (" + Array(repeating: "?", count: liveIdentities.count).joined(separator: ",") + ")"
            var args: StatementArguments = [owner.uuidString]; args += StatementArguments(liveJobs.map(\.uuidString)); args += StatementArguments(liveIdentities)
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state=CASE control WHEN 'cancel' THEN 'cancelled' ELSE 'paused' END,execution_owner=NULL,resume_requested=CASE control WHEN 'run' THEN resume_requested ELSE 0 END,issue=CASE control WHEN 'pause' THEN NULL ELSE 'interrupted' END WHERE transport='foreground' AND finished_at IS NULL AND execution_owner=?" + jobs + identities, arguments: args)
            var background: StatementArguments = [owner.uuidString]; background += StatementArguments(liveJobs.map(\.uuidString))
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET execution_owner=NULL WHERE transport='background' AND finished_at IS NULL AND execution_owner=?" + jobs, arguments: background)
        }
    }

    /// The durable request is a command, never an access grant. Revalidate the
    /// original message before claiming, then the network leaf authorizes anew.
    func claimDownloadResume(_ id: UUID, owner: UUID, now: Date = Date()) throws -> V2ResourceDownloadResume? {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_download_jobs WHERE job_id=? AND " + Self.requestedDownloadPredicate, arguments: [id.uuidString]) else { return nil }
            let location = try V2MediaMessageLocation(roomID: .init(row["room_id"]), messageID: .init(row["message_id"]))
            let visible = try Self.messageMayResolve(location, mediaID: .init(row["media_id"]), db: db)
            if row["transport"] as String == "foreground",
               row["retry_at_milliseconds"] as Int64 > Int64((now.timeIntervalSince1970 * 1000).rounded(.down)) { return nil }
            let attempts: Int = row["attempt_count"]
            guard visible, attempts < 5 else {
                try db.execute(sql: "UPDATE v2_resource_download_jobs SET resume_requested=0,issue=? WHERE job_id=?", arguments: [visible ? "interrupted" : "unavailable",id.uuidString])
                return nil
            }
            guard let transport = V2ResourceDownloadResume.Transport(rawValue: row["transport"]) else { throw V2ResourceStorageError.invalidRecord }
            guard let priority = V2NetworkWorkPriority(rawValue: row["work_priority"]) else { throw V2ResourceStorageError.invalidRecord }
            let request = try V2ResourceDownloadResume(id: id, transport: transport, priority: priority, mediaID: .init(row["media_id"]),
                message: .init(roomID: .init(row["room_id"]), messageID: .init(row["message_id"])),
                bytes: row["byte_count"], checksum: (row["sha256"] as String?).map { try .init(value: $0) })
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state=CASE transport WHEN 'foreground' THEN 'preparing' ELSE state END,execution_owner=?,attempt_count=attempt_count+1,automatic_retry_allowed=0,issue=NULL WHERE job_id=?", arguments: [owner.uuidString,id.uuidString])
            return request
        }
    }

    func completeResumedDownload(_ request: V2ResourceDownloadResume, owner: UUID, fileID: V2LocalResourceFileID) throws {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT state,execution_owner,control,mapping_id,byte_count,sha256 FROM v2_resource_download_jobs WHERE job_id=?", arguments: [request.id.uuidString]) else { throw V2ResourceStorageError.conflict }
            if row["state"] as String == "completed" { return }
            guard row["execution_owner"] as String? == owner.uuidString, row["control"] as String == "run",
                  request.transport == .foreground || (row["mapping_id"] as String?) == nil,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_files WHERE file_id=? AND state='published' AND byte_count=? AND checksum=?)", arguments: [fileID.value.uuidString,row["byte_count"] as Int64?,row["sha256"] as String?]) == true else { throw V2ResourceStorageError.conflict }
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='completed',execution_owner=NULL,resume_requested=0,issue=NULL,finished_at=? WHERE job_id=?", arguments: [Date().timeIntervalSince1970,request.id.uuidString])
            try GRDBV2LocalSyncStore.pruneResourceTransferHistory(db: db, now: Date())
        }
    }
}
