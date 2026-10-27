import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    private struct RetryHead: Equatable, Sendable { let id: String; let due: Double }
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
                  !job.needsAttention, job.control == .run, job.nextAction != .awaitingBackground, job.retryAt <= now,
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
            return .init(id: job.id, request: job.request, localAssetID: job.localAssetID,
                session: job.session, stage: job.stage, cancellationRequested: job.cancellationRequested, control: job.control,
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
            if try Bool.fetchOne(db, sql: "SELECT stage IN ('ready','cancelled') AND execution_owner IS NULL FROM v2_resource_transfer_jobs WHERE job_id=?", arguments: [id.uuidString]) == true {
                try Self.pruneResourceTransferHistory(db: db, now: Date())
            }
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
    public func dueResourceTransfers(now: Date = Date(), limit: Int = 16, excluding: Set<UUID> = []) throws -> [UUID] {
        guard (1...64).contains(limit), excluding.count <= 64 else { throw V2ResourceJournalError.invalidRecord }
        return try databasePool.read { db in
            let excluded = excluding.isEmpty ? "" : " AND job_id NOT IN (" + Array(repeating: "?", count: excluding.count).joined(separator: ",") + ")"
            var arguments: StatementArguments = [now.timeIntervalSince1970]
            arguments += StatementArguments(excluding.map(\.uuidString)); arguments += [limit]
            return try String.fetchAll(db,sql:"SELECT job_id FROM v2_resource_transfer_jobs WHERE stage NOT IN ('ready','cancelled','rejected','expired') AND needs_attention=0 AND user_control='run' AND execution_owner IS NULL AND next_action<>'awaitingBackground' AND retry_at<=?" + excluded + " ORDER BY retry_at,created_at,job_id LIMIT ?",arguments: arguments).map {
                guard let id = UUID(uuidString:$0) else { throw V2ResourceJournalError.invalidRecord }; return id
            }
        }
    }
    func nextResourceAttempt(excluding: Set<UUID>) throws -> Date? {
        guard excluding.count <= 64 else { throw V2ResourceJournalError.invalidRecord }
        return try databasePool.read { db in
            let excluded = excluding.isEmpty ? "" : " AND job_id NOT IN (" + Array(repeating: "?", count: excluding.count).joined(separator: ",") + ")"
            return try Double.fetchOne(db, sql: "SELECT MIN(retry_at) FROM v2_resource_transfer_jobs WHERE stage NOT IN ('ready','cancelled','rejected','expired') AND needs_attention=0 AND user_control='run' AND execution_owner IS NULL AND next_action<>'awaitingBackground'" + excluded, arguments: StatementArguments(excluding.map(\.uuidString))).map(Date.init(timeIntervalSince1970:))
        }
    }
    func resourceExecutionIsOwned(_ id: UUID, owner: UUID) throws -> Bool {
        try databasePool.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_transfer_jobs WHERE job_id=? AND execution_owner=?)", arguments: [id.uuidString,owner.uuidString]) ?? false }
    }
    public nonisolated func resourceWorkSchedule() -> V2CommandRetrySchedule {
        let pool = databasePool
        let query = "SELECT MIN(retry_at) FROM v2_resource_transfer_jobs WHERE stage NOT IN ('ready','cancelled','rejected','expired') AND needs_attention=0 AND user_control='run' AND execution_owner IS NULL AND next_action<>'awaitingBackground'"
        return .init(nextAttemptAt: { try await pool.read { try Double.fetchOne($0, sql: query).map(Date.init(timeIntervalSince1970:)) } }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    do {
                        // Identity matters: inserting another equally-due job
                        // must wake a free worker even if MIN(retry_at) is stable.
                        let observation = ValueObservation.tracking { db in
                            try Row.fetchAll(db, sql: "SELECT job_id,retry_at FROM v2_resource_transfer_jobs WHERE stage NOT IN ('ready','cancelled','rejected','expired') AND needs_attention=0 AND user_control='run' AND execution_owner IS NULL AND next_action<>'awaitingBackground' ORDER BY retry_at,created_at,job_id LIMIT 64")
                                .map { RetryHead(id: $0["job_id"], due: $0["retry_at"]) }
                        }.removeDuplicates()
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
