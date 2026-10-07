@testable import IMV2ServerInfrastructure
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing

@Suite("PostgreSQL bounded activation renewal batches", .serialized)
struct PostgresV2RoomActivationRenewalBatchTests {
    @Test("129 concurrent renewals commit bounded shared transactions and drain")
    func coalescingAndDrain() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            let tokens = try await createTokens(count: 129, store: store, sql: sql, schema: schema)
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).renewal_batch_audit (transaction_id bigint NOT NULL)").run()
            try await sql.raw("""
                CREATE FUNCTION \(unsafeRaw: schema).audit_renewal_batch() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN INSERT INTO \(unsafeRaw: schema).renewal_batch_audit VALUES (txid_current()); RETURN NEW; END; $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER audit_renewal_batch AFTER UPDATE ON \(unsafeRaw: schema).room_activation_leases
                FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: schema).audit_renewal_batch()
                """).run()
            let gate = RenewalTestGate()
            let duration = try V2ActorMilliseconds(20_000)
            let jobs = tokens.map { token in Task {
                await gate.wait()
                return try await store.renew(token: token, duration: duration)
            } }
            await gate.open()
            for (token, job) in zip(tokens, jobs) { #expect(try await job.value.token == token) }
            let audit = try #require(try await sql.raw("""
                SELECT count(*) AS batches, sum(size)::bigint AS total, max(size) AS largest
                FROM (SELECT count(*) AS size FROM \(unsafeRaw: schema).renewal_batch_audit GROUP BY transaction_id) batches
                """).first(decoding: RenewalAudit.self))
            #expect(audit.total == 129)
            #expect(audit.batches >= 2 && audit.batches < 129)
            #expect(audit.largest <= 128)
            await store.shutdownRenewals()
            await store.shutdownRenewals()
            var closed = false
            do { _ = try await store.renew(token: tokens[0], duration: duration) }
            catch { closed = true }
            #expect(closed)
        }
    }

    @Test("expired, owner changed and wrong incarnation do not abort valid siblings")
    func independentFences() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            let tokens = try await createTokens(count: 6, store: store, sql: sql, schema: schema)
            let past = Date().addingTimeInterval(-1)
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET expires_at = \(bind: past) WHERE room_id = \(bind: tokens[0].roomID.uuidValue!)").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch = 1 WHERE room_id = \(bind: tokens[1].roomID.uuidValue!)").run()
            let wrong = V2RoomActivationToken(roomID: tokens[3].roomID, owner: tokens[3].owner,
                activationEpoch: tokens[3].activationEpoch,
                host: .init(hostID: tokens[3].host.hostID, incarnationID: UUID()))
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id = \(bind: tokens[4].roomID.uuidValue!)").run()
            let wrongEpoch = V2RoomActivationToken(roomID: tokens[5].roomID, owner: tokens[5].owner,
                activationEpoch: try .init(tokens[5].activationEpoch.rawValue + 1), host: tokens[5].host)
            let malformed = V2RoomActivationToken(roomID: try RoomID("non-uuid-room"), owner: tokens[0].owner,
                activationEpoch: tokens[0].activationEpoch, host: tokens[0].host)
            let batcher = V2RoomActivationRenewalBatcher(database: database, schema: schema, timeouts: .default)
            let submitted = [tokens[0], tokens[1], wrong, tokens[4], wrongEpoch, tokens[3], tokens[5], tokens[5], malformed]
            let expected: [V2RoomActivationLeaseError] = [.leaseExpired, .ownerChanged, .activationChanged, .activationChanged, .activationChanged]
            let duration = try V2ActorMilliseconds(20_000)
            // Exercise the defensive internal all-invalid branch, and preserve
            // the public adapter's original typed invalid-identifier mapping.
            await #expect(throws: V2CoreError.invalidIdentifier) {
                _ = try await batcher.renew(token: malformed, duration: duration)
            }
            await #expect(throws: V2CoreError.invalidIdentifier) {
                _ = try await store.renew(token: malformed, duration: duration)
            }
            let gate = RenewalTestGate()
            let jobs = submitted.enumerated().map { index, token in Task { () -> Result<V2RoomActivationLease, any Error> in
                await gate.wait()
                do { return .success(try await batcher.renew(token: token, duration: index == 7 ? .init(30_000) : duration)) }
                catch { return .failure(error) }
            } }
            try await gate.waitForEntries(submitted.count)
            await gate.open()
            for index in 0..<5 {
                switch await jobs[index].value {
                case .failure(let error): #expect((error as? V2RoomActivationLeaseError) == expected[index])
                case .success: Issue.record("invalid fence renewed")
                }
            }
            let valid = try await jobs[5].value.get()
            switch await jobs[8].value {
            case .failure(let error): #expect((error as? V2CoreError) == .invalidIdentifier)
            case .success: Issue.record("non-UUID room renewed")
            }
            let shorter = try await jobs[6].value.get()
            let longer = try await jobs[7].value.get()
            // Same exact token shares the max valid duration in one SQL batch;
            // an invalid sibling must not poison either valid request.
            #expect(shorter.token == tokens[5] && longer.token == tokens[5])
            #expect(shorter.databaseObservedAt == longer.databaseObservedAt)
            #expect(shorter.expiresAt == longer.expiresAt)
            #expect(longer.expiresAt.timeIntervalSince(longer.databaseObservedAt) >= 29.9)
            #expect(valid.token == tokens[3])
            #expect(valid.expiresAt.timeIntervalSince(valid.databaseObservedAt) >= 19.9)
            let expired = try #require(try await sql.raw("SELECT expires_at FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id = \(bind: tokens[0].roomID.uuidValue!)").first(decoding: RenewalExpiry.self))
            #expect(expired.expiresAt < valid.databaseObservedAt)
            #expect(try await store.locate(roomID: tokens[3].roomID, owner: tokens[3].owner)?.token == tokens[3])
            await store.shutdownRenewals()
            await batcher.shutdown()
        }
    }

    @Test("renewal lock wait observes fresh expiry or returns only confirmed rollback as deferred", arguments: [false, true])
    func blockedRenewalCannotReviveExpiredLease(confirmedRollback: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let store = PostgresV2RoomActivationStore(database: database, schema: schema,
                timeouts: try .init(lockMilliseconds: confirmedRollback ? 200 : 2_000))
            let token = try #require(try await createTokens(count: 1, store: store, sql: sql, schema: schema).first)
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET expires_at=clock_timestamp()+(\(bind: confirmedRollback ? 10_000 : 800)::integer * interval '1 millisecond') WHERE room_id=\(bind: token.roomID.uuidValue!)").run()
            let gate = RenewalRoomLockGate()
            let deadline = ContinuousClock.now + .seconds(5)
            let holder = Task {
                try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await v2WithRoomScopedTransaction(database: database) { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: RenewalCount.self))
                        _ = try await connection.raw("SELECT room_id FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id=\(bind: token.roomID.uuidValue!) FOR NO KEY UPDATE").all()
                        await gate.hold(pid: pid.value)
                    }
                }
            }
            var renewal: Task<V2RoomActivationLease, any Error>?
            do {
                let pid = try await gate.waitUntilHeld(deadline: deadline)
                renewal = Task { try await store.renew(token: token, duration: try .init(20_000)) }
                var observedLock = false
                var observedBeforeExpiry = false
                var observedExpiry = false
                while ContinuousClock.now < deadline {
                    let state = try #require(try await sql.raw("""
                        SELECT EXISTS (
                            SELECT 1 FROM pg_stat_activity
                            WHERE datname=current_database() AND state='active' AND wait_event_type='Lock'
                              AND \(bind: pid)::int=ANY(pg_blocking_pids(pid))
                              AND query LIKE \(bind: "%" + schema + "%")
                        ) AS blocked,
                        (SELECT clock_timestamp()>=expires_at FROM \(unsafeRaw: schema).room_activation_leases
                         WHERE room_id=\(bind: token.roomID.uuidValue!)) AS expired
                        """).first(decoding: RenewalBlockedState.self))
                    observedLock = observedLock || state.blocked
                    observedBeforeExpiry = observedBeforeExpiry || (state.blocked && !state.expired)
                    observedExpiry = state.expired
                    if observedLock && (confirmedRollback || observedExpiry) { break }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let result = try #require(renewal)
                if confirmedRollback {
                    // Keep the real lock holder until PostgreSQL lock_timeout
                    // aborts and the wrapper has actually confirmed ROLLBACK.
                    await #expect(throws: V2RoomActivationLeaseError.renewalDeferred) { _ = try await result.value }
                    await gate.release()
                    try await holder.value
                    try #require(observedLock)
                    try #require(observedBeforeExpiry)
                    let recovered = try await store.renew(token: token, duration: try .init(20_000))
                    #expect(recovered.token == token)
                    await store.shutdownRenewals()
                    return
                }
                await gate.release()
                try await holder.value
                await #expect(throws: V2RoomActivationLeaseError.leaseExpired) { _ = try await result.value }
                try #require(observedLock, "renewal must really wait behind the owned lease transaction")
                try #require(observedBeforeExpiry, "the actual lock wait must begin while the lease is still valid")
                try #require(observedExpiry, "database clock must exceed expiry before releasing the blocker")
                let expiry = try #require(try await sql.raw("SELECT expires_at FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id=\(bind: token.roomID.uuidValue!)").first(decoding: RenewalExpiry.self))
                let state = try #require(try await sql.raw("SELECT clock_timestamp()>=expires_at AS expired, false AS blocked FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id=\(bind: token.roomID.uuidValue!)").first(decoding: RenewalBlockedState.self))
                #expect(state.expired)
                #expect(expiry.expiresAt.timeIntervalSince1970 > 0)
                await store.shutdownRenewals()
            } catch {
                await gate.release()
                _ = await holder.result
                if let renewal { _ = await renewal.result }
                await store.shutdownRenewals()
                throw error
            }
        }
    }

    @Test("renewal waiting on a lease lock preserves the predecessor's newly extended expiry")
    func lockedExpiryExtensionIsObservedAfterWaiting() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            let token = try #require(try await createTokens(count: 1, store: store, sql: sql, schema: schema).first)
            let gate = RenewalRoomLockGate()
            let deadline = ContinuousClock.now + .seconds(5)
            let holder: Task<Date, any Error> = Task {
                try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await v2WithRoomScopedTransaction(database: database) { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: RenewalCount.self))
                        _ = try await connection.raw("SELECT room_id FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id=\(bind: token.roomID.uuidValue!) FOR NO KEY UPDATE").all()
                        await gate.hold(pid: pid.value)
                        // Update only after the actual renewal statement has
                        // taken its snapshot and joined the lock wait queue.
                        let extended = try #require(try await connection.raw("""
                            UPDATE \(unsafeRaw: schema).room_activation_leases
                            SET expires_at=clock_timestamp()+interval '60 seconds'
                            WHERE room_id=\(bind: token.roomID.uuidValue!) RETURNING expires_at
                            """).first(decoding: RenewalExpiry.self))
                        return extended.expiresAt
                    }
                }
            }
            var renewal: Task<V2RoomActivationLease, any Error>?
            do {
                let holderPID = try await gate.waitUntilHeld(deadline: deadline)
                renewal = Task { try await store.renew(token: token, duration: try .init(20_000)) }
                var observedWait = false
                while ContinuousClock.now < deadline {
                    let waiting = try #require(try await sql.raw("""
                        SELECT count(*)::bigint AS value FROM pg_stat_activity
                        WHERE datname=current_database() AND state='active' AND wait_event_type='Lock'
                          AND \(bind: holderPID)::int=ANY(pg_blocking_pids(pid))
                          AND query LIKE \(bind: "%" + schema + "%")
                        """).first(decoding: RenewalCount.self))
                    if waiting.value > 0 { observedWait = true; break }
                    try await Task.sleep(for: .milliseconds(2))
                }
                await gate.release()
                let committedExpiry = try await holder.value
                let renewalTask = try #require(renewal)
                let renewed = try await renewalTask.value
                try #require(observedWait, "renewal must actually wait before the predecessor extends expiry")
                #expect(renewed.token == token)
                // The predecessor's 60s expiry dominates this request's 20s.
                #expect(renewed.expiresAt == committedExpiry)
                let stored = try #require(try await sql.raw("SELECT expires_at FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id=\(bind: token.roomID.uuidValue!)").first(decoding: RenewalExpiry.self))
                #expect(stored.expiresAt == committedExpiry)
                await store.shutdownRenewals()
            } catch {
                await gate.release()
                _ = await holder.result
                if let renewal { _ = await renewal.result }
                await store.shutdownRenewals()
                throw error
            }
        }
    }

    private func createTokens(count: Int, store: PostgresV2RoomActivationStore,
                              sql: any SQLDatabase, schema: String) async throws -> [V2RoomActivationToken] {
        let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
        let host = V2ActorHostIdentity(hostID: try V2ActorHostID("renewal-batch-host"), incarnationID: UUID())
        let duration = try V2ActorMilliseconds(10_000)
        var tokens: [V2RoomActivationToken] = []
        for _ in 0..<count {
            let room = try RoomID(UUID().uuidString)
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms (room_id,room_shard_id,capacity_profile_id) VALUES (\(bind: room.uuidValue!), 'owner-a', 'standard')").run()
            guard case .acquired(let lease) = try await store.acquire(roomID: room, owner: owner, host: host, duration: duration) else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            tokens.append(lease.token)
        }
        return tokens
    }
}

private actor RenewalTestGate {
    private var entries = 0
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entries += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitForEntries(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while entries < count {
            guard ContinuousClock.now < deadline else { throw V2RoomActivationLeaseError.outcomeUnknown }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
private struct RenewalAudit: Decodable { let batches: Int64; let total: Int64; let largest: Int64 }
private struct RenewalExpiry: Decodable {
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
}

private struct RenewalCount: Decodable { let value: Int64 }
private struct RenewalBlockedState: Decodable { let blocked: Bool; let expired: Bool }
private actor RenewalRoomLockGate {
    private var pid: Int64?
    private let releaseGate = RenewalTestGate()
    func hold(pid: Int64) async {
        self.pid = pid
        await releaseGate.wait()
    }
    func release() async { await releaseGate.open() }
    func waitUntilHeld(deadline: ContinuousClock.Instant) async throws -> Int64 {
        if let value = pid { return value }
        while ContinuousClock.now < deadline {
            if let value = pid { return value }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw V2RoomActivationLeaseError.outcomeUnknown
    }
}
