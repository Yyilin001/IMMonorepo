import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    /// Called once by the new account owner. In-flight actions already persist
    /// their reconciliation action before I/O, so recovery never invents an ID.
    public func recoverResourceExecutions(owner: UUID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET execution_owner=NULL WHERE execution_owner IS NOT NULL AND execution_owner<>?", arguments: [owner.uuidString])
        }
    }
    func claimResourceStep(id: UUID, owner: UUID, now: Date) throws -> V2ResourceTransferJob? {
        try databasePool.write { db in
            guard let job = try Self.readResourceTransfer(id, db: db),
                  !job.needsAttention, job.nextAction != .awaitingBackground, job.retryAt <= now,
                  ![.ready,.cancelled,.rejected,.expired].contains(job.stage),
                  try String.fetchOne(db, sql: "SELECT execution_owner FROM v2_resource_transfer_jobs WHERE job_id=?", arguments: [id.uuidString]) == nil else { return nil }
            let policy = V2NetworkWorkPolicy.commandRecovery
            let deadline = job.roundDeadline ?? now.addingTimeInterval(policy.totalBudget)
            guard job.actionAttempts < policy.maximumAttempts, now < deadline else {
                try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET needs_attention=1,stage='paused',last_error='budgetExhausted' WHERE job_id=?", arguments: [id.uuidString])
                return nil
            }
            let recovery = job.cancellationRequested ? "cancel" : (job.session == nil ? "create" : "status")
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET execution_owner=?,next_action=?,last_error=COALESCE(last_error,'outcomeUnknown'),action_attempts=action_attempts+1,total_attempts=total_attempts+1,round_deadline=? WHERE job_id=?", arguments: [owner.uuidString,recovery,deadline.timeIntervalSince1970,id.uuidString])
            // Return the action that was claimed, including its charged budget.
            return .init(id: job.id, request: job.request, localFileToken: job.localFileToken,
                session: job.session, stage: job.stage, cancellationRequested: job.cancellationRequested,
                attempts: job.attempts, retryAt: job.retryAt, lastError: job.lastError,
                nextAction: job.cancellationRequested ? .cancel : job.nextAction,
                actionAttempts: job.actionAttempts + 1,totalAttempts: job.totalAttempts + 1,
                roundDeadline: deadline,pollAttempts: job.pollAttempts,needsAttention: false)
        }
    }
    func finishResourceStep(id: UUID, owner: UUID, next: V2ResourceTransferJob.Action,
                            retryAt: Date, processingPoll: Bool = false, preserveBudget: Bool = false) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET execution_owner=NULL,next_action=?,retry_at=MAX(server_retry_not_before,?),action_attempts=CASE WHEN ? THEN action_attempts ELSE 0 END,round_deadline=CASE WHEN ? THEN round_deadline ELSE NULL END,poll_attempts=poll_attempts+?,last_error=CASE WHEN ? THEN last_error ELSE NULL END WHERE job_id=? AND execution_owner=?", arguments: [next.rawValue,try Self.commandRetryTimestamp(retryAt),preserveBudget,preserveBudget,processingPoll ? 1 : 0,preserveBudget,id.uuidString,owner.uuidString])
        }
    }
    func failResourceStep(id: UUID, owner: UUID, code: String, retryAt: Date?, cancellation: Bool = false, serverRetryNotBefore: Date? = nil) throws {
        try databasePool.write { db in
            if let serverRetryNotBefore {
                try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET server_retry_not_before=MAX(server_retry_not_before,?) WHERE job_id=? AND execution_owner=?", arguments: [try Self.commandRetryTimestamp(serverRetryNotBefore),id.uuidString,owner.uuidString])
            }
            if cancellation {
                try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET execution_owner=NULL WHERE job_id=? AND execution_owner=?", arguments: [id.uuidString,owner.uuidString])
            } else {
                try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET execution_owner=NULL,stage='paused',attempts=attempts+1,last_error=?,retry_at=?,needs_attention=? WHERE job_id=? AND execution_owner=? AND stage NOT IN ('ready','cancelled','rejected','expired')", arguments: [code,try Self.commandRetryTimestamp(retryAt ?? .distantFuture),retryAt == nil,id.uuidString,owner.uuidString])
            }
        }
    }
    public func dueResourceTransfers(now: Date = Date(), limit: Int = 16) throws -> [UUID] {
        guard (1...64).contains(limit) else { throw V2ResourceJournalError.invalidRecord }
        return try databasePool.read { db in
            try String.fetchAll(db,sql:"SELECT job_id FROM v2_resource_transfer_jobs WHERE stage NOT IN ('ready','cancelled','rejected','expired') AND needs_attention=0 AND execution_owner IS NULL AND next_action<>'awaitingBackground' AND retry_at<=? ORDER BY retry_at,created_at LIMIT ?",arguments:[now.timeIntervalSince1970,limit]).map {
                guard let id = UUID(uuidString:$0) else { throw V2ResourceJournalError.invalidRecord }; return id
            }
        }
    }
    public nonisolated func resourceWorkSchedule() -> V2CommandRetrySchedule {
        let pool = databasePool
        let query = "SELECT MIN(retry_at) FROM v2_resource_transfer_jobs WHERE stage NOT IN ('ready','cancelled','rejected','expired') AND needs_attention=0 AND execution_owner IS NULL AND next_action<>'awaitingBackground'"
        return .init(nextAttemptAt: { try await pool.read { try Double.fetchOne($0, sql: query).map(Date.init(timeIntervalSince1970:)) } }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    do {
                        let observation = ValueObservation.tracking { db in try Double.fetchOne(db,sql:query) }.removeDuplicates()
                        for try await _ in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(()) }
                        continuation.finish()
                    } catch { continuation.finish(throwing:error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }
    /// Observation owns no transfer; cancelling the waiter does not revoke work.
    public nonisolated func resourceTransferUpdates(id: UUID) -> AsyncThrowingStream<V2ResourceTransferJob?, any Error> {
        let pool = databasePool
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db in try Self.readResourceTransfer(id, db:db) }.removeDuplicates()
                    for try await job in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(job) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
