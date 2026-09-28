import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    // The store is account-bound. All creation paths call this within the same
    // write transaction as the job and any consuming intent; paused/unknown
    // jobs retain their reservation until an authoritative terminal result.
    static func requireResourceJobCapacity(db: Database) throws {
        let count = try Int.fetchOne(db, sql: """
            SELECT
              (SELECT COUNT(*) FROM v2_resource_transfer_jobs
               WHERE stage NOT IN ('ready','cancelled','rejected','expired')) +
              (SELECT COUNT(*) FROM v2_resource_import_jobs
               WHERE stage NOT IN ('ready','cancelled','failed'))
            """) ?? 0
        guard count < 32 else { throw V2ResourceJournalError.capacityExceeded }
    }

    static func prepareResourceImport(id: UUID, request: V2ResourceImportRequest,
                                      now: Date, db: Database) throws {
        if let existing = try readResourceImport(id, db: db) {
            guard existing.request == request else { throw V2ResourceJournalError.conflict }
            return
        }
        try requireResourceJobCapacity(db: db)
        try db.execute(sql: """
            INSERT INTO v2_resource_import_jobs(job_id,request,stage,created_at)
            VALUES(?,?,'pending',?)
            """, arguments: [id.uuidString, try JSONEncoder().encode(request), try commandRetryTimestamp(now)])
    }
}
