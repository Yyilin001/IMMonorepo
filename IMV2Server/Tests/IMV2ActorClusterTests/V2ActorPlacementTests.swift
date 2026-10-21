import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorCluster

@Suite("Actor placement lifecycle without room database leases")
struct V2ActorPlacementTests {
    private let successor = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
    private func host() -> V2ActorHostIdentity { .init(hostID: .init(uuid: UUID()), incarnationID: UUID()) }
    private func fixture() throws -> (V2ActorPlacementSnapshot, V2ActorPlacementDirectory, V2ActorHostIdentity) {
        let host = host()
        let snapshot = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)],
            hosts: [.init(host: host, retired: false), .init(host: successor, retired: false)])
        return (snapshot, .init(snapshot: snapshot), host)
    }

    @Test("placement history identity survives host expansion but isolates shards and deployments")
    func stableDeploymentIdentity() throws {
        let deployment = UUID()
        let a = try V2RoomDiscoveryPeer(hostID: .init(uuid: UUID()), serviceID: .init("host-a"),
            address: "a.test", port: 7337, accessibleShardIDs: ["rooms", "other"], maximumRooms: 100)
        let b = try V2RoomDiscoveryPeer(hostID: .init(uuid: UUID()), serviceID: .init("host-b"),
            address: "b.test", port: 7337, accessibleShardIDs: ["rooms", "other"], maximumRooms: 100)
        let original = try V2RoomActorPlacementRuntime.initialSnapshot(deploymentID: deployment, shard: "rooms", peers: [a])
        let expanded = try V2RoomActorPlacementRuntime.initialSnapshot(deploymentID: deployment, shard: "rooms", peers: [a, b])
        #expect(original.clusterID == expanded.clusterID)
        #expect(original.clusterID == (try V2RoomActorPlacementRuntime.initialSnapshot(
            deploymentID: deployment, shard: "rooms", peers: [b, a])).clusterID)
        #expect(original.clusterID != (try V2RoomActorPlacementRuntime.initialSnapshot(
            deploymentID: deployment, shard: "other", peers: [a])).clusterID)
        #expect(original.clusterID != (try V2RoomActorPlacementRuntime.initialSnapshot(
            deploymentID: UUID(), shard: "rooms", peers: [a])).clusterID)
        // This is only genesis affinity; startup must still load committed
        // history and must never overwrite it with the expanded genesis.
        let allRetired = expanded.slots.allSatisfy { $0.retired }
        #expect(allRetired)
    }

    @Test("Committed transfer withdraws admission before publishing the successor")
    func transfer() throws {
        let (initial, directory, oldHost) = try fixture()
        var machine = V2ActorPlacementStateMachine(snapshot: initial)
        let identity = V2RoomActorIdentity(roomID: .init(uuid: UUID()), clusterID: initial.clusterID,
            partition: 0, owner: initial.slots[0].owner, activationID: UUID())
        let transfer = V2ActorPlacementTransfer(id: UUID(), successor: successor)
        #expect(directory.admits(identity))
        try machine.apply(.beginTransfer(partition: 0, expected: initial.slots[0].owner, transfer: transfer), revision: 2)
        try directory.installCommitted(machine.snapshot)
        #expect(!directory.admits(identity))
        #expect(machine.snapshot.slots[0].owner.host == oldHost)
        #expect(throws: V2ActorPlacementError.invalidTransition) {
            try machine.apply(.completeTransfer(partition: 0, expected: initial.slots[0].owner, transferID: UUID()), revision: 3)
        }
        #expect(machine.snapshot.revision == 2)
        try machine.apply(.completeTransfer(partition: 0, expected: initial.slots[0].owner, transferID: transfer.id), revision: 3)
        try directory.installCommitted(machine.snapshot)
        #expect(machine.snapshot.slots[0].owner.host == transfer.successor)
        #expect(machine.snapshot.slots[0].owner.epoch == 2)
        #expect(!directory.admits(identity))
        #expect(throws: V2ActorPlacementError.staleRevision) { try directory.installCommitted(initial) }
    }

    @Test("Conflicting committed snapshots cannot replace the current revision")
    func conflictingSnapshot() throws {
        let (initial, directory, _) = try fixture()
        let conflicting = try V2ActorPlacementSnapshot(clusterID: initial.clusterID, revision: 1,
            slots: [.init(owner: .init(host: host(), epoch: 1), transfer: nil)])
        #expect(throws: V2ActorPlacementError.conflictingSnapshot) { try directory.installCommitted(conflicting) }
        #expect(directory.snapshot() == initial)
    }

    @Test("Higher directory revisions cannot change host without advancing ownership epoch")
    func ownerEpochRegression() throws {
        let (initial, directory, _) = try fixture()
        let invalid = try V2ActorPlacementSnapshot(clusterID: initial.clusterID, revision: 2,
            slots: [.init(owner: .init(host: host(), epoch: 1), transfer: nil)])
        #expect(throws: V2ActorPlacementError.staleOwner) { try directory.installCommitted(invalid) }
        #expect(directory.snapshot() == initial)
    }

    @Test("Failed initialization releases its capacity and can be retried")
    func failedInitialization() async throws {
        let (_, directory, host) = try fixture(), probe = Probe()
        let registry = try V2RoomActorRegistry<Int>(host: host, directory: directory, maximumRooms: 1,
            make: { _ in
                let value = await probe.make()
                if value == 1 { throw V2ActorPlacementError.unavailable }
                return value
            }, close: { _ in await probe.closed() })
        let room = RoomID(uuid: UUID())
        await #expect(throws: V2ActorPlacementError.unavailable) { try await registry.resolve(room) }
        #expect(await registry.count() == 0)
        let handle = try await registry.resolve(room)
        #expect(try await handle.invoke { $0 } == 2)
        await registry.stop()
        #expect(await probe.closeCount == 1)
    }

    @Test("Concurrent resolution creates one instance and warm calls bypass the registry")
    func concurrentCreation() async throws {
        let (_, directory, host) = try fixture(), probe = Probe(), gate = Gate()
        let registry = try V2RoomActorRegistry<Int>(host: host, directory: directory, maximumRooms: 2,
            make: { _ in let value = await probe.make(); await gate.wait(); return value },
            close: { _ in await probe.closed() })
        let room = RoomID(uuid: UUID())
        let handles = try await withThrowingTaskGroup(of: V2RoomActorHandle<Int>.self) { group in
            for _ in 0..<64 { group.addTask { try await registry.resolve(room) } }
            await gate.entered(); await gate.release()
            var handles: [V2RoomActorHandle<Int>] = []
            for try await handle in group { handles.append(handle) }
            return handles
        }
        #expect(handles.count == 64)
        #expect(handles.allSatisfy { $0 === handles[0] })
        #expect(await probe.made == 1)
        #expect(try await handles[0].invoke { $0 } == 1)
        await registry.stop()
        #expect(await probe.closeCount == 1)
        #expect(await registry.count() == 0)
    }

    @Test("Cancelling one waiter does not cancel shared initialization")
    func cancelledWaiter() async throws {
        let (_, directory, host) = try fixture(), probe = Probe(), gate = Gate()
        let registry = try V2RoomActorRegistry<Int>(host: host, directory: directory, maximumRooms: 1,
            make: { _ in let value = await probe.make(); await gate.wait(); return value },
            close: { _ in await probe.closed() })
        let room = RoomID(uuid: UUID()), cancelled = Task { try await registry.resolve(room) }
        await gate.entered(); cancelled.cancel()
        let survivor = Task { try await registry.resolve(room) }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let handle = try await survivor.value
        #expect(try await handle.invoke { $0 } == 1)
        #expect(await probe.made == 1)
        await registry.stop()
    }

    @Test("Retirement rejects old handles and delayed cleanup cannot close a replacement")
    func retirement() async throws {
        let (_, directory, host) = try fixture(), probe = Probe()
        let registry = try V2RoomActorRegistry<Int>(host: host, directory: directory, maximumRooms: 1,
            make: { _ in await probe.make() }, close: { _ in await probe.closed() })
        let room = RoomID(uuid: UUID()), first = try await registry.resolve(room)
        await registry.retire(first.identity)
        await #expect(throws: V2ActorPlacementError.retiring) { try await first.invoke { $0 } }
        let second = try await registry.resolve(room)
        #expect(second.identity.activationID != first.identity.activationID)
        await registry.retire(first.identity)
        #expect(try await second.invoke { $0 } == 2)
        #expect(await probe.closeCount == 1)
        await registry.stop()
        #expect(await probe.closeCount == 2)
    }

    @Test("Placement withdrawal closes warm references and drainage waits for physical work")
    func physicalDrain() async throws {
        let (initial, directory, host) = try fixture(), probe = Probe(), gate = Gate()
        let registry = try V2RoomActorRegistry<Int>(host: host, directory: directory, maximumRooms: 1,
            make: { _ in await probe.make() }, close: { _ in await probe.closed() })
        let handle = try await registry.resolve(.init(uuid: UUID()))
        let work = Task { try await handle.invoke { value in await gate.wait(); return value } }
        await gate.entered()
        var machine = V2ActorPlacementStateMachine(snapshot: initial)
        try machine.apply(.beginTransfer(partition: 0, expected: handle.identity.owner,
            transfer: .init(id: UUID(), successor: successor)), revision: 2)
        try directory.installCommitted(machine.snapshot)
        await #expect(throws: V2ActorPlacementError.staleOwner) { try await handle.invoke { $0 } }
        let drain = Task { await registry.drain(partition: 0, owner: handle.identity.owner) }
        #expect(await probe.closeCount == 0)
        await gate.release()
        #expect(try await work.value == 1)
        await drain.value
        #expect(await probe.closeCount == 1)
        #expect(await registry.count() == 0)
        await registry.stop()
    }
}

private actor Probe {
    var made = 0
    var closeCount = 0
    func make() -> Int { made += 1; return made }
    func closed() { closeCount += 1 }
}

private actor Gate {
    private var released = false
    private var wasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        wasEntered = true
        let observers = self.observers; self.observers.removeAll()
        for observer in observers { observer.resume() }
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func entered() async {
        guard !wasEntered else { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        let waiters = self.waiters; self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
