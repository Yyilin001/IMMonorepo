import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerContracts
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import Testing

@Suite("room policy activation directory", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2RoomPolicyAuthorizationDirectoryTests {
    @Test("initialized registry references are shared by concurrent readers and close atomically")
    func initializedReferencesAndShutdown() async throws {
        let token = try token()
        let registry = PostgresV2RoomPolicyAuthorizationRegistry(activation: token, endpoint: "room-b",
            currentLoader: { _, _ in throw V2PolicyAuthorizationLifecycleError.invalidRequest })
        let directory = PostgresV2RoomPolicyAuthorizationDirectory(endpoint: "room-b", maximumRooms: 1,
            factory: { _ in
                Issue.record("Initialized registry unexpectedly entered cold creation")
                return registry
            }, initializedFactory: { _ in registry })
        try await directory.install(.init(token: token, kind: "group", directState: nil))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<128 {
                group.addTask {
                    let found = try await directory.registry(token: token)
                    #expect(found === registry)
                }
            }
            try await group.waitForAll()
        }
        #expect(await directory.pressure().creations == 0)
        await directory.shutdown()
        #expect(await registry.pressure().closed)
        await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) {
            try await directory.registry(token: token)
        }
    }

    @Test("cancelled creation keeps capacity, completed creation coalesces, and stale retirement cannot close a replacement")
    func creationAndReplacement() async throws {
        let gate = CreationGate(), token = try token(), participants = (UUID(), UUID())
        let directory = makeDirectory(participants: participants, gate: gate)
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
            await directory.retire(token: token)
            #expect(await registry.pressure().closed)
            #expect(await directory.pressure().rooms == 0)
            let new = try await directory.registry(token: replacement)
            #expect(new !== registry)
            await directory.retire(token: token)
            #expect(await new.pressure().closed == false)
            #expect(await directory.pressure().rooms == 1)
            await directory.shutdown()
            #expect(await new.pressure().closed)
            #expect(await directory.pressure().rooms == 0)
        } catch {
            await gate.release(); _ = await first.result; await directory.shutdown(); throw error
        }
    }

    @Test("retirement during creation seals ingress and joins the actual creation before freeing the slot")
    func retireDuringCreation() async throws {
        let gate = CreationGate(), token = try token()
        let directory = makeDirectory(participants: (UUID(), UUID()), gate: gate)
        let loading = Task { try await directory.registry(token: token) }
        var retiring: Task<Void, Never>?
        do {
            try await eventually { await gate.calls == 1 }
            retiring = Task { await directory.retire(token: token) }
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
            await retiring?.value
            #expect(await directory.pressure().rooms == 0)
            #expect(await directory.pressure().creations == 0)
            await directory.shutdown()
        } catch {
            await gate.release(); _ = await loading.result; _ = await retiring?.result
            await directory.shutdown(); throw error
        }
    }

    private func makeDirectory(participants: (UUID, UUID), gate: CreationGate)
        -> PostgresV2RoomPolicyAuthorizationDirectory {
        return .init(endpoint: "room-b", maximumRooms: 1, maximumCreations: 1, factory: { token in
            await gate.hold()
            return PostgresV2RoomPolicyAuthorizationRegistry(activation: token, participants: participants,
                endpoint: "room-b", currentLoader: { _, _ in
                    Issue.record("Unwarmed registry unexpectedly cold-loaded policy")
                    throw V2PolicyAuthorizationLifecycleError.invalidRequest
                })
        })
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
