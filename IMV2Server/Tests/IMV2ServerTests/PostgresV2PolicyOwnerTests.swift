import Foundation
import FluentKit
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("policy owner execution and recovery", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2PolicyOwnerTests {
    private let fingerprint = Data(repeating: 9, count: 32)

    @Test("current-state mutations reject an existing legacy room holder without applying facts or sealing the scope")
    func currentStateRejectsLegacyHolder() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let scope = V2PolicyAuthorizationScope.account(UUID())
            let current = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let lease = try await current.acquireOwner(scope: scope, ownerID: UUID(), durationSeconds: 30)
            try await v2SeedLegacyPolicyHolder(sql: sql, schema: schema, owner: lease)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.notDrained) {
                try await current.changeCurrentPolicy(scope: scope, ownerID: lease.ownerID,
                    durationSeconds: 30, operationKey: "current-atomic", fingerprint: fingerprint,
                    commandJSON: "{}", apply: { _, _ in
                        Issue.record("Current mutation must reject a legacy holder before applying facts")
                        return Data()
                    })
            }
            #expect(try await current.pendingChanges(scope: scope).isEmpty)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_authorization_scopes WHERE scope_key=\(bind: scope.key) AND pending_change_key IS NULL AND revision=\(bind: lease.revision)")
                .first(decoding: Count.self)?.value == 1)

        }
    }

    @Test("mutations of one scope queue in arrival order while another scope completes independently")
    func scopeMutationOrderAndIsolation() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let gate = PolicyOwnerTestGate()
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).policy_owner_order(position bigserial PRIMARY KEY, operation_key text UNIQUE)").run()
            let apply: PostgresV2PolicyOwner.Mutation = { context, change in
                if change.operationKey == "first" { await gate.hold() }
                let sql = try #require(context.transaction as? any SQLDatabase)
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).policy_owner_order(operation_key) VALUES (\(bind: change.operationKey))").run()
                return Data(change.operationKey.utf8)
            }
            let owner = PostgresV2PolicyOwner(journal: journal, scope: .account(UUID()),
                 apply: apply)
            let independent = PostgresV2PolicyOwner(journal: journal, scope: .account(UUID()),
                 apply: apply)
            let first = Task { try await owner.change(operationKey: "first", fingerprint: fingerprint, commandJSON: "{}") }
            await observe { await gate.entered }
            let second = Task { try await owner.change(operationKey: "second", fingerprint: fingerprint, commandJSON: "{}") }
            do {
                await observe { await owner.pressure().roots == 2 }
                let result = try await independent.change(operationKey: "independent", fingerprint: fingerprint, commandJSON: "{}")
                #expect(result == Data("independent".utf8))
                #expect(await owner.pressure().roots == 2)
                #expect(try await sql.raw("SELECT operation_key FROM \(unsafeRaw: schema).policy_owner_order ORDER BY position")
                    .all(decoding: OrderRow.self).map(\.operation_key) == ["independent"])
                // Cancellation of the waiting caller must not discard an
                // already admitted mutation or its retained shutdown root.
                second.cancel()
                await gate.release()
                #expect(try await first.value == Data("first".utf8))
                #expect(try await second.value == Data("second".utf8))
                #expect(try await sql.raw("SELECT operation_key FROM \(unsafeRaw: schema).policy_owner_order ORDER BY position")
                    .all(decoding: OrderRow.self).map(\.operation_key) == ["independent", "first", "second"])
                #expect(await owner.pressure().roots == 0)
                await owner.shutdown(); await independent.shutdown()
            } catch {
                await gate.release(); _ = await first.result; _ = await second.result
                await owner.shutdown(); await independent.shutdown()
                throw error
            }
        }
    }

    @Test("cancelled callers and shutdown join an actual mutation through COMMIT")
    func cancelledChangeRetainsItsRoot() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let gate = PolicyOwnerTestGate()
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).policy_owner_effects(operation_key text PRIMARY KEY)").run()
            let owner = PostgresV2PolicyOwner(journal: journal, scope: .account(UUID()),
                apply: { context, change in
                    await gate.hold()
                    let sql = try #require(context.transaction as? any SQLDatabase)
                    try await sql.raw("INSERT INTO \(unsafeRaw: schema).policy_owner_effects VALUES (\(bind: change.operationKey))").run()
                    return Data([1])
                })
            let caller = Task { try await owner.change(operationKey: "block", fingerprint: fingerprint, commandJSON: "{\"blocked\":true}") }
            await observe { await gate.entered }
            do {
                await #expect(throws: V2PolicyAuthorizationLifecycleError.identityConflict) {
                    try await owner.change(operationKey: "block", fingerprint: fingerprint, commandJSON: "{\"blocked\":false}")
                }
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_owner_effects").first(decoding: Count.self)?.value == 0)
                caller.cancel()
                let closing = Task { await owner.shutdown() }
                await observe { await owner.pressure().closed }
                #expect(await owner.pressure().roots == 1)
                await gate.release()
                #expect(try await caller.value == Data([1]))
                await closing.value
                #expect(await owner.pressure().roots == 0)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_owner_effects").first(decoding: Count.self)?.value == 1)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) { try await owner.change(operationKey: "closed", fingerprint: fingerprint, commandJSON: "{}") }
            } catch {
                await gate.release(); _ = await caller.result; await owner.shutdown()
                throw error
            }
        }
    }

    @Test("permanent results replay after another owner takes authority without reacquiring its lease")
    func replayAfterTakeover() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let scope = V2PolicyAuthorizationScope.account(UUID())
            let old = PostgresV2PolicyOwner(journal: journal, scope: scope,
                 apply: { _, _ in Data([3]) })
            #expect(try await old.change(operationKey: "setting", fingerprint: fingerprint, commandJSON: "{}") == Data([3]))
            try await sql.raw("UPDATE \(unsafeRaw: schema).policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second' WHERE scope_key=\(bind: scope.key)").run()
            _ = try await journal.acquireOwner(scope: scope, ownerID: UUID(), durationSeconds: 30)
            await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) { try await old.change(operationKey: "new-setting", fingerprint: fingerprint, commandJSON: "{}") }
            #expect(try await old.change(operationKey: "setting", fingerprint: fingerprint, commandJSON: "{}") == Data([3]))
            await #expect(throws: V2PolicyAuthorizationLifecycleError.identityConflict) {
                try await old.change(operationKey: "setting", fingerprint: fingerprint, commandJSON: "{\"different\":true}")
            }
            await old.shutdown()
        }
    }

    private func observe(_ predicate: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await predicate())
    }
    private struct Count: Decodable { let value: Int64 }
    private struct OrderRow: Decodable { let operation_key: String }
}

private actor PolicyOwnerTestGate {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
