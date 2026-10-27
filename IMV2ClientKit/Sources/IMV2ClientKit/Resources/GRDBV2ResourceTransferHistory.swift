import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    /// Retiring presentation history never removes a dependency or a file.
    /// Business journals may retain hidden terminal facts until their owners GC.
    func pruneResourceTransferHistory(now: Date = Date()) throws {
        try databasePool.write { try Self.pruneResourceTransferHistory(db: $0, now: now) }
    }

    private static let visibleResourceHistorySQL = """
        SELECT 'upload' AS kind,job_id,finished_at FROM v2_resource_transfer_jobs
          WHERE stage IN ('ready','cancelled') AND execution_owner IS NULL AND history_retired=0 AND finished_at IS NOT NULL
            AND NOT EXISTS(SELECT 1 FROM v2_background_transfer_tasks b WHERE b.job_id=v2_resource_transfer_jobs.job_id AND b.state='active')
        UNION ALL SELECT 'import',job_id,finished_at FROM v2_resource_import_jobs
          WHERE stage IN ('ready','cancelled') AND execution_owner IS NULL AND history_retired=0 AND finished_at IS NOT NULL
        UNION ALL SELECT 'download',job_id,finished_at FROM v2_resource_download_jobs
          WHERE state IN ('completed','stopped') AND history_retired=0
        """

    static let retainDownloadAdmissionHistorySQL = """
        UPDATE v2_resource_entries SET automatic_download_admitted=1
        WHERE home_kind='room' AND automatic_download_admitted=0 AND (home_id,media_id) IN (
            SELECT room_id,media_id FROM v2_resource_download_jobs
            WHERE history_retired=1 AND state IN ('completed','stopped'))
        """

    static func pruneResourceTransferHistory(db: Database, now: Date) throws {
        let cutoff = try commandRetryTimestamp(now.addingTimeInterval(-30 * 24 * 60 * 60))
        let tables: [(String, String, String)] = [
            ("upload", "v2_resource_transfer_jobs", "stage IN ('ready','cancelled') AND execution_owner IS NULL AND NOT EXISTS(SELECT 1 FROM v2_background_transfer_tasks b WHERE b.job_id=v2_resource_transfer_jobs.job_id AND b.state='active')"),
            ("import", "v2_resource_import_jobs", "stage IN ('ready','cancelled') AND execution_owner IS NULL"),
            ("download", "v2_resource_download_jobs", "state IN ('completed','stopped')")
        ]
        for (kind, table, terminal) in tables {
            try db.execute(sql: "UPDATE " + table + " SET history_retired=1 WHERE history_retired=0 AND " + terminal + " AND finished_at IS NOT NULL AND (finished_at<=? OR (?,job_id) NOT IN (SELECT kind,job_id FROM (" + visibleResourceHistorySQL + ") ORDER BY finished_at DESC,kind DESC,job_id DESC LIMIT 500))", arguments: [cutoff,kind])
        }
        // Bounded physical metadata GC. Every incoming domain edge pins its
        // original fact, regardless of the dependent's display/history state.
        try db.execute(sql: """
            DELETE FROM v2_resource_transfer_jobs WHERE job_id IN (
              SELECT j.job_id FROM v2_resource_transfer_jobs j WHERE j.history_retired=1
                AND j.stage IN ('ready','cancelled') AND j.source_released=1 AND j.execution_owner IS NULL
                AND NOT EXISTS(SELECT 1 FROM v2_send_intent_dependencies d WHERE d.job_id=j.job_id)
                AND NOT EXISTS(SELECT 1 FROM v2_group_avatar_intents a WHERE a.upload_job_id=j.job_id)
                AND NOT EXISTS(SELECT 1 FROM v2_profile_intents p WHERE p.upload_job_id=j.job_id)
                AND NOT EXISTS(SELECT 1 FROM v2_background_transfer_tasks b WHERE b.job_id=j.job_id)
                AND NOT EXISTS(SELECT 1 FROM v2_resource_file_consumers c WHERE c.kind='upload' AND c.consumer_id=j.job_id)
              ORDER BY j.finished_at,j.job_id LIMIT 64)
            """)
        try db.execute(sql: """
            DELETE FROM v2_resource_import_jobs WHERE job_id IN (
              SELECT j.job_id FROM v2_resource_import_jobs j WHERE j.history_retired=1
                AND j.stage IN ('ready','cancelled') AND j.execution_owner IS NULL
                AND NOT EXISTS(SELECT 1 FROM v2_send_intent_import_dependencies d WHERE d.job_id=j.job_id)
                AND NOT EXISTS(SELECT 1 FROM v2_group_avatar_intents a WHERE a.import_job_id=j.job_id)
                AND NOT EXISTS(SELECT 1 FROM v2_profile_intents p WHERE p.import_job_id=j.job_id)
              ORDER BY j.finished_at,j.job_id LIMIT 64)
            """)
        try db.execute(sql: retainDownloadAdmissionHistorySQL)
        try db.execute(sql: """
            DELETE FROM v2_resource_download_jobs WHERE job_id IN (
              SELECT job_id FROM v2_resource_download_jobs WHERE history_retired=1 AND state IN ('completed','stopped')
              ORDER BY finished_at,job_id LIMIT 64)
            """)
    }
}
