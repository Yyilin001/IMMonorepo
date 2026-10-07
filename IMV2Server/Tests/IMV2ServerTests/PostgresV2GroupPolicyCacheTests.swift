import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("bounded group policy cache", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2GroupPolicyCacheTests {
    @Test("cancelled eviction retains capacity until durable SQL settles and stale preparation cannot execute")
    func durableEviction() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let sender = UUID(), second = UUID(), token = try token()
            try await seed([sender, second], sql: sql, schema: schema)
            let recorder = GroupCacheSnapshots(), fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
            let registry = makeRegistry(database: database, schema: schema, token: token, recorder: recorder)
            let old = try await registry.runtime(sender: sender, token: token)
            let command = try command(sender: sender, token: token)
            let queued = try await old.prepareBatch(commands: [command], callerDeadline: .now + .seconds(20))
            let holder = try #require(await recorder.holders.first)
            let held = GroupCacheHold()
            let transaction = Task {
                try await database.transaction { transaction in
                    try await fence.requireActive(holder, transaction: transaction)
                    let sql = try #require(transaction as? any SQLDatabase)
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                    await held.wait(pid: pid)
                }
            }
            var evicting: Task<PostgresV2RoomPolicyAuthorization, any Error>?
            do {
                try await observe { await held.pid != nil }
                let pid = try #require(await held.pid)
                let miss = Task { try await registry.runtime(sender: second, token: token) }; evicting = miss
                try await observe {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))").first(decoding: Count.self)?.value ?? 0 > 0
                }
                miss.cancel()
                #expect(await registry.pressure().directions == 1)
                #expect(await registry.isEvicting())
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                    try await registry.runtime(sender: UUID(), token: token)
                }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) {
                    try await old.executePreparedBatch(queued) { _ in Issue.record("evicted witness executed") }
                }
                await held.release(); try await transaction.value
                await #expect(throws: CancellationError.self) { try await miss.value }
                #expect(await registry.pressure().directions == 0)
                #expect(await registry.isEvicting() == false)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await fence.install(holder) }
                let replacement = try await registry.runtime(sender: sender, token: token)
                #expect(replacement !== old && replacement.activationID != old.activationID)
                try await replacement.warm()
                let current = try #require(await recorder.holders.last)
                #expect(current.registrationID != holder.registrationID)
                #expect(try await registry.revoke(holder).holder == holder)
                #expect(await replacement.pressure().accepting)
                // A bounded cache serves more distinct senders than its size.
                // Unwarmed entries hold no durable permit and can retire cheaply.
                for _ in 0..<130 { _ = try await registry.runtime(sender: UUID(), token: token) }
                #expect(await registry.pressure().directions == 1)
                try await registry.shutdown()
            } catch {
                await held.release(); _ = await transaction.result; _ = await evicting?.result
                try? await registry.shutdown(); throw error
            }
        }
    }

    @Test("failed durable cleanup stays sealed and the same sender retries after database recovery")
    func failedCleanup() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let sender = UUID(), token = try token(), recorder = GroupCacheSnapshots()
            try await seed([sender], sql: sql, schema: schema)
            let registry = makeRegistry(database: database, schema: schema, token: token, recorder: recorder)
            let old = try await registry.runtime(sender: sender, token: token)
            try await old.warm()
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).room_policy_authorization_leases RENAME TO unavailable_group_leases").run()
            do {
                await #expect(throws: (any Error).self) {
                    try await registry.runtime(sender: UUID(), token: token)
                }
                #expect(await old.pressure().closed)
                #expect(await registry.pressure().directions == 1)
                #expect(await registry.isEvicting() == false)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) { try await old.warm() }
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).unavailable_group_leases RENAME TO room_policy_authorization_leases").run()
                let replacement = try await registry.runtime(sender: sender, token: token)
                #expect(replacement !== old)
                try await replacement.warm()
                #expect(await registry.pressure().directions == 1)
                #expect(await recorder.holders.count == 2)
                try await registry.shutdown()
            } catch {
                try? await sql.raw("ALTER TABLE \(unsafeRaw: schema).unavailable_group_leases RENAME TO room_policy_authorization_leases").run()
                try? await registry.shutdown(); throw error
            }
        }
    }

    @Test("cold loads and actual message transactions cannot be evicted", arguments: ["cold", "execution"])
    func activeRoots(phase: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let sender = UUID(), token = try token(), held = GroupCacheHold(), recorder = GroupCacheSnapshots()
            try await seed([sender], sql: sql, schema: schema)
            let registry = makeRegistry(database: database, schema: schema, token: token, recorder: recorder,
                beforeLoad: { if phase == "cold" { await held.wait(pid: 0) } })
            let runtime = try await registry.runtime(sender: sender, token: token)
            if phase == "execution" { try await runtime.warm() }
            let command = try command(sender: sender, token: token)
            let work = Task {
                if phase == "cold" { try await runtime.warm() }
                else {
                    try await runtime.execute(command: command, callerDeadline: .now + .seconds(20)) { execution in
                        try await database.transaction { transaction in
                            let sql = try #require(transaction as? any SQLDatabase)
                            try await execution.requireActive(roomID: token.roomID.uuidValue!, senderID: sender,
                                clientMessageID: command.clientMessageID.uuidValue!, sql: sql)
                            await held.wait(pid: 0)
                        }
                    }
                }
            }
            do {
                try await observe { await held.pid != nil }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                    try await registry.runtime(sender: UUID(), token: token)
                }
                #expect(await runtime.pressure().closed == false)
                #expect(try await registry.runtime(sender: sender, token: token) === runtime)
                await held.release(); try await work.value
                _ = try await registry.runtime(sender: UUID(), token: token)
                #expect(await runtime.pressure().closed)
                #expect(await registry.pressure().directions == 1)
                try await registry.shutdown()
            } catch {
                await held.release(); _ = await work.result; try? await registry.shutdown(); throw error
            }
        }
    }

    private func makeRegistry(database: any Database, schema: String, token: V2RoomActivationToken,
        recorder: GroupCacheSnapshots, beforeLoad: @escaping @Sendable () async -> Void = {}) -> PostgresV2RoomPolicyAuthorizationRegistry {
        let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
        let store = PostgresV2AccountPolicySnapshotStore(database: database, schema: schema)
        let ownerID = UUID()
        return .init(activation: token, endpoint: "group-cache", fence: .init(database: database, schema: schema),
            maximumDirections: 1, accountLoader: { sender, registration, activation in
                await beforeLoad()
                let owner = try await journal.acquireOwner(scope: .account(sender), ownerID: ownerID, durationSeconds: 30)
                let state = try await journal.readOwnerState(owner: owner)
                let snapshot = try await store.register(sender: sender, state: state, registrationID: registration,
                    roomID: token.roomID.uuidValue!, activationID: activation, roomOwnerEpoch: token.owner.epoch,
                    endpoint: "group-cache", durationSeconds: 20)
                await recorder.record(snapshot.holder)
                return snapshot
            })
    }
    private func seed(_ users: [UUID], sql: any SQLDatabase, schema: String) async throws {
        for (index, user) in users.enumerated() {
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).public_user_profiles(user_id,public_handle,display_name,created_at,updated_at)
                VALUES (\(bind: user),\(bind: "groupcache_\(index)"),'Sender',clock_timestamp(),clock_timestamp())
                """).run()
        }
    }
    private func token() throws -> V2RoomActivationToken {
        .init(roomID: .init(uuid: UUID()), owner: try .init(shardID: "room-b", epoch: 0),
            activationEpoch: try .init(1), host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
    }
    private func command(sender: UUID, token: V2RoomActivationToken) throws -> V2SendMessageCommand {
        try .init(roomID: token.roomID, senderUserID: .init(uuid: sender), clientMessageID: .init(uuid: UUID()),
            text: "group cache", limits: .init(maxUTF8Bytes: 64))
    }
    private func observe(_ check: @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while .now < deadline { if try await check() { return }; await Task.yield() }
        throw V2PolicyAuthorizationLifecycleError.notDrained
    }
    private struct Count: Decodable { let value: Int64 }
}

private actor GroupCacheSnapshots {
    private(set) var holders: [V2PolicyAuthorizationHolder] = []
    func record(_ holder: V2PolicyAuthorizationHolder) { holders.append(holder) }
}
private actor GroupCacheHold {
    private(set) var pid: Int64?
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait(pid: Int64) async {
        self.pid = pid
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
