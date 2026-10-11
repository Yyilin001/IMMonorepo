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
    @Test("idle current-policy eviction requires no lease SQL and rejects stale preparation")
    func idleEviction() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let sender = UUID(), token = try token()
            let registry = makeRegistry(database: database, schema: schema, token: token)
            let old = try await registry.runtime(sender: sender, token: token)
            let queued = try await old.prepareBatch(commands: [command(sender: sender, token: token)],
                callerDeadline: .now + .seconds(20))
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM pg_catalog.pg_class WHERE oid=to_regclass(\(bind: schema + ".room_policy_authorization_leases"))").first(decoding: GroupRetiredLeaseCount.self)?.value == 0)
            do {
                _ = try await registry.runtime(sender: UUID(), token: token)
                #expect(await registry.pressure().directions == 1)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) {
                    try await old.executePreparedBatch(queued) { _ in Issue.record("evicted witness executed") }
                }
                let replacement = try await registry.runtime(sender: sender, token: token)
                #expect(replacement !== old)
                try await replacement.warm()
                #expect(await replacement.pressure().accepting)
                for _ in 0..<130 { _ = try await registry.runtime(sender: UUID(), token: token) }
                #expect(await registry.pressure().directions == 1)
                await registry.shutdown()
            } catch {
                await registry.shutdown()
                throw error
            }
        }
    }

    @Test("current snapshot loads and actual transactions retain capacity through cancellation and shutdown",
          arguments: ["cold", "execution"])
    func activeRoots(phase: String) async throws {
        try await withUserEventDatabase { database, _, schema in
            let sender = UUID(), token = try token(), held = GroupCacheHold()
            let registry = makeRegistry(database: database, schema: schema, token: token,
                beforeLoad: { if phase == "cold" { await held.wait() } })
            let runtime = try await registry.runtime(sender: sender, token: token)
            let command = try command(sender: sender, token: token)
            let work = Task {
                if phase == "cold" { try await runtime.warm() }
                else {
                    try await runtime.execute(command: command, callerDeadline: .now + .seconds(20)) { execution in
                        try await database.transaction { transaction in
                            let sql = try #require(transaction as? any SQLDatabase)
                            try await execution.requireActive(roomID: token.roomID.uuidValue!, senderID: sender,
                                clientMessageID: command.clientMessageID.uuidValue!, sql: sql)
                            await held.wait()
                        }
                    }
                }
            }
            let stopped = GroupCacheShutdownProbe()
            var stopping: Task<Void, Never>?
            do {
                try await observe { await held.entered }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                    try await registry.runtime(sender: UUID(), token: token)
                }
                #expect(await runtime.pressure().closed == false)
                #expect(try await registry.runtime(sender: sender, token: token) === runtime)
                work.cancel()
                let shutdown = Task { await registry.shutdown(); await stopped.complete() }
                stopping = shutdown
                try await observe { await runtime.pressure().closed }
                #expect(await stopped.done == false)
                #expect(await registry.pressure().directions == 1)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) {
                    try await registry.runtime(sender: sender, token: token)
                }
                await held.release()
                _ = await work.result
                await shutdown.value
                #expect(await stopped.done)
            } catch {
                await held.release(); _ = await work.result; _ = await stopping?.result
                await registry.shutdown()
                throw error
            }
        }
    }

    private func makeRegistry(database: any Database, schema: String, token: V2RoomActivationToken,
        beforeLoad: @escaping @Sendable () async -> Void = {}) -> PostgresV2RoomPolicyAuthorizationRegistry {
        .init(activation: token, endpoint: "group-cache",
            maximumDirections: 1, currentLoader: { sender, recipient in
                #expect(recipient == nil)
                await beforeLoad()
                return try .account(sender: sender, snapshots: [.init(scope: .account(sender), version: 1,
                    facts: .account(.init(userID: sender, isActive: true, specialKind: nil,
                        specialStatus: nil, allowsServiceMessages: nil, allowsCustomerMessages: nil)))])
            })
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
}

private actor GroupCacheHold {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private actor GroupCacheShutdownProbe {
    private(set) var done = false
    func complete() { done = true }
}

private struct GroupRetiredLeaseCount: Decodable { let value: Int64 }
