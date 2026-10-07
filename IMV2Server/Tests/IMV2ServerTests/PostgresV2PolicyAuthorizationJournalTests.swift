import Foundation
import FluentKit
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("durable policy registration and revocation", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2PolicyAuthorizationJournalTests {
    private let fingerprint = Data(repeating: 7, count: 32)

    @Test("owner acquisition samples expiry after its actual scope lock wait", arguments: [false, true])
    func ownerClaimClockAfterLock(changeOwner: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let scope = V2PolicyAuthorizationScope.account(UUID()), ownerID = UUID()
            let before = try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: 0.5)
            let requestedID = changeOwner ? UUID() : ownerID, gate = PolicyClaimRevisionGate()
            let blocker = Task {
                try await database.transaction { transaction in
                    let connection = try #require(transaction as? any SQLDatabase)
                    _ = try await connection.raw("SELECT scope_key FROM \(unsafeRaw: schema).policy_authorization_scopes WHERE scope_key=\(bind: scope.key) FOR UPDATE").all()
                    let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                    await gate.waitToUpdate(pid: pid)
                    try await connection.raw("UPDATE \(unsafeRaw: schema).policy_authorization_scopes SET revision=revision+1 WHERE scope_key=\(bind: scope.key)").run()
                    await gate.holdUpdatedRevision()
                }
            }
            var claiming: Task<V2PolicyOwnerLease, any Error>?
            do {
                let deadline = ContinuousClock.now + .seconds(8)
                while await gate.pid == nil {
                    guard .now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pid = try #require(await gate.pid)
                let claim = Task { try await journal.acquireOwner(scope: scope, ownerID: requestedID, durationSeconds: 30) }
                claiming = claim
                // Observe the combined statement itself waiting, rather than
                // assuming the preceding insert has reached the lock boundary.
                while try await sql.raw("""
                    SELECT count(*)::bigint AS value FROM pg_stat_activity
                    WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))
                        AND query LIKE '%WITH locked AS MATERIALIZED%'
                    """).first(decoding: Count.self)?.value ?? 0 == 0 {
                    guard .now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                await gate.requestRevisionUpdate()
                while !(await gate.revisionUpdated) {
                    guard .now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                while try await sql.raw("SELECT CASE WHEN clock_timestamp()>=\(bind: before.validUntil) THEN 1 ELSE 0 END::bigint AS value")
                    .first(decoding: Count.self)?.value ?? 0 == 0 {
                    guard .now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                await gate.release(); try await blocker.value
                let acquired = try await claim.value
                #expect(acquired.ownerID == requestedID && acquired.epoch == before.epoch + 1)
                // The statement started before the blocking transaction
                // committed. Its locked tuple must include that new revision.
                #expect(acquired.revision == before.revision + 1)
                #expect(try await sql.raw("""
                    SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_authorization_scopes
                    WHERE scope_key=\(bind: scope.key) AND owner_id=\(bind: requestedID)
                        AND owner_epoch=\(bind: acquired.epoch) AND owner_valid_until>clock_timestamp()
                    """).first(decoding: Count.self)?.value == 1)
            } catch {
                await gate.release(); _ = await blocker.result; _ = await claiming?.result
                throw error
            }
        }
    }

    @Test("the maximum epoch can renew but cannot overflow on expiry or takeover")
    func ownerClaimEpochLimit() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let scope = V2PolicyAuthorizationScope.account(UUID()), ownerID = UUID()
            _ = try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: 30)
            try await sql.raw("UPDATE \(unsafeRaw: schema).policy_authorization_scopes SET owner_epoch=\(bind: Int64.max) WHERE scope_key=\(bind: scope.key)").run()
            #expect(try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: 30).epoch == Int64.max)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                try await journal.acquireOwner(scope: scope, ownerID: UUID(), durationSeconds: 30)
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second' WHERE scope_key=\(bind: scope.key)").run()
            for requestedID in [ownerID, UUID()] {
                await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidRequest) {
                    try await journal.acquireOwner(scope: scope, ownerID: requestedID, durationSeconds: 30)
                }
            }
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_authorization_scopes
                WHERE scope_key=\(bind: scope.key) AND owner_id=\(bind: ownerID) AND owner_epoch=\(bind: Int64.max)
                """).first(decoding: Count.self)?.value == 1)
        }
    }

    @Test("set registration samples ownership expiry after all scope locks", arguments: [false, true])
    func registrationScopeClockAfterAllLocks(expireBlockedOwner: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let ownerID = UUID()
            let first = try await journal.acquireOwner(scope: .account(UUID()), ownerID: ownerID,
                durationSeconds: expireBlockedOwner ? 30 : 0.5)
            let last = try await journal.acquireOwner(scope: .stranger(UUID()), ownerID: ownerID,
                durationSeconds: expireBlockedOwner ? 0.5 : 30)
            let expiry = expireBlockedOwner ? last.validUntil : first.validUntil
            let registrationID = UUID(), gate = PolicyJournalTransactionGate()
            let blocker = Task {
                try await database.transaction { transaction in
                    let connection = try #require(transaction as? any SQLDatabase)
                    _ = try await connection.raw("SELECT scope_key FROM \(unsafeRaw: schema).policy_authorization_scopes WHERE scope_key=\(bind: last.scope.key) FOR UPDATE").all()
                    let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var registration: Task<V2PolicyAuthorizationHolder, any Error>?
            do {
                let deadline = ContinuousClock.now + .seconds(8)
                while await gate.pid == nil {
                    guard ContinuousClock.now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pid = try #require(await gate.pid)
                let task = Task {
                    try await journal.register(owners: [last, first], registrationID: registrationID,
                        roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-a", durationSeconds: 20)
                }
                registration = task
                while try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))")
                    .first(decoding: Count.self)?.value ?? 0 == 0 {
                    guard ContinuousClock.now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                while try await sql.raw("SELECT CASE WHEN clock_timestamp()>=\(bind: expiry) THEN 1 ELSE 0 END::bigint AS value")
                    .first(decoding: Count.self)?.value ?? 0 == 0 {
                    guard ContinuousClock.now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                await gate.release(); try await blocker.value
                await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) { try await task.value }
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_authorization_holders WHERE registration_id=\(bind: registrationID)")
                    .first(decoding: Count.self)?.value == 0)
            } catch {
                await gate.release(); _ = await blocker.result; _ = await registration?.result
                throw error
            }
        }
    }

    @Test("seal freezes holders, excludes new registrations, and commits facts with the permanent result")
    func sealAndCommit() async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let sender = UUID(), recipient = UUID(), ownerID = UUID()
            let scopes: [V2PolicyAuthorizationScope] = [.account(sender), .account(recipient), .pair(sender, recipient)]
            var owners: [V2PolicyOwnerLease] = []
            for scope in scopes { owners.append(try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: 30)) }
            let holder = try await journal.register(owners: owners, registrationID: UUID(), roomID: UUID(),
                activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-owner-a", durationSeconds: 20)
            #expect(try await journal.register(owners: owners, registrationID: holder.registrationID,
                roomID: holder.roomID, activationID: holder.activationID, roomOwnerEpoch: holder.roomOwnerEpoch,
                endpoint: holder.endpoint, durationSeconds: 20) == holder)
            let change = try await journal.beginChange(owner: owners[2], operationKey: "block-1",
                fingerprint: fingerprint, commandJSON: "{\"blocked\":true}")
            #expect(change.expectedRevision == 1 && change.nextRevision == 2 && !change.committed)
            #expect(try await journal.targets(operationKey: "block-1") == [holder])
            await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                try await journal.register(owners: owners, registrationID: UUID(), roomID: UUID(),
                    activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-owner-b", durationSeconds: 20)
            }
            await #expect(throws: V2PolicyAuthorizationLifecycleError.notDrained) {
                try await journal.commitChange(owner: owners[2], operationKey: "block-1") { _, _ in
                    Issue.record("Domain mutation ran before actual revocation"); return Data()
                }
            }
            // Reconstruct adapters to demonstrate recovery from durable state.
            let restarted = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            #expect(try await restarted.pendingChanges() == [change])
            let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
            let proof = try await fence.revoke(holder)
            try await restarted.acknowledge(operationKey: "block-1", proof: proof)
            try await restarted.acknowledge(operationKey: "block-1", proof: proof)
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).policy_test_fact(value boolean NOT NULL)").run()
            let receipt = Data([1, 2, 3])
            #expect(try await restarted.commitChange(owner: owners[2], operationKey: "block-1") { transaction, _ in
                let sql = try #require(transaction as? any SQLDatabase)
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).policy_test_fact VALUES (true)").run()
                return receipt
            } == receipt)
            #expect(try await restarted.commitChange(owner: owners[2], operationKey: "block-1") { _, _ in
                Issue.record("Replay executed domain mutation twice"); return Data()
            } == receipt)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_test_fact").first(decoding: Count.self)?.value == 1)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_authorization_outbox WHERE revision=2 AND published_at IS NULL").first(decoding: Count.self)?.value == 1)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) {
                try await restarted.register(owners: owners, registrationID: UUID(), roomID: UUID(),
                    activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-owner-a", durationSeconds: 20)
            }
        }
    }

    @Test("revocation tombstones survive reordering and reject changed lease identities")
    func revokeBeforeInstall() async throws {
        try await withUserEventDatabase { database, _, schema in
            let holder = self.holder()
            let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
            try await fence.revoke(holder)
            let restarted = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
            try await restarted.revoke(holder)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await restarted.install(holder) }
            await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) {
                try await database.transaction { transaction in try await restarted.requireActive(holder, transaction: transaction) }
            }
            let changed = V2PolicyAuthorizationHolder(registrationID: holder.registrationID,
                roomID: holder.roomID, activationID: UUID(), roomOwnerEpoch: 2,
                generation: holder.generation + 1, endpoint: holder.endpoint, validUntil: holder.validUntil)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.identityConflict) { try await restarted.install(changed) }
        }
    }

    @Test("pending changes survive owner takeover while an expired owner cannot commit")
    func takeoverAndRecovery() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let scope = V2PolicyAuthorizationScope.account(UUID())
            let old = try await journal.acquireOwner(scope: scope, ownerID: UUID(), durationSeconds: 30)
            let change = try await journal.beginChange(owner: old, operationKey: "suspend-1",
                fingerprint: fingerprint, commandJSON: "{\"active\":false}")
            await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                try await journal.acquireOwner(scope: scope, ownerID: UUID(), durationSeconds: 30)
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second' WHERE scope_key=\(bind:scope.key)").run()
            let successor = try await journal.acquireOwner(scope: scope, ownerID: UUID(), durationSeconds: 30)
            #expect(successor.epoch == old.epoch + 1)
            #expect(try await journal.beginChange(owner: successor, operationKey: "suspend-1",
                fingerprint: fingerprint, commandJSON: "{ \"active\": false }") == change)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                try await journal.commitChange(owner: old, operationKey: "suspend-1") { _, _ in Data([0]) }
            }
            #expect(try await journal.commitChange(owner: successor, operationKey: "suspend-1") { _, _ in Data([1]) } == Data([1]))
            // Permanent result replay precedes current owner authority.
            #expect(try await journal.beginChange(owner: old, operationKey: "suspend-1",
                fingerprint: fingerprint, commandJSON: "{\"active\":false}").committed)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.identityConflict) {
                try await journal.beginChange(owner: successor, operationKey: "suspend-1",
                    fingerprint: fingerprint, commandJSON: "{\"active\":true}")
            }
        }
    }

    @Test("publication failure rolls back domain changes without losing the revocation obligation")
    func commitRollbackIsAtomic() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let owner = try await journal.acquireOwner(scope: .account(UUID()), ownerID: UUID(), durationSeconds: 30)
            _ = try await journal.beginChange(owner: owner, operationKey: "setting-1",
                fingerprint: fingerprint, commandJSON: "{\"strangers\":false}")
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).policy_test_fact(value boolean NOT NULL)").run()
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).policy_authorization_outbox ADD CONSTRAINT reject_test_publication CHECK (revision < 2)").run()
            await #expect(throws: (any Error).self) {
                try await journal.commitChange(owner: owner, operationKey: "setting-1") { transaction, _ in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("INSERT INTO \(unsafeRaw: schema).policy_test_fact VALUES (true)").run()
                    return Data([1])
                }
            }
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_test_fact").first(decoding: Count.self)?.value == 0)
            #expect(try await journal.pendingChanges().count == 1)
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).policy_authorization_outbox DROP CONSTRAINT reject_test_publication").run()
            #expect(try await journal.commitChange(owner: owner, operationKey: "setting-1") { _, _ in Data([2]) } == Data([2]))
        }
    }

    @Test("durable revocation waits for the physical transaction even after caller cancellation")
    func revocationWaitsForPostgresTransaction() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let holder = self.holder()
            let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
            try await fence.install(holder)
            let peer = self.holder()
            try await fence.install(peer)
            let gate = PolicyJournalTransactionGate()
            let submitted = Task {
                try await database.transaction { transaction in
                    try await fence.requireActive([peer, holder, peer], transaction: transaction)
                    let sql = try #require(transaction as? any SQLDatabase)
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                    await gate.hold(pid: pid)
                }
            }
            let entryDeadline = ContinuousClock.now + .seconds(5)
            while await gate.pid == nil, ContinuousClock.now < entryDeadline { await Task.yield() }
            guard let pid = await gate.pid else {
                await gate.release(); _ = await submitted.result
                throw V2PolicyAuthorizationLifecycleError.corruptPersistence
            }
            let revoke = Task { try await fence.revoke(holder) }
            do {
                var blockers: Int64 = 0
                let deadline = ContinuousClock.now + .seconds(5)
                repeat {
                    blockers = try await sql.raw("""
                        SELECT count(*)::bigint AS value FROM pg_stat_activity
                        WHERE \(bind: pid)::integer = ANY(pg_blocking_pids(pid))
                        """).first(decoding: Count.self)?.value ?? 0
                    if blockers > 0 { break }
                    await Task.yield()
                } while ContinuousClock.now < deadline
                #expect(blockers > 0)
                submitted.cancel()
                #expect(try await sql.raw("""
                    SELECT count(*)::bigint AS value FROM pg_stat_activity
                    WHERE \(bind: pid)::integer = ANY(pg_blocking_pids(pid))
                    """).first(decoding: Count.self)?.value ?? 0 > 0)
                await gate.release()
                _ = await submitted.result
                try await revoke.value
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await fence.install(holder) }
            } catch {
                await gate.release(); _ = await submitted.result; _ = await revoke.result
                throw error
            }
        }
    }

    @Test("a batch lease check rejects one revoked or substituted holder while an independent holder remains valid")
    func batchLeaseAuthority() async throws {
        try await withUserEventDatabase { database, _, schema in
            let first = self.holder(), second = self.holder()
            let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
            try await fence.install(first); try await fence.install(second)
            let substituted = V2PolicyAuthorizationHolder(registrationID: second.registrationID,
                roomID: UUID(), activationID: second.activationID, roomOwnerEpoch: second.roomOwnerEpoch,
                generation: second.generation, endpoint: second.endpoint, validUntil: second.validUntil)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.identityConflict) {
                try await database.transaction { transaction in
                    try await fence.requireActive([first, substituted], transaction: transaction)
                }
            }
            await #expect(throws: V2PolicyAuthorizationLifecycleError.identityConflict) {
                try await database.transaction { transaction in
                    try await fence.requireActive([second, substituted], transaction: transaction)
                }
            }
            try await fence.revoke(second)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) {
                try await database.transaction { transaction in
                    try await fence.requireActive([first, second], transaction: transaction)
                }
            }
            try await database.transaction { transaction in
                try await fence.requireActive(first, transaction: transaction)
            }
            await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) {
                try await database.transaction { transaction in
                    try await fence.requireActive([first, self.holder()], transaction: transaction)
                }
            }
        }
    }

    @Test("the single-query lease clock is sampled after the last holder lock", arguments: [false, true])
    func leaseClockAfterAllLocks(expireBlockedHolder: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let expiry = Date().addingTimeInterval(2)
            let first = V2PolicyAuthorizationHolder(registrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1, generation: 1, endpoint: "room-owner-a",
                validUntil: expireBlockedHolder ? Date().addingTimeInterval(30) : expiry)
            let last = V2PolicyAuthorizationHolder(registrationID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
                roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1, generation: 1, endpoint: "room-owner-a",
                validUntil: expireBlockedHolder ? expiry : Date().addingTimeInterval(30))
            let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
            try await fence.install(first); try await fence.install(last)
            let gate = PolicyJournalTransactionGate()
            let blocker = Task {
                try await database.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    _ = try await sql.raw("SELECT registration_id FROM \(unsafeRaw: schema).room_policy_authorization_leases WHERE registration_id=\(bind: last.registrationID) FOR UPDATE").all()
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var check: Task<Void, any Error>?
            do {
                let deadline = ContinuousClock.now + .seconds(10)
                while await gate.pid == nil {
                    guard ContinuousClock.now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pid = try #require(await gate.pid)
                let task = Task { try await database.transaction { transaction in
                    try await fence.requireActive([last, first, first], transaction: transaction)
                } }
                check = task
                while try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))")
                    .first(decoding: Count.self)?.value ?? 0 == 0 {
                    guard ContinuousClock.now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                // Database time, rather than a fixed sleep, proves that the
                // early row or the blocked row expired while this SQL waited.
                while try await sql.raw("SELECT CASE WHEN clock_timestamp()>=\(bind: expiry) THEN 1 ELSE 0 END::bigint AS value")
                    .first(decoding: Count.self)?.value ?? 0 == 0 {
                    guard ContinuousClock.now < deadline else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    try await Task.sleep(for: .milliseconds(10))
                }
                await gate.release(); try await blocker.value
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await task.value }
            } catch {
                await gate.release(); _ = await blocker.result; _ = await check?.result
                throw error
            }
        }
    }

    private func holder() -> V2PolicyAuthorizationHolder {
        .init(registrationID: UUID(), roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1,
              generation: 1, endpoint: "room-owner-a", validUntil: Date().addingTimeInterval(30))
    }
    private struct Count: Decodable { let value: Int64 }
}

private actor PolicyClaimRevisionGate {
    private(set) var pid: Int64?
    private(set) var revisionUpdated = false
    private var updateRequested = false
    private var released = false
    private var updateWaiter: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    func waitToUpdate(pid: Int64) async {
        self.pid = pid
        guard !released, !updateRequested else { return }
        await withCheckedContinuation { updateWaiter = $0 }
    }
    func requestRevisionUpdate() { updateRequested = true; updateWaiter?.resume(); updateWaiter = nil }
    func holdUpdatedRevision() async {
        revisionUpdated = true
        guard !released else { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }
    func release() {
        released = true
        updateWaiter?.resume(); updateWaiter = nil
        heldWaiter?.resume(); heldWaiter = nil
    }
}

private actor PolicyJournalTransactionGate {
    private(set) var pid: Int64?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(pid: Int64) async {
        self.pid = pid
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true; continuation?.resume(); continuation = nil
    }
}
