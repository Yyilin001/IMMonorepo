import Foundation
import FluentKit
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("bounded policy owner directory", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2PolicyOwnerDirectoryTests {
    @Test("compact fact retention obeys its byte budget independently of actor capacity", arguments: [false, true])
    func retainedFactBudget(usesCurrentState: Bool) async throws {
        try await withUserEventDatabase { database, _, schema in
            let metrics = V2SendOperationBatchMetrics()
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema,
                stateMetrics: metrics, roomDrainRequired: !usesCurrentState)
            let directory = makeDirectory(database: database, journal: journal, maximumRoots: 2,
                maximumRetainedStates: 8, maximumRetainedStateBytes: 350, memoryMetrics: metrics)
            let scopes = (0..<3).map { _ in V2PolicyAuthorizationScope.stranger(UUID()) }
            for scope in scopes { _ = try await directory.registrationStates(scopes: [scope]) }
            #expect(await directory.pressure().owners == 1)
            #expect(await directory.pressure().retainedStates == 1)
            #expect(await directory.pressure().retainedBytes <= 350)
            #expect(metrics.sendOperationBatchMetricsSnapshot().policyMemoryEvents[.factsEvicted] == 1)
            #expect(try await directory.cachedRegistrationStates(scopes: [scopes[0]]) == nil)
            let reads = metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count ?? 0
            // Restore the requested dormant owner at a completely full fact
            // budget. Retaining the old object must not evict the request.
            _ = try await directory.registrationOwners(scopes: [scopes[1]])
            _ = try await directory.registrationStates(scopes: [scopes[1]])
            #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count == reads)
            _ = try await directory.registrationStates(scopes: [scopes[0]])
            #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.policyOwnerStateFacts]?.count == reads + 1)
            await directory.shutdown()
        }
    }

    @Test("valid memory states remain readable when unrelated SQL consumes every directory root", arguments: [false, true])
    func cachedStatesBypassBusyRoots(usesCurrentState: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let metrics = V2SendOperationBatchMetrics()
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema,
                stateMetrics: metrics, roomDrainRequired: !usesCurrentState)
            let ownerID = UUID(), warmUser = UUID()
            let warm = V2PolicyAuthorizationScope.account(warmUser), cold = V2PolicyAuthorizationScope.account(UUID())
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).public_user_profiles
                (user_id,public_handle,display_name,created_at,updated_at)
                VALUES (\(bind: warmUser),'directory_warm_user','Warm',clock_timestamp(),clock_timestamp())
                """).run()
            let directory = makeDirectory(database: database, journal: journal, maximumRoots: 1,
                ownerID: ownerID, maximumOwners: 2)
            let before = try #require(try await directory.registrationStates(scopes: [warm]).first)
            _ = try await journal.acquireOwner(scope: cold, ownerID: ownerID, durationSeconds: 30)
            let gate = DirectoryTransactionGate()
            let blocking = Task {
                try await database.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    _ = try await sql.raw("SELECT scope_key FROM \(unsafeRaw: schema).policy_authorization_scopes WHERE scope_key=\(bind: cold.key) FOR UPDATE").all()
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                    await gate.hold(pid: pid)
                }
            }
            let enteredDeadline = ContinuousClock.now + .seconds(5)
            while await gate.pid == nil, ContinuousClock.now < enteredDeadline { await Task.yield() }
            guard let pid = await gate.pid else {
                await gate.release(); _ = await blocking.result; await directory.shutdown()
                throw V2PolicyAuthorizationLifecycleError.corruptPersistence
            }
            let coldClaim = Task { try await directory.registrationOwners(scopes: [cold]) }
            do {
                var blocked: Int64 = 0
                let deadline = ContinuousClock.now + .seconds(5)
                repeat {
                    blocked = try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer = ANY(pg_blocking_pids(pid))").first(decoding: Count.self)?.value ?? 0
                    if blocked > 0 { break }
                    await Task.yield()
                } while ContinuousClock.now < deadline
                try #require(blocked > 0)
                #expect(await directory.pressure().roots == 1)
                let after = try #require(try await directory.registrationStates(scopes: [warm]).first)
                #expect(after.owner == before.owner && after.facts == before.facts && after.deadline == before.deadline)
                let stages = metrics.sendOperationBatchMetricsSnapshot().stages
                #expect(stages[.policyOwnerStateTransaction]?.count == 1)
                #expect(stages[.policyOwnerStateFacts]?.count == 1)
                #expect(await directory.pressure().roots == 1)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                    try await directory.registrationStates(scopes: [.account(UUID())])
                }
                await gate.release()
                try await blocking.value
                _ = try await coldClaim.value
                #expect(await directory.pressure().roots == 0)
                await directory.shutdown()
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) {
                    try await directory.registrationStates(scopes: [warm])
                }
            } catch {
                await gate.release(); _ = await blocking.result; _ = await coldClaim.result
                await directory.shutdown(); throw error
            }
        }
    }
    @Test("idle eviction preserves durable ownership and does not grow the cache")
    func idleEviction() async throws {
        try await withUserEventDatabase { database, _, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let directory = makeDirectory(database: database, journal: journal, maximumRoots: 2)
            let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
            let before = try #require(try await directory.registrationOwners(scopes: [first]).first)
            _ = try await directory.registrationOwners(scopes: [second])
            let after = try #require(try await directory.registrationOwners(scopes: [first]).first)
            #expect(before.ownerID == after.ownerID && before.epoch == after.epoch && before.revision == after.revision)
            #expect(await directory.pressure().owners == 1)
            await directory.shutdown()
            #expect(await directory.pressure().owners == 0)
        }
    }

    @Test("active owners cannot be evicted and cancelled claims retain global capacity until SQL settles")
    func activeClaimsRetainCapacity() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let ownerID = UUID(), scope = V2PolicyAuthorizationScope.account(UUID())
            _ = try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: 30)
            let directory = makeDirectory(database: database, journal: journal, maximumRoots: 2, ownerID: ownerID)
            let gate = DirectoryTransactionGate()
            let blocking = Task {
                try await database.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    _ = try await sql.raw("SELECT scope_key FROM \(unsafeRaw: schema).policy_authorization_scopes WHERE scope_key=\(bind: scope.key) FOR UPDATE").all()
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                    await gate.hold(pid: pid)
                }
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while await gate.pid == nil, ContinuousClock.now < deadline { await Task.yield() }
            guard let pid = await gate.pid else {
                await gate.release(); _ = await blocking.result; await directory.shutdown()
                throw V2PolicyAuthorizationLifecycleError.corruptPersistence
            }
            let first = Task { try await directory.registrationOwners(scopes: [scope]) }
            do {
                let deadline = ContinuousClock.now + .seconds(5)
                var blocked: Int64 = 0
                repeat {
                    blocked = try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer = ANY(pg_blocking_pids(pid))").first(decoding: Count.self)?.value ?? 0
                    if blocked > 0 { break }
                    await Task.yield()
                } while ContinuousClock.now < deadline
                #expect(blocked > 0)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                    try await directory.registrationOwners(scopes: [.account(UUID())])
                }
                first.cancel()
                #expect(await directory.pressure().roots == 1)
                let closing = Task { await directory.shutdown() }
                let closeDeadline = ContinuousClock.now + .seconds(5)
                while !(await directory.pressure().closed), ContinuousClock.now < closeDeadline { await Task.yield() }
                #expect(await directory.pressure().closed)
                #expect(await directory.pressure().roots == 1)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) {
                    try await directory.registrationOwners(scopes: [scope])
                }
                await gate.release()
                try await blocking.value
                #expect(try await first.value.count == 1)
                await closing.value
                #expect(await directory.pressure().roots == 0)
            } catch {
                await gate.release(); _ = await blocking.result; _ = await first.result; await directory.shutdown(); throw error
            }
        }
    }

    private func makeDirectory(database: any Database, journal: PostgresV2PolicyAuthorizationJournal,
                               maximumRoots: Int, ownerID: UUID = UUID(), maximumOwners: Int = 1,
                               maximumRetainedStates: Int = 0, maximumRetainedStateBytes: Int = 4 * 1_024 * 1_024,
                               memoryMetrics: V2SendOperationBatchMetrics? = nil) -> PostgresV2PolicyOwnerDirectory {
        .init(journal: journal, dispatcher: .init(database: database,
            projectionDelivery: SuccessfulProjectionDelivery(),
            legacyAuthorization: .init(controlDatabase: database, ownerDatabases: [:])),
            ownerID: ownerID, maximumOwners: maximumOwners, maximumRoots: maximumRoots,
            maximumRetainedStates: maximumRetainedStates, maximumRetainedStateBytes: maximumRetainedStateBytes,
            memoryMetrics: memoryMetrics,
            revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
    }
    private struct Count: Decodable { let value: Int64 }
}
private actor DirectoryTransactionGate {
    private(set) var pid: Int64?
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold(pid: Int64) async {
        self.pid = pid
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
