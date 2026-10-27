import Foundation
import GRDB
import IMV2Core

extension V2ResourceFileJournal {
    func recordAutomaticDownloadFailure(_ id: UUID, issue: V2ResourceDownloadIssue, now: Date, retryAfter: Date?) throws {
        try databasePool.write { db in
            guard let attempts = try Int.fetchOne(db, sql: "SELECT attempt_count FROM v2_resource_download_jobs WHERE job_id=? AND transport='foreground' AND work_priority=? AND state='paused' AND control='run' AND execution_owner IS NULL",
                arguments: [id.uuidString,V2NetworkWorkPriority.background.rawValue]) else { return }
            let due = issue == .policy ? Date(timeIntervalSince1970: 0)
                : max(now.addingTimeInterval(min(30, pow(2, Double(max(0, attempts - 1)))) * Double.random(in: 0.75...1.25)), retryAfter ?? now)
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET automatic_retry_allowed=?,issue=?,retry_at_milliseconds=? WHERE job_id=?",
                arguments: [attempts < 5,issue.rawValue,Int64((due.timeIntervalSince1970 * 1000).rounded(.down)),id.uuidString])
        }
    }

    /// Re-enable only explicitly classified temporary/policy failures, under
    /// current message authority and immutable metadata. Attempts never reset.
    func requeueRecoverableAutomaticDownloads() throws {
        try databasePool.write { db in
            let policy = try Self.readDownloadNetworkPreferences(db: db).automaticDownloads
            guard !policy.categories.isEmpty else { return }
            let kinds = policy.categories.map(\.rawValue).sorted()
            var arguments: StatementArguments = [V2NetworkWorkPriority.background.rawValue,policy.maximumByteCount]
            arguments += StatementArguments(kinds)
            let ids = try String.fetchAll(db, sql: """
                SELECT DISTINCT j.job_id FROM v2_resource_download_jobs j
                JOIN v2_resource_entries e ON e.home_kind='room' AND e.home_id=j.room_id AND e.media_id=j.media_id
                JOIN v2_resource_references r ON r.home_kind=e.home_kind AND r.home_id=e.home_id AND r.media_id=e.media_id AND r.context_id=j.message_id
                WHERE j.transport='foreground' AND j.work_priority=? AND j.state='paused' AND j.control='run'
                  AND j.execution_owner IS NULL AND j.resume_requested=0 AND j.automatic_retry_allowed=1 AND j.attempt_count<5
                  AND j.issue IN ('network','policy') AND e.state='ready' AND e.byte_count=j.byte_count AND e.checksum=j.sha256
                  AND e.byte_count<=? AND e.kind IN (
                """ + Array(repeating: "?", count: kinds.count).joined(separator: ",") + ") AND " + GRDBV2LocalSyncStore.visibleResourceMessageReferenceSQL + " LIMIT 2", arguments: arguments)
            for id in ids {
                try db.execute(sql: "UPDATE v2_resource_download_jobs SET resume_requested=1,issue=NULL WHERE job_id=?", arguments: [id])
            }
        }
    }

    struct AutomaticDownloadCandidate: Sendable {
        let mediaID: MediaID
        let roomID: RoomID
        let messageID: MessageID
        let bytes: Int64
        let checksum: V2ResourceChecksum
    }
    /// Local admission bookkeeping is not a second task state machine. Once
    /// admitted, only the canonical download journal owns retries and controls.
    static func automaticDownloadCandidates(db: Database) throws -> [AutomaticDownloadCandidate] {
        let policy = try readDownloadNetworkPreferences(db: db).automaticDownloads
        guard !policy.categories.isEmpty else { return [] }
        let live = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_download_jobs WHERE finished_at IS NULL") ?? 0
        // Automatic intent may be persisted while offline. Keep four logical
        // slots available for an explicit user request rather than filling the
        // entire account queue with blocked prefetch work.
        guard live < 12 else { return [] }
        let kinds = policy.categories.map(\.rawValue).sorted()
        var arguments: StatementArguments = [policy.maximumByteCount]
        arguments += StatementArguments(kinds); arguments += [min(2, 12 - live)]
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.media_id,e.home_id,MIN(r.context_id) AS message_id,e.byte_count,e.checksum
            FROM v2_resource_entries e JOIN v2_resource_references r USING(home_kind,home_id,media_id)
            WHERE e.home_kind='room' AND e.automatic_download_admitted=0 AND e.state='ready' AND e.checksum IS NOT NULL
              AND e.byte_count<=? AND e.kind IN (
            """ + Array(repeating: "?", count: kinds.count).joined(separator: ",") + ") AND " + GRDBV2LocalSyncStore.visibleResourceMessageReferenceSQL + """
              AND NOT EXISTS(SELECT 1 FROM v2_resource_cached_versions c JOIN v2_resource_files f USING(file_id)
                WHERE c.media_id=e.media_id AND f.state='published')
              AND NOT EXISTS(SELECT 1 FROM v2_resource_download_jobs j WHERE j.media_id=e.media_id
                OR j.identity=e.checksum||':'||CAST(e.byte_count AS TEXT))
            GROUP BY e.home_kind,e.home_id,e.media_id ORDER BY e.indexed_at DESC,e.media_id LIMIT ?
            """, arguments: arguments)
        return try rows.map { try .init(mediaID: .init($0["media_id"]), roomID: .init($0["home_id"]),
            messageID: .init($0["message_id"]), bytes: $0["byte_count"], checksum: .init(value: $0["checksum"])) }
    }
    func enqueueAutomaticDownloads() throws {
        try databasePool.write { db in
            for item in try Self.automaticDownloadCandidates(db: db) {
                let identity = item.checksum.value + ":" + String(item.bytes)
                try db.execute(sql: """
                    INSERT OR IGNORE INTO v2_resource_download_jobs(job_id,media_id,room_id,message_id,transport,work_priority,
                        identity,byte_count,sha256,resume_requested,state,created_at)
                    VALUES(?,?,?,?,'foreground',?,?,?, ?,1,'paused',?)
                    """, arguments: [UUID().uuidString,item.mediaID.rawValue,item.roomID.rawValue,item.messageID.rawValue,
                        V2NetworkWorkPriority.background.rawValue,identity,item.bytes,item.checksum.value,Date().timeIntervalSince1970])
                if db.changesCount == 1 {
                    try db.execute(sql: "UPDATE v2_resource_entries SET automatic_download_admitted=1 WHERE home_kind='room' AND home_id=? AND media_id=?",
                        arguments: [item.roomID.rawValue,item.mediaID.rawValue])
                }
            }
        }
    }
}
