import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ActorRuntime
import Testing
@testable import IMV2ActorCluster

@Suite("Committed placement and physical handoff")
struct V2ActorPlacementCoordinatorTests {
    private let successor = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
    private func host() -> V2ActorHostIdentity { .init(hostID: .init(uuid: UUID()), incarnationID: UUID()) }
    private func snapshot(host: V2ActorHostIdentity) throws -> V2ActorPlacementSnapshot {
        try .init(clusterID: UUID(), revision: 1, slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)],
            hosts: [.init(host: host, retired: false), .init(host: successor, retired: false)])
    }

    @Test("Successor cannot initialize until old physical work and close finish")
    func handoff() async throws {
        let oldIdentity = host(), newIdentity = successor, initial = try snapshot(host: oldIdentity)
        let log = PlacementTestLog(initial), workGate = PlacementGate(), closeGate = PlacementGate()
        let closes = PlacementSignal()
        let runtime = try V2RoomActorPlacementRuntime(logs: ["room-a": log], snapshots: ["room-a": initial])
        let configuration = try V2RoomRuntimeConfiguration()
        let old = V2RoomActivationHost<Int, Int>(identity: oldIdentity,
            placement: runtime, configuration: configuration,
            budget: .init(configuration: configuration), classify: { _ in .barrier },
            factory: .init { _ in
                .init(restore: { try await $0.validate() }, execute: { turn in
                    await workGate.hold()
                    return .committed(turn.items.map(\.request))
                }, invalidateReservation: { _ in }, close: {
                    await closeGate.hold(); await closes.signal()
                })
            })
        await old.start()
        let room = RoomID(uuid: UUID()), owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        guard case .ready(let token) = try await old.activate(roomID: room, owner: owner,
            deadline: .now + .seconds(2)) else { Issue.record("expected ready"); return }
        let work = Task { try await old.invoke(token: token, request: 1, deadline: .now + .seconds(5)) }
        await workGate.entered.wait()
        let coordinator = V2ActorPlacementCoordinator(log: log,
            directory: .init(snapshot: initial), authorizeSuccessor: { _ in }, drain: { snapshot, partition in
                try await runtime.drainPlacement(snapshot, shard: "room-a", partition: partition,
                    host: old, deadline: .now + .seconds(5))
            })
        let transfer = Task { try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
            successor: newIdentity, transferID: UUID()) }
        let waitingUntil = ContinuousClock.now + .seconds(2)
        while await old.snapshot().retiringRooms == 0 {
            guard ContinuousClock.now < waitingUntil else { throw V2ActorPlacementError.unavailable }
            await Task.yield()
        }
        #expect(await log.load().slots[0].owner.host == oldIdentity)
        #expect(await log.load().slots[0].transfer != nil)
        #expect(await closes.count == 0)
        #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
            try runtime.grant(roomID: room, owner: owner)
        }
        await #expect(throws: V2RoomCallFailure.notAccepted(.retired)) {
            try await old.invoke(token: token, request: 2, deadline: .now + .seconds(2))
        }
        await workGate.release()
        #expect(try await work.value == 1)
        await closeGate.entered.wait()
        // SQL completion alone is insufficient: physical executor close must
        // finish before the durable log can publish the successor.
        #expect(await log.load().slots[0].owner.host == oldIdentity)
        #expect(await closes.count == 0)
        #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
            try runtime.grant(roomID: room, owner: owner)
        }
        await closeGate.release()
        let committed = try await transfer.value
        #expect(await closes.count == 1)
        #expect(committed.slots[0].owner.host == newIdentity)
        #expect(committed.slots[0].owner.epoch == 2)
        try await runtime.refresh()
        #expect(try runtime.grant(roomID: room, owner: owner).host == newIdentity)
        await #expect(throws: V2RoomCallFailure.notAccepted(.staleActivation)) {
            try await old.activate(roomID: room, owner: owner, deadline: .now + .seconds(2))
        }
        #expect((await old.stop(deadline: .now + .seconds(2))).completed)
    }

    @Test("An RPC failure leaves ownership withdrawn, never transferred")
    func failedDrain() async throws {
        let initial = try snapshot(host: host()), log = PlacementTestLog(initial)
        let directory = V2ActorPlacementDirectory(snapshot: initial)
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: directory, authorizeSuccessor: { _ in },
            drain: { _, _ in throw V2ActorPlacementError.unavailable })
        await #expect(throws: V2ActorPlacementError.unavailable) {
            try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
                successor: successor, transferID: UUID())
        }
        let committed = await log.load()
        #expect(committed.slots[0].owner == initial.slots[0].owner)
        #expect(committed.slots[0].transfer != nil)
        #expect(directory.snapshot() == committed)
    }

    @Test("A durably retired Host transfers without contacting its stopped process")
    func retiredHostHandoff() async throws {
        let initial = try snapshot(host: host()), log = PlacementTestLog(initial)
        let retired = try await log.append(.retireHost(initial.slots[0].owner.host),
            expected: initial, requestID: UUID())
        let directory = V2ActorPlacementDirectory(snapshot: retired)
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: directory,
            authorizeSuccessor: { _ in }, drain: { _, _ in
                Issue.record("retirement already certified physical drain")
                throw V2ActorPlacementError.unavailable
            })
        let successor = self.successor, transferID = UUID()
        await log.loseNextCompletionResponse()
        await #expect(throws: V2ActorPlacementError.unavailable) {
            try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
                successor: successor, transferID: transferID)
        }
        let recovered = try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
            successor: successor, transferID: transferID)
        #expect(recovered.slots[0].owner == .init(host: successor, epoch: 2))
        #expect(!recovered.slots[0].retired && recovered.slots[0].transfer == nil)
        #expect(await log.load() == recovered)
        #expect(directory.snapshot() == recovered)
    }

    @Test("Uncommitted withdrawal input cannot retire the physical Host")
    func uncommittedWithdrawal() async throws {
        let identity = host(), initial = try snapshot(host: identity), log = PlacementTestLog(initial)
        let runtime = try V2RoomActorPlacementRuntime(logs: ["room-a": log], snapshots: ["room-a": initial])
        let configuration = try V2RoomRuntimeConfiguration()
        let physical = V2RoomActivationHost<Int, Int>(identity: identity,
            placement: runtime, configuration: configuration,
            budget: .init(configuration: configuration), classify: { _ in .barrier },
            factory: .init { _ in
                .init(restore: { try await $0.validate() }, execute: { .committed($0.items.map(\.request)) },
                    invalidateReservation: { _ in }, close: {})
            })
        await physical.start()
        let room = RoomID(uuid: UUID()), owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        guard case .ready(let token) = try await physical.activate(roomID: room, owner: owner,
            deadline: .now + .seconds(2)) else { Issue.record("expected ready"); return }
        var forged = V2ActorPlacementStateMachine(snapshot: initial)
        try forged.apply(.beginTransfer(partition: 0, expected: initial.slots[0].owner,
            transfer: .init(id: UUID(), successor: successor)), revision: 2)
        await #expect(throws: V2ActorPlacementError.staleOwner) {
            try await runtime.drainPlacement(forged.snapshot, shard: "room-a", partition: 0,
                host: physical, deadline: .now + .seconds(2))
        }
        #expect(await log.load() == initial)
        #expect(try runtime.grant(roomID: room, owner: owner).host == identity)
        #expect(await physical.isReady(token: token))
        #expect(try await physical.invoke(token: token, request: 7, deadline: .now + .seconds(2)) == 7)
        #expect((await physical.stop(deadline: .now + .seconds(2))).completed)
    }

    @Test("A completed transfer cannot be replayed as a live withdrawal")
    func completedWithdrawal() async throws {
        let identity = host(), initial = try snapshot(host: identity), log = PlacementTestLog(initial)
        let runtime = try V2RoomActorPlacementRuntime(logs: ["room-a": log], snapshots: ["room-a": initial])
        let transferID = UUID()
        let withdrawn = try await log.append(.beginTransfer(partition: 0, expected: initial.slots[0].owner,
            transfer: .init(id: transferID, successor: successor)), expected: initial, requestID: transferID)
        let completed = try await log.append(.completeTransfer(partition: 0, expected: initial.slots[0].owner,
            transferID: transferID), expected: withdrawn, requestID: transferID)
        let configuration = try V2RoomRuntimeConfiguration()
        let physical = V2RoomActivationHost<Int, Int>(identity: identity,
            placement: runtime, configuration: configuration,
            budget: .init(configuration: configuration), classify: { _ in .barrier },
            factory: .init { _ in
                .init(restore: { try await $0.validate() }, execute: { .committed($0.items.map(\.request)) },
                    invalidateReservation: { _ in }, close: {})
            })
        await #expect(throws: V2ActorPlacementError.staleOwner) {
            try await runtime.drainPlacement(withdrawn, shard: "room-a", partition: 0,
                host: physical, deadline: .now + .seconds(2))
        }
        #expect(await log.load() == completed)
        #expect((await physical.stop(deadline: .now + .seconds(2))).completed)
    }

    @Test("An in-flight restoration also blocks physical handoff")
    func restoringHandoff() async throws {
        let identity = host(), initial = try snapshot(host: identity), log = PlacementTestLog(initial)
        let runtime = try V2RoomActorPlacementRuntime(logs: ["room-a": log], snapshots: ["room-a": initial])
        let restoration = PlacementGate(), closing = PlacementGate()
        let configuration = try V2RoomRuntimeConfiguration()
        let physical = V2RoomActivationHost<Int, Int>(identity: identity,
            placement: runtime, configuration: configuration,
            budget: .init(configuration: configuration), classify: { _ in .barrier },
            factory: .init { _ in
                .init(restore: { context in
                    try await context.validate(); await restoration.hold(); try await context.validate()
                }, execute: { .committed($0.items.map(\.request)) },
                    invalidateReservation: { _ in }, close: { await closing.hold() })
            })
        await physical.start()
        let room = RoomID(uuid: UUID()), owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        let activation = Task { try await physical.activate(roomID: room, owner: owner,
            deadline: .now + .seconds(5)) }
        await restoration.entered.wait()
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: .init(snapshot: initial),
            authorizeSuccessor: { _ in }, drain: { snapshot, partition in
                try await runtime.drainPlacement(snapshot, shard: "room-a", partition: partition,
                    host: physical, deadline: .now + .seconds(5))
            })
        let successor = self.successor
        let transfer = Task { try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
            successor: successor, transferID: UUID()) }
        let waitingUntil = ContinuousClock.now + .seconds(2)
        while await physical.snapshot().retiringRooms == 0 {
            guard ContinuousClock.now < waitingUntil else { throw V2ActorPlacementError.unavailable }
            await Task.yield()
        }
        await #expect(throws: V2RoomCallFailure.notAccepted(.retired)) { try await activation.value }
        #expect(await log.load().slots[0].owner.host == identity)
        #expect(await closing.entered.count == 0)
        await restoration.release()
        await closing.entered.wait()
        #expect(await log.load().slots[0].owner.host == identity)
        await closing.release()
        #expect(try await transfer.value.slots[0].owner.host == successor)
        #expect((await physical.stop(deadline: .now + .seconds(2))).completed)
    }

    @Test("An untrusted successor cannot withdraw the current owner")
    func untrustedSuccessor() async throws {
        let initial = try snapshot(host: host()), log = PlacementTestLog(initial)
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: .init(snapshot: initial),
            authorizeSuccessor: { _ in throw V2ActorPlacementError.staleOwner },
            drain: { _, _ in Issue.record("must not drain an unauthorized transfer"); throw V2ActorPlacementError.unavailable })
        await #expect(throws: V2ActorPlacementError.staleOwner) {
            try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
                successor: successor, transferID: UUID())
        }
        #expect(await log.load() == initial)
    }

    @Test("A receipt for another transfer cannot publish ownership")
    func mismatchedReceipt() async throws {
        let initial = try snapshot(host: host()), log = PlacementTestLog(initial)
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: .init(snapshot: initial), authorizeSuccessor: { _ in }, drain: { value, partition in
            .init(clusterID: value.clusterID, partition: partition, owner: value.slots[partition].owner, transferID: UUID())
        })
        await #expect(throws: V2ActorPlacementError.staleOwner) {
            try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
                successor: successor, transferID: UUID())
        }
        #expect(await log.load().revision == 2)
    }

    @Test("Successor eligibility is checked again after physical drain")
    func successorExpiresDuringDrain() async throws {
        let initial = try snapshot(host: host()), log = PlacementTestLog(initial), checks = PlacementSignal()
        let directory = V2ActorPlacementDirectory(snapshot: initial)
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: directory,
            authorizeSuccessor: { _ in
                await checks.signal()
                guard await checks.count == 1 else { throw V2ActorPlacementError.staleOwner }
            }, drain: { value, partition in
                .init(clusterID: value.clusterID, partition: partition, owner: value.slots[partition].owner,
                    transferID: value.slots[partition].transfer!.id)
            })
        await #expect(throws: V2ActorPlacementError.staleOwner) {
            try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
                successor: successor, transferID: UUID())
        }
        let current = await log.load()
        #expect(await checks.count == 2)
        #expect(current.revision == 2)
        #expect(current.slots[0].owner == initial.slots[0].owner)
        #expect(current.slots[0].transfer != nil)
        #expect(directory.snapshot() == current)
    }

    @Test("Lost commit response is recovered by the exact durable transfer key")
    func lostCommitResponse() async throws {
        let initial = try snapshot(host: host()), log = PlacementTestLog(initial)
        let directory = V2ActorPlacementDirectory(snapshot: initial), newHost = successor, id = UUID()
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: directory, authorizeSuccessor: { _ in }, drain: { value, partition in
            await log.loseNextCompletionResponse()
            return .init(clusterID: value.clusterID, partition: partition, owner: value.slots[partition].owner,
                transferID: value.slots[partition].transfer!.id)
        })
        await #expect(throws: V2ActorPlacementError.unavailable) {
            try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner, successor: newHost, transferID: id)
        }
        #expect(directory.snapshot().revision == 2)
        #expect(await log.load().revision == 3)
        let recovered = try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
            successor: newHost, transferID: id)
        #expect(recovered.revision == 3)
        #expect(directory.snapshot().revision == 3)
        await #expect(throws: V2ActorPlacementError.staleOwner) {
            try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
                successor: newHost, transferID: UUID())
        }
    }

    @Test("Cancelled migration stays withdrawn and can resume with the same ID")
    func cancelledMigration() async throws {
        let initial = try snapshot(host: host()), log = PlacementTestLog(initial), gate = PlacementGate()
        let newHost = successor, id = UUID(), directory = V2ActorPlacementDirectory(snapshot: initial)
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: directory, authorizeSuccessor: { _ in }, drain: { value, partition in
            await gate.hold()
            return .init(clusterID: value.clusterID, partition: partition, owner: value.slots[partition].owner,
                transferID: value.slots[partition].transfer!.id)
        })
        let transfer = Task { try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
            successor: newHost, transferID: id) }
        await gate.entered.wait(); transfer.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await transfer.value }
        #expect(await log.load().revision == 2)
        let committed = try await coordinator.transfer(partition: 0, expected: initial.slots[0].owner,
            successor: newHost, transferID: id)
        #expect(committed.revision == 3)
    }

    @Test("Placement persistence uses fixed-field PB and validates nested values")
    func protobuf() throws {
        let initial = try snapshot(host: host())
        #expect(try V2ActorPlacementProtobuf.decode(V2ActorPlacementProtobuf.encode(initial)) == initial)
        let commands: [V2ActorPlacementCommand] = [
            .beginTransfer(partition: 0, expected: initial.slots[0].owner, transfer: .init(id: UUID(), successor: successor)),
            .completeTransfer(partition: 0, expected: initial.slots[0].owner, transferID: UUID()),
            .cancelTransfer(partition: 0, expected: initial.slots[0].owner, transferID: UUID()),
            .retireHost(initial.slots[0].owner.host),
            .registerHost(previous: initial.slots[0].owner.host,
                successor: .init(hostID: initial.slots[0].owner.host.hostID, incarnationID: UUID()))]
        for command in commands {
            #expect(try V2ActorPlacementProtobuf.decodeCommand(V2ActorPlacementProtobuf.encode(command)) == command)
        }
        #expect(throws: (any Error).self) { try V2ActorPlacementProtobuf.decode(Data()) }
        #expect(throws: (any Error).self) { try V2ActorPlacementProtobuf.decodeCommand(Data()) }
    }

    @Test("A reference cannot claim another partition even when both have the same host")
    func partitionBinding() throws {
        let owner = V2ActorPlacementOwner(host: host(), epoch: 1)
        let snapshot = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: owner, transfer: nil), .init(owner: owner, transfer: nil)])
        let room = RoomID(uuid: UUID()), partition = snapshot.partition(for: room)
        let forged = V2RoomActorIdentity(roomID: room, clusterID: snapshot.clusterID,
            partition: 1 - partition, owner: owner, activationID: UUID())
        #expect(!V2ActorPlacementDirectory(snapshot: snapshot).admits(forged))
    }
}

/// Test-only fault injector. Production must provide a durable linearizable log.
actor PlacementTestLog: V2ActorPlacementLog {
    private struct Key: Hashable { let id: UUID; let kind: Int }
    private var current: V2ActorPlacementSnapshot
    private var records: [Key: (V2ActorPlacementCommand, V2ActorPlacementSnapshot)] = [:]
    private var loseCompletion = false
    init(_ current: V2ActorPlacementSnapshot) { self.current = current }
    func load() -> V2ActorPlacementSnapshot { current }
    func loseNextCompletionResponse() { loseCompletion = true }
    func append(_ command: V2ActorPlacementCommand, evidence: V2ActorPlacementCommandEvidence, expected: V2ActorPlacementSnapshot, requestID: UUID, originRevision: UInt64) throws -> V2ActorPlacementSnapshot {
        let kind = command.logKind
        let key = Key(id: requestID, kind: kind)
        if let prior = records[key] {
            guard prior.0 == command else { throw V2ActorPlacementError.invalidTransition }
            return prior.1
        }
        guard current == expected else { throw V2ActorPlacementError.staleRevision }
        var machine = V2ActorPlacementStateMachine(snapshot: current)
        try machine.apply(command, revision: current.revision + 1)
        current = machine.snapshot; records[key] = (command, current)
        if kind == 2 && loseCompletion { loseCompletion = false; throw V2ActorPlacementError.unavailable }
        return current
    }
}

private actor PlacementSignal {
    var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { count += 1; let waiting = waiters; waiters.removeAll(); for waiter in waiting { waiter.resume() } }
    func wait() async { if count == 0 { await withCheckedContinuation { waiters.append($0) } } }
}
private actor PlacementGate {
    nonisolated let entered = PlacementSignal()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async { await entered.signal(); if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let waiting = waiters; waiters.removeAll(); for waiter in waiting { waiter.resume() } }
}
