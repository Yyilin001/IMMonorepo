import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorCluster

@Suite("Process placement registration replay")
struct V2ActorPlacementRuntimeTests {
    @Test("A host with no owned partitions can register, drain and restart without taking another host's rooms")
    func emptyHostLifecycle() async throws {
        let reserved = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let host = V2ActorHostIdentity(hostID: reserved.hostID, incarnationID: UUID())
        let owner = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: .init(host: owner, epoch: 9), transfer: nil)],
            hosts: [.init(host: reserved, retired: true), .init(host: owner, retired: false)])
        let log = RuntimePlacementLog(initial)
        let runtime = try V2RoomActorPlacementRuntime(logs: ["room-a": log], snapshots: ["room-a": initial])
        try await runtime.register(host, shards: ["room-a"])
        let registered = await log.load()
        #expect(registered.slots == initial.slots && registered.revision == 2)
        #expect(registered.registration(for: host.hostID) == .init(host: host, retired: false))
        #expect(try V2ActorPlacementProtobuf.decode(V2ActorPlacementProtobuf.encode(registered)) == registered)
        try await runtime.retireAfterDrain(.init(host: host), shards: ["room-a"])
        let retired = await log.load()
        #expect(retired.slots == initial.slots && retired.revision == 3)
        #expect(retired.registration(for: host.hostID) == .init(host: host, retired: true))
        let restarted = V2ActorHostIdentity(hostID: host.hostID, incarnationID: UUID())
        let next = try V2RoomActorPlacementRuntime(logs: ["room-a": log], snapshots: ["room-a": retired])
        try await next.register(restarted, shards: ["room-a"])
        let final = await log.load()
        #expect(final.revision == 4 && final.slots == initial.slots)
        #expect(final.registration(for: host.hostID) == .init(host: restarted, retired: false))
        // A late stop from the old process cannot retire its successor.
        try await runtime.retireAfterDrain(.init(host: host), shards: ["room-a"])
        #expect(await log.load() == final)
    }

    @Test("Retired transfer successor can be replaced even when no Host remains active")
    func replaceLastRetiredSuccessor() async throws {
        let owner = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let successor = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let replacement = V2ActorHostIdentity(hostID: successor.hostID, incarnationID: UUID())
        let snapshot = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: .init(host: owner, epoch: 3),
                transfer: .init(id: UUID(), successor: successor), retired: true)],
            hosts: [.init(host: owner, retired: true), .init(host: successor, retired: false)])
        let log = RuntimePlacementLog(snapshot)
        let runtime = try V2RoomActorPlacementRuntime(logs: ["room-a": log], snapshots: ["room-a": snapshot])
        let operation = UUID()
        try await runtime.retireAfterExclusion(.init(host: successor, operationID: operation, settledShardIDs: ["room-a"]),
            deadline: .now + .seconds(2))
        let retired = await log.load()
        #expect(retired.slots[0].transfer == nil)
        #expect(retired.slots[0].owner == snapshot.slots[0].owner && retired.slots[0].retired)
        #expect(retired.hosts.allSatisfy { $0.retired })
        await #expect(throws: V2ActorPlacementError.unavailable) {
            try await runtime.takeOverRetiredHost(owner, shards: ["room-a"], operationID: UUID(),
                eligibleHosts: [owner.hostID: ["room-a"], successor.hostID: ["room-a"]], deadline: .now + .seconds(2))
        }
        try await runtime.register(replacement, shards: ["room-a"])
        try await runtime.takeOverRetiredHost(owner, shards: ["room-a"], operationID: UUID(),
            eligibleHosts: [owner.hostID: ["room-a"], successor.hostID: ["room-a"]], deadline: .now + .seconds(2))
        let recovered = await log.load()
        #expect(recovered.slots[0].owner.host == replacement && recovered.slots[0].owner.epoch == 4)
        #expect(!recovered.slots[0].retired && recovered.slots[0].transfer == nil)
    }

    private func fixture() throws -> (V2ActorHostIdentity, V2ActorPlacementSnapshot, RuntimePlacementLog, V2RoomActorPlacementRuntime) {
        let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let previous = V2ActorHostIdentity(hostID: host.hostID, incarnationID: UUID())
        let snapshot = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: .init(host: previous, epoch: 1), transfer: nil, retired: true)])
        let log = RuntimePlacementLog(snapshot)
        return (host, snapshot, log, try .init(logs: ["room-a": log], snapshots: ["room-a": snapshot]))
    }

    @Test("An unaccepted expired startup attempt renews its identity only against the same retired predecessor")
    func expiredRegistrationAttempt() async throws {
        let (host, _, log, runtime) = try fixture()
        await log.expireNextSubmission()
        try await runtime.register(host, shards: ["room-a"])
        #expect(await log.commitCount == 1)
        #expect(await log.load().registration(for: host.hostID) == .init(host: host, retired: false))
    }

    @Test("Lost registration response retries the original command exactly once")
    func lostRegistrationResponse() async throws {
        let (host, _, log, runtime) = try fixture()
        await log.loseNextResponse()
        await #expect(throws: V2ActorPlacementError.unavailable) { try await runtime.register(host, shards: ["room-a"]) }
        #expect(await log.load().revision == 2)
        try await runtime.register(host, shards: ["room-a"])
        try await runtime.register(host, shards: ["room-a"])
        #expect(await log.load().revision == 2)
        #expect(await log.commitCount == 1)
        let grant = try runtime.grant(roomID: .init(uuid: UUID()), owner: .init(shardID: "room-a", epoch: 0))
        #expect(grant.host == host)
        #expect(grant.epoch == 2)
    }

    @Test("Concurrent startup calls share a durable registration key")
    func concurrentRegistration() async throws {
        let (host, _, log, runtime) = try fixture()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { try await runtime.register(host, shards: ["room-a"]) } }
            try await group.waitForAll()
        }
        #expect(await log.commitCount == 1)
        #expect(await log.load().revision == 2)
        let other = V2ActorHostIdentity(hostID: host.hostID, incarnationID: UUID())
        await #expect(throws: V2ActorPlacementError.invalidConfiguration) { try await runtime.register(other, shards: ["room-a"]) }
    }

    @Test("Lost startup reply still permits retirement of this exact committed registration")
    func retireAfterLostRegistrationResponse() async throws {
        let (host, _, log, runtime) = try fixture()
        await log.loseNextResponse()
        await #expect(throws: V2ActorPlacementError.unavailable) {
            try await runtime.register(host, shards: ["room-a"])
        }
        try await runtime.retireAfterDrain(.init(host: host), shards: ["room-a"])
        #expect(await log.load().revision == 3)
        #expect(await log.load().slots[0].retired)
        #expect(await log.commitCount == 2)
        // An exact replay returns the old committed registration snapshot,
        // which cannot restore admission over its later retirement.
        try await runtime.register(host, shards: ["room-a"])
        #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
            try runtime.grant(roomID: .init(uuid: UUID()), owner: .init(shardID: "room-a", epoch: 0))
        }
    }

    @Test("An empty duplicate Host cannot retire another application's active registration")
    func duplicateStartupCannotRetireForeignRegistration() async throws {
        let (host, _, log, runtime) = try fixture()
        try await runtime.register(host, shards: ["room-a"])
        let active = await log.load()
        let duplicate = try V2RoomActorPlacementRuntime(logs: ["room-a": log], snapshots: ["room-a": active])
        await #expect(throws: (any Error).self) { try await duplicate.register(host, shards: ["room-a"]) }
        try await duplicate.retireAfterDrain(.init(host: host), shards: ["room-a"])
        #expect(await log.load() == active)
        #expect(await log.commitCount == 1)
    }

    @Test("Late committed responses cannot restore withdrawn admission")
    func lateSnapshot() throws {
        let (_, initial, _, _) = try fixture()
        var machine = V2ActorPlacementStateMachine(snapshot: initial)
        let directory = V2ActorPlacementDirectory(snapshot: initial)
        let oldHost = initial.slots[0].owner.host
        let successor = V2ActorHostIdentity(hostID: oldHost.hostID, incarnationID: UUID())
        try machine.apply(.registerHost(previous: oldHost, successor: successor), revision: 2)
        let registered = machine.snapshot
        try machine.apply(.retireHost(successor), revision: 3)
        try directory.installCommitted(machine.snapshot)
        try directory.installCommittedUnlessOlder(registered)
        #expect(directory.snapshot() == machine.snapshot)
        #expect(directory.snapshot().slots[0].retired)
        let foreign = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1, slots: initial.slots)
        #expect(throws: V2ActorPlacementError.conflictingSnapshot) { try directory.installCommittedUnlessOlder(foreign) }
    }

    @Test("Ownership changes stop at the activation wire epoch limit")
    func boundedEpoch() throws {
        let (host, initial, _, _) = try fixture()
        let limit = V2RoomActorPlacementGrant.maximumEpoch
        let owner = V2ActorPlacementOwner(host: initial.slots[0].owner.host, epoch: limit)
        let reserved = try V2ActorPlacementSnapshot(clusterID: initial.clusterID, revision: 1,
            slots: [.init(owner: owner, transfer: nil, retired: true)])
        var registration = V2ActorPlacementStateMachine(snapshot: reserved)
        #expect(throws: V2ActorPlacementError.epochExhausted) {
            try registration.apply(.registerHost(previous: owner.host, successor: host), revision: 2)
        }
        #expect(registration.snapshot == reserved)
        let id = UUID()
        let target = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let pending = try V2ActorPlacementSnapshot(clusterID: initial.clusterID, revision: 1,
            slots: [.init(owner: owner, transfer: .init(id: id, successor: target))],
            hosts: [.init(host: owner.host, retired: false), .init(host: target, retired: false)])
        var transfer = V2ActorPlacementStateMachine(snapshot: pending)
        #expect(throws: V2ActorPlacementError.epochExhausted) {
            try transfer.apply(.completeTransfer(partition: 0, expected: owner, transferID: id), revision: 2)
        }
        #expect(transfer.snapshot == pending)
        #expect(throws: V2ActorPlacementError.invalidConfiguration) {
            try V2ActorPlacementSnapshot(clusterID: initial.clusterID, revision: 1,
                slots: [.init(owner: .init(host: host, epoch: limit + 1), transfer: nil)])
        }
    }
}

/// Fault injection for durable idempotency. SQL commit/rollback is tested
/// separately against a disposable PostgreSQL database.
private actor RuntimePlacementLog: V2ActorPlacementLog {
    private struct Key: Hashable { let id: UUID; let kind: Int }
    private var snapshot: V2ActorPlacementSnapshot
    private var records: [Key: (V2ActorPlacementCommand, V2ActorPlacementSnapshot)] = [:]
    private var loseResponse = false
    private var expireNext = false
    private(set) var commitCount = 0
    init(_ snapshot: V2ActorPlacementSnapshot) { self.snapshot = snapshot }
    func load() -> V2ActorPlacementSnapshot { snapshot }
    func loseNextResponse() { loseResponse = true }
    func expireNextSubmission() { expireNext = true }
    func append(_ command: V2ActorPlacementCommand, evidence: V2ActorPlacementCommandEvidence, expected: V2ActorPlacementSnapshot,
                requestID: UUID, originRevision: UInt64) throws -> V2ActorPlacementSnapshot {
        if expireNext { expireNext = false; throw V2ActorPlacementError.requestExpired }
        let key = Key(id: requestID, kind: command.logKind)
        if let prior = records[key] {
            guard prior.0 == command else { throw V2ActorPlacementError.invalidTransition }
            return prior.1
        }
        guard expected == snapshot else { throw V2ActorPlacementError.staleRevision }
        var machine = V2ActorPlacementStateMachine(snapshot: snapshot)
        try machine.apply(command, revision: snapshot.revision + 1)
        snapshot = machine.snapshot
        records[key] = (command, snapshot); commitCount += 1
        if loseResponse { loseResponse = false; throw V2ActorPlacementError.unavailable }
        return snapshot
    }
}
