import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerContracts
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("room policy activation directory", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2RoomPolicyAuthorizationDirectoryTests {
    @Test("cancelled creation keeps capacity, completed creation coalesces, and stale retirement cannot close a replacement")
    func creationAndReplacement() async throws {
        try await withUserEventDatabase { database, _, schema in
            let gate = CreationGate(), token = try token(), participants = (UUID(), UUID())
            let directory = makeDirectory(database: database, schema: schema, participants: participants, gate: gate)
            await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) {
                try await V2RoomSQLDeadline.withDeadline(.now - .seconds(1)) { try await directory.registry(token: token) }
            }
            #expect(await gate.calls == 0)
            #expect(await directory.pressure().creations == 0)
            let callerDeadline = ContinuousClock.now + .seconds(5)
            let first = Task {
                try await V2RoomSQLDeadline.withDeadline(callerDeadline) { try await directory.registry(token: token) }
            }
            do {
                try await eventually { await gate.calls == 1 }
                #expect(await gate.deadline == callerDeadline)
                first.cancel()
                #expect(await directory.pressure().creations == 1)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                    try await directory.registry(token: self.token())
                }
                let replacement = V2RoomActivationToken(roomID: token.roomID, owner: token.owner,
                    activationEpoch: token.activationEpoch,
                    host: .init(hostID: token.host.hostID, incarnationID: UUID()))
                await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                    try await directory.registry(token: replacement)
                }
                let second = Task { try await directory.registry(token: token) }
                await gate.release()
                let registry = try await second.value
                #expect(try await directory.registry(token: token) === registry)
                #expect(await gate.calls == 1)
                await #expect(throws: CancellationError.self) { try await first.value }
                try await directory.retire(token: token)
                #expect(await registry.pressure().closed)
                #expect(await directory.pressure().rooms == 0)
                let new = try await directory.registry(token: replacement)
                #expect(new !== registry)
                try await directory.retire(token: token)
                #expect(await new.pressure().closed == false)
                #expect(await directory.pressure().rooms == 1)
                try await directory.shutdown()
                #expect(await new.pressure().closed)
                #expect(await directory.pressure().rooms == 0)
            } catch {
                await gate.release(); _ = await first.result; try? await directory.shutdown(); throw error
            }
        }
    }

    @Test("retirement during creation seals ingress and joins the actual creation before freeing the slot")
    func retireDuringCreation() async throws {
        try await withUserEventDatabase { database, _, schema in
            let gate = CreationGate(), token = try token()
            let directory = makeDirectory(database: database, schema: schema, participants: (UUID(), UUID()), gate: gate)
            let loading = Task { try await directory.registry(token: token) }
            var retiring: Task<Void, any Error>?
            do {
                try await eventually { await gate.calls == 1 }
                retiring = Task { try await directory.retire(token: token) }
                try await eventually { await directory.pressure().retiring == 1 }
                #expect(await directory.pressure().rooms == 1)
                #expect(await directory.pressure().creations == 1)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) {
                    try await directory.registry(token: token)
                }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                    try await directory.registry(token: self.token())
                }
                await gate.release()
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) { try await loading.value }
                try await retiring?.value
                #expect(await directory.pressure().rooms == 0)
                #expect(await directory.pressure().creations == 0)
                try await directory.shutdown()
            } catch {
                await gate.release(); _ = await loading.result; _ = await retiring?.result
                try? await directory.shutdown(); throw error
            }
        }
    }

    @Test("missing activation revocation waits for actual SQL and retains bounded capacity after caller cancellation")
    func fallbackWaitsForSQL() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let admission = V2DatabaseWorkAdmissionController(policy: .init(maximumForegroundWriteInFlight: 1,
                maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
                maximumForegroundWriteQueued: 1, maximumInteractiveReadQueued: 1,
                maximumSyncQueued: 16, timeout: .seconds(5)))
            let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema,
                databaseWorkAdmission: admission)
            let directory = PostgresV2RoomPolicyAuthorizationDirectory(endpoint: "room-b", maximumRooms: 1,
                maximumRevocations: 1, factory: { _ in throw V2PolicyAuthorizationLifecycleError.invalidRequest },
                fallback: { try await fence.revoke($0) })
            let holder = V2PolicyAuthorizationHolder(registrationID: UUID(), roomID: UUID(), activationID: UUID(),
                roomOwnerEpoch: 0, generation: 1, endpoint: "room-b", validUntil: Date().addingTimeInterval(30))
            guard case .admitted = await admission.acquire(.sync, callerDeadline: .now + .seconds(5)) else {
                throw V2PolicyAuthorizationLifecycleError.busy
            }
            let installing = Task { try await fence.install(holder) }
            var permitHeld = true
            do {
                try await eventually { await admission.snapshot().sync.queued == 1 }
                // The bounded waiter has not dispatched even the lease insert.
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).room_policy_authorization_leases").first(decoding: Count.self)?.value == 0)
                await admission.release(.sync)
                permitHeld = false
                try await installing.value
                #expect(await admission.snapshot().sync.inFlight == 0)
            } catch {
                if permitHeld { await admission.release(.sync) }
                _ = await installing.result
                try? await directory.shutdown()
                throw error
            }
            let gate = SQLGate()
            let transaction = Task {
                try await database.transaction { transaction in
                    try await fence.requireActive(holder, transaction: transaction)
                    let sql = try #require(transaction as? any SQLDatabase)
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                    await gate.hold(pid: pid)
                }
            }
            var revoking: Task<V2PolicyAuthorizationRevocationProof, any Error>?
            do {
                try await eventually { await gate.pid != nil }
                let pid = try #require(await gate.pid)
                let task = Task { try await directory.revoke(holder) }; revoking = task
                try await eventually {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer = ANY(pg_blocking_pids(pid))").first(decoding: Count.self)?.value ?? 0 > 0
                }
                task.cancel()
                #expect(await directory.pressure().revocations == 1)
                #expect(await admission.snapshot().sync.inFlight == 1)
                let other = V2PolicyAuthorizationHolder(registrationID: UUID(), roomID: holder.roomID,
                    activationID: holder.activationID, roomOwnerEpoch: 0, generation: 2,
                    endpoint: holder.endpoint, validUntil: holder.validUntil)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) { try await directory.revoke(other) }
                await gate.release(); try await transaction.value
                #expect(try await task.value.holder == holder)
                #expect(await directory.pressure().revocations == 0)
                #expect(await admission.snapshot().sync.inFlight == 0)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await fence.install(holder) }
                try await directory.shutdown()
            } catch {
                await gate.release(); _ = await transaction.result; _ = await revoking?.result
                try? await directory.shutdown(); throw error
            }
        }
    }

    private func makeDirectory(database: any Database, schema: String, participants: (UUID, UUID), gate: CreationGate)
        -> PostgresV2RoomPolicyAuthorizationDirectory {
        let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
        return .init(endpoint: "room-b", maximumRooms: 1, maximumCreations: 1, factory: { token in
            await gate.hold()
            return PostgresV2RoomPolicyAuthorizationRegistry(activation: token, participants: participants,
                endpoint: "room-b", fence: fence, loader: { _, _, _ in
                    Issue.record("Unwarmed registry unexpectedly cold-loaded policy")
                    throw V2PolicyAuthorizationLifecycleError.invalidRequest
                })
        }, fallback: { try await fence.revoke($0) })
    }
    private func token() throws -> V2RoomActivationToken {
        .init(roomID: .init(uuid: UUID()), owner: try .init(shardID: "room-b", epoch: 0),
            activationEpoch: try .init(1), host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
    }
    private func eventually(_ predicate: @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while .now < deadline { if try await predicate() { return }; await Task.yield() }
        throw V2PolicyAuthorizationLifecycleError.notDrained
    }
    private struct Count: Decodable { let value: Int64 }
}

private actor CreationGate {
    private(set) var calls = 0
    private(set) var deadline: ContinuousClock.Instant?
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        calls += 1
        deadline = V2RoomSQLDeadline.current
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private actor SQLGate {
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
