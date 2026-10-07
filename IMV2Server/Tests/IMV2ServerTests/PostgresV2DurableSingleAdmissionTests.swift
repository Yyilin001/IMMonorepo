import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("single quota UPDATE observes the latest tuple and retries only a successful zero-row snapshot", arguments: [false, true])
    func durableSingleAdmissionObservesConcurrentCounter(counterReset: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, owner, _, sql, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools SET command_window_used=\(bind: counterReset ? 10 : 0),
                  command_window_limit=10 WHERE room_shard_id='room-b' AND capacity_profile_id='standard'
                """).run()
            let original = try #require(try await sql.raw("""
                SELECT lease_id,generation FROM im_v2.shard_admission_pools
                WHERE room_shard_id='room-b' AND capacity_profile_id='standard'
                """).first(decoding: SingleAdmissionLease.self))
            // A transition-table statement trigger distinguishes one successful
            // fast UPDATE from zero-row UPDATE followed by the existing gate.
            // It records actual affected rows, not the SQL the test expects.
            try await sql.raw("CREATE TABLE im_v2.single_admission_audit (transaction_id bigint NOT NULL, rows_changed bigint NOT NULL)").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.audit_single_admission() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                  INSERT INTO im_v2.single_admission_audit
                  SELECT txid_current(), count(*) FROM changed_pool;
                  RETURN NULL;
                END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER audit_single_admission AFTER UPDATE ON im_v2.shard_admission_pools
                REFERENCING NEW TABLE AS changed_pool FOR EACH STATEMENT
                EXECUTE FUNCTION im_v2.audit_single_admission()
                """).run()
            let metrics = V2SendOperationBatchMetrics()
            let gate = SingleAdmissionCounterGate()
            let deadline = ContinuousClock.now + .seconds(5)
            let holder = Task {
                do {
                    try await V2RoomSQLDeadline.withDeadline(deadline) {
                        try await v2WithRoomScopedTransaction(database: owner) { transaction in
                            let connection = try #require(transaction as? any SQLDatabase)
                            let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: SingleAdmissionCount.self))
                            // A real writer either advances the old counter or
                            // resets a committed full window while holding it.
                            try await connection.raw("""
                                UPDATE im_v2.shard_admission_pools SET command_window_used=\(bind: counterReset ? 0 : 1)
                                WHERE lease_id=\(bind: original.lease_id) AND generation=\(bind: original.generation)
                                """).run()
                            await gate.hold(pid: pid.value)
                        }
                    }
                } catch { await gate.release(); throw error }
            }
            await gate.waitUntilReady()
            let tail = Task {
                try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await v2WithRoomScopedTransaction(database: owner, sendOperationMetrics: metrics) { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: SingleAdmissionCount.self))
                        let txid = try #require(try await connection.raw("SELECT txid_current()::bigint AS value").first(decoding: SingleAdmissionCount.self))
                        await gate.registerTail(pid: pid.value, transactionID: txid.value)
                        try await v2ReserveDurableOwnerBatchAdmission([
                            .init(leaseID: original.lease_id, generation: original.generation,
                                commandDelta: 2, roomShardID: "room-b", capacityProfileID: "standard")
                        ], retryAfterSeconds: 1, now: now, sql: connection)
                    }
                }
            }
            do {
                var observedWait = false
                while ContinuousClock.now < deadline {
                    if let pids = await gate.participants {
                        let waiting = try await sql.raw("""
                            SELECT count(*)::bigint AS value FROM pg_stat_activity
                            WHERE datname=current_database() AND pid=\(bind: pids.tail)
                              AND state='active' AND wait_event_type='Lock'
                              AND \(bind: pids.holder)::integer=ANY(pg_blocking_pids(pid))
                            """).first(decoding: SingleAdmissionCount.self)
                        if waiting?.value == 1 { observedWait = true; break }
                    }
                    await Task.yield()
                }
                await gate.release()
                try await holder.value
                try await tail.value
                try #require(observedWait, "the actual quota statement must wait for our real writer")
                let used = try await sql.raw("""
                    SELECT command_window_used AS value FROM im_v2.shard_admission_pools
                    WHERE lease_id=\(bind: original.lease_id) AND generation=\(bind: original.generation)
                    """).first(decoding: SingleAdmissionCount.self)
                #expect(used?.value == (counterReset ? 2 : 3))
                let txid = try #require(await gate.tailTransactionID)
                let audit = try await sql.raw("""
                    SELECT rows_changed AS value FROM im_v2.single_admission_audit
                    WHERE transaction_id=\(bind: txid) ORDER BY rows_changed
                    """).all(decoding: SingleAdmissionCount.self)
                #expect(audit.map(\.value) == (counterReset ? [0, 1] : [1]))
                let handoffs = metrics.sendOperationBatchMetricsSnapshot().ownerAdmissionHandoffs
                let selected: V2SendOperationAdmissionPath = counterReset ? .singleFallback : .singleSuccess
                #expect(handoffs[selected]?.count == 1)
                #expect(handoffs.values.reduce(0) { $0 + $1.count } == 1)
                #expect(handoffs[selected]?.resultReadyToValidatedMillisecondsTotal ?? -1 >= 0)
                #expect(handoffs[selected]?.validatedToCommitDispatchMillisecondsTotal ?? -1 >= 0)
            } catch {
                await gate.release()
                _ = await holder.result
                _ = await tail.result
                throw error
            }
        }
    }
}

private struct SingleAdmissionCount: Decodable { let value: Int64 }
private struct SingleAdmissionLease: Decodable { let lease_id: UUID; let generation: Int64 }
private actor SingleAdmissionCounterGate {
    private var holderPID: Int64?
    private var tailPID: Int64?
    private(set) var tailTransactionID: Int64?
    private var released = false
    private var readyWaiter: CheckedContinuation<Void, Never>?
    private var holderWaiter: CheckedContinuation<Void, Never>?
    var participants: (holder: Int64, tail: Int64)? {
        guard let holderPID, let tailPID else { return nil }
        return (holderPID, tailPID)
    }
    func hold(pid: Int64) async {
        holderPID = pid
        let waiter = readyWaiter; readyWaiter = nil; waiter?.resume()
        guard !released else { return }
        await withCheckedContinuation { holderWaiter = $0 }
    }
    func waitUntilReady() async {
        guard holderPID == nil, !released else { return }
        await withCheckedContinuation { readyWaiter = $0 }
    }
    func registerTail(pid: Int64, transactionID: Int64) {
        tailPID = pid; tailTransactionID = transactionID
    }
    func release() {
        released = true
        let holder = holderWaiter, ready = readyWaiter
        holderWaiter = nil; readyWaiter = nil
        holder?.resume(); ready?.resume()
    }
}
