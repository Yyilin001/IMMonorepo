import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    private static let readySendPredicate = """
        s.stage='preparing' AND s.attempts<5
        AND NOT EXISTS (SELECT 1 FROM v2_send_intent_dependencies d JOIN v2_resource_transfer_jobs r ON r.job_id=d.job_id WHERE d.intent_id=s.intent_id AND r.stage<>'ready')
        AND NOT EXISTS (SELECT 1 FROM v2_send_intent_import_dependencies d JOIN v2_resource_import_jobs r ON r.job_id=d.job_id WHERE d.intent_id=s.intent_id AND r.stage<>'ready')
        """
    private static let preparationDueQuery = """
        SELECT MIN(due) FROM (
        SELECT retry_at AS due FROM v2_resource_import_jobs WHERE stage NOT IN ('ready','cancelled','failed') AND attempts<5 AND user_control='run' AND execution_owner IS NULL
        UNION ALL SELECT retry_at FROM v2_send_intents s WHERE \(readySendPredicate)
        UNION ALL SELECT MAX(retry_at,COALESCE(claim_until,0)) FROM v2_group_avatar_intents g
        WHERE stage IN ('preparing','submitted') AND (submission_started=1 OR (upload_job_id IS NULL AND import_job_id IS NULL) OR EXISTS
            (SELECT 1 FROM v2_resource_transfer_jobs r WHERE r.job_id=g.upload_job_id AND (r.stage IN ('ready','cancelled','rejected','expired') OR r.needs_attention=1)) OR EXISTS(SELECT 1 FROM v2_resource_import_jobs r WHERE r.job_id=g.import_job_id AND (r.stage IN ('ready','cancelled','failed') OR r.attempts>=5)))
        UNION ALL SELECT 0 FROM v2_resource_transfer_jobs j WHERE \(resourceSourceReleasePredicate))
        """
    /// The account is the sole import/consumer owner. Resource byte work has a separate journal owner.
    public func resourcePreparationSchedule() -> V2CommandRetrySchedule {
        let pool = databasePool
        let query = Self.preparationDueQuery
        return V2CommandRetrySchedule(nextAttemptAt: {
            try await pool.read { try Double.fetchOne($0, sql: query).map(Date.init(timeIntervalSince1970:)) }
        }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let observer = Task {
                    do {
                        for try await _ in ValueObservation.tracking({ try Double.fetchOne($0, sql: query) }).removeDuplicates().values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(()) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in observer.cancel() }
            }
        })
    }
    public func runResourcePreparation(flush: @escaping @Sendable () async throws -> Void) async throws {
        try await V2CommandRetryScheduler(schedule: resourcePreparationSchedule(), flush: flush).run()
    }
    public func duePreparedSendIntents(now: Date = Date()) throws -> [V2SendIntent] {
        try databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT intent_id FROM v2_send_intents s WHERE \(Self.readySendPredicate) AND retry_at<=? ORDER BY created_at LIMIT 16", arguments: [now.timeIntervalSince1970]).map {
                guard let id = UUID(uuidString: $0), let intent = try Self.readSendIntent(id, db: db) else { throw V2ResourceJournalError.invalidRecord }
                return intent
            }
        }
    }
    public func preparedSendRequiresAttention(_ id: UUID) throws -> Bool {
        try databasePool.read { try Bool.fetchOne($0, sql: "SELECT attempts>=5 FROM v2_send_intents WHERE intent_id=?", arguments: [id.uuidString]) ?? false }
    }
    @discardableResult
    public func retryPreparedSendIntent(_ id: UUID, now: Date = Date()) throws -> UUID {
        try databasePool.write { db in
            if let raw = try String.fetchOne(db, sql: "SELECT intent_id FROM v2_send_intents WHERE replacement_of=?", arguments: [id.uuidString]) {
                guard let replacement = UUID(uuidString: raw) else { throw V2ResourceJournalError.invalidRecord }
                return replacement
            }
            guard let intent = try Self.readSendIntent(id, db: db), intent.stage == .preparing,
                  try Bool.fetchOne(db, sql: "SELECT work_id IS NULL FROM v2_send_intents WHERE intent_id=?",
                    arguments: [id.uuidString]) == true else { throw V2ResourceJournalError.conflict }
            if try Self.preparedSendNeedsRenewal(intent, now: now, db: db) {
                guard let created = try Double.fetchOne(db, sql: "SELECT created_at FROM v2_send_intents WHERE intent_id=?",
                    arguments: [id.uuidString]) else { throw V2ResourceJournalError.invalidRecord }
                return try Self.replaceUnsentSendIntent(intent, now: now, createdAt: .init(timeIntervalSince1970: created), db: db)
            }
            try db.execute(sql: "UPDATE v2_send_intents SET attempts=0,retry_at=0 WHERE intent_id=?", arguments: [id.uuidString])
            return id
        }
    }
    public func resourceImportDeadline(_ id: UUID) throws -> Date? {
        try databasePool.read { try Double.fetchOne($0, sql: "SELECT round_deadline FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString]).map(Date.init(timeIntervalSince1970:)) }
    }
    public func deferPreparedSendIntent(_ id: UUID, now: Date = Date()) throws {
        try databasePool.write { db in
            let attempts = try Int.fetchOne(db, sql: "SELECT attempts FROM v2_send_intents WHERE intent_id=?", arguments: [id.uuidString]) ?? 0
            let delay = Double.random(in: 0.5...1) * min(30, pow(2, Double(min(attempts,5))))
            try db.execute(sql: "UPDATE v2_send_intents SET attempts=attempts+1,retry_at=? WHERE intent_id=? AND stage='preparing'", arguments: [now.addingTimeInterval(delay).timeIntervalSince1970,id.uuidString])
        }
    }
    public func dueResourceImports(now: Date = Date()) throws -> [V2ResourceImportJob] {
        try databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT job_id FROM v2_resource_import_jobs WHERE stage NOT IN ('ready','cancelled','failed') AND attempts<5 AND user_control='run' AND execution_owner IS NULL AND retry_at<=? ORDER BY retry_at,created_at LIMIT 16", arguments: [now.timeIntervalSince1970]).map {
                guard let id = UUID(uuidString: $0), let job = try Self.readResourceImport(id, db: db) else { throw V2ResourceJournalError.invalidRecord }; return job
            }
        }
    }
    /// Charge before I/O. A crash preserves the original failure budget and next wake.
    public func claimResourceImport(_ id: UUID, owner: UUID, now: Date = Date()) throws -> Bool {
        try databasePool.write { db in
            guard let job = try Self.readResourceImport(id, db: db), job.control == .run, job.attempts<5, job.retryAt<=now,
                  try String.fetchOne(db, sql: "SELECT execution_owner FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString]) == nil,
                  job.status.map({ ![.ready,.cancelled,.failed].contains($0.state) }) ?? true else { return false }
            let deadline = try Double.fetchOne(db, sql: "SELECT round_deadline FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString]) ?? now.addingTimeInterval(60).timeIntervalSince1970
            if deadline<=now.timeIntervalSince1970 {
                try db.execute(sql: "UPDATE v2_resource_import_jobs SET attempts=5 WHERE job_id=?", arguments: [id.uuidString]); return false
            }
            let delay = Double.random(in: 0.5...1) * min(30,pow(2,Double(job.attempts)))
            try db.execute(sql: "UPDATE v2_resource_import_jobs SET execution_owner=?,attempts=attempts+1,round_deadline=?,retry_at=? WHERE job_id=?", arguments: [owner.uuidString,deadline,now.addingTimeInterval(delay).timeIntervalSince1970,id.uuidString]); return true
        }
    }
    public func releaseResourceImportExecution(_ id: UUID, owner: UUID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_import_jobs SET execution_owner=NULL WHERE job_id=? AND execution_owner=?", arguments: [id.uuidString,owner.uuidString])
            if try Bool.fetchOne(db, sql: "SELECT stage IN ('ready','cancelled') FROM v2_resource_import_jobs WHERE job_id=? AND execution_owner IS NULL", arguments: [id.uuidString]) == true {
                try Self.pruneResourceTransferHistory(db: db, now: Date())
            }
        }
    }
    public func recoverResourceImportExecutions(owner: UUID) throws {
        try databasePool.write { try $0.execute(sql: "UPDATE v2_resource_import_jobs SET execution_owner=NULL WHERE execution_owner IS NOT NULL AND execution_owner<>?", arguments: [owner.uuidString]) }
    }
}
