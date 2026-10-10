import Foundation
import FluentKit
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("durable policy ownership and atomic changes", .serialized, .timeLimit(.minutes(2)))
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

    @Test("publication failure rolls back domain facts and the operation, then permits retry")
    func commitRollbackIsAtomic() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let owner = try await journal.acquireOwner(scope: .account(UUID()), ownerID: UUID(), durationSeconds: 30)
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).policy_test_fact(value boolean NOT NULL)").run()
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).policy_authorization_outbox ADD CONSTRAINT reject_test_publication CHECK (revision < 2)").run()
            await #expect(throws: (any Error).self) {
                try await journal.changeCurrentPolicy(scope: owner.scope, ownerID: owner.ownerID,
                    durationSeconds: 30, operationKey: "setting-1", fingerprint: fingerprint,
                    commandJSON: "{\"strangers\":false}", apply: { context, _ in
                    let sql = try #require(context.transaction as? any SQLDatabase)
                    try await sql.raw("INSERT INTO \(unsafeRaw: schema).policy_test_fact VALUES (true)").run()
                    return Data([1])
                })
            }
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_test_fact").first(decoding: Count.self)?.value == 0)
            #expect(try await journal.pendingChanges().isEmpty)
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).policy_authorization_outbox DROP CONSTRAINT reject_test_publication").run()
            #expect(try await journal.changeCurrentPolicy(scope: owner.scope, ownerID: owner.ownerID,
                durationSeconds: 30, operationKey: "setting-1", fingerprint: fingerprint,
                commandJSON: "{\"strangers\":false}", apply: { _, _ in Data([2]) }).receipt == Data([2]))
        }
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
