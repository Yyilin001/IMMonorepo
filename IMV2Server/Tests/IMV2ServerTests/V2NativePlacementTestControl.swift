import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import NIOPosix
@testable import IMV2ServerInfrastructure

/// Business SQL tests use the same native durable quorum as the room runtime.
/// Only authenticated network transport is replaced by direct voter calls.
final class V2NativePlacementTestControl: Sendable {
    private let shardID: String
    private let log: V2PlacementRaftLeaderLog
    private let voters: [V2PlacementRaftVoter]
    private let stores: [V2PlacementRaftFileStorage]
    private let pool: NIOThreadPool
    private let directory: URL

    private init(shardID: String, log: V2PlacementRaftLeaderLog, voters: [V2PlacementRaftVoter],
                 stores: [V2PlacementRaftFileStorage], pool: NIOThreadPool, directory: URL) {
        self.shardID = shardID; self.log = log; self.voters = voters
        self.stores = stores; self.pool = pool; self.directory = directory
    }

    static func open(host: V2ActorHostIdentity, shardID: String) async throws -> V2NativePlacementTestControl {
        try await open(hosts: [host], initialHost: host, shardID: shardID)
    }

    static func open(hosts: [V2ActorHostIdentity], initialHost: V2ActorHostIdentity,
                     shardID: String, partitionOwners: [V2ActorHostIdentity]? = nil) async throws -> V2NativePlacementTestControl {
        let owners = partitionOwners ?? [initialHost]
        guard !hosts.isEmpty, hosts.count <= 64, hosts.contains(initialHost),
              Set(hosts.map(\.hostID)).count == hosts.count,
              !owners.isEmpty, owners.count <= 4096, owners.allSatisfy({ hosts.contains($0) }) else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-native-placement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let pool = NIOThreadPool(numberOfThreads: 2); pool.start()
        var stores: [V2PlacementRaftFileStorage] = [], voters: [V2PlacementRaftVoter] = []
        do {
            let ids = (0..<3).map { _ in V2ActorHostID(uuid: UUID()) }, roster = Set(ids)
            let unregistered = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let initial = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1, slots: owners.map { owner in
                .init(owner: .init(host: .init(hostID: owner.hostID,
                    incarnationID: unregistered), epoch: 1),
                    transfer: nil, retired: true)
            }, hosts: hosts.map { .init(host: .init(hostID: $0.hostID, incarnationID: unregistered), retired: true) })
            for (index, id) in ids.enumerated() {
                let store = try await V2PlacementRaftFileStorage.bootstrap(at: directory.appendingPathComponent("\(index).pb"),
                    initial: .init(groupID: initial.clusterID, voterID: id, voters: roster), pool: pool)
                stores.append(store)
                voters.append(try await .open(id: id, groupID: initial.clusterID, voters: roster, storage: store))
            }
            let request = try await voters[0].campaign()
            try await voters[0].receivedVote(voters[1].vote(request, from: ids[0]), from: ids[1])
            let transport = NativePlacementTestTransport(source: ids[0], voters: Dictionary(uniqueKeysWithValues: zip(ids, voters)))
            let log = try V2PlacementRaftLeaderLog(voter: voters[0], id: ids[0], groupID: initial.clusterID,
                voters: roster, transport: transport)
            _ = try await log.bootstrap(initial)
            return .init(shardID: shardID, log: log, voters: voters, stores: stores, pool: pool, directory: directory)
        } catch {
            for voter in voters { await voter.stop() }
            for store in stores { try? await store.close() }
            try? await pool.shutdownGracefully()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func register(_ identity: V2ActorHostIdentity, shard: String) async throws -> V2RoomActorPlacementRuntime {
        guard shard == shardID else { throw V2ActorPlacementError.invalidConfiguration }
        let runtime = try V2RoomActorPlacementRuntime(logs: [shard: log], snapshots: [shard: try await log.load()])
        try await runtime.register(identity, shards: [shard])
        return runtime
    }

    func snapshot() async throws -> V2ActorPlacementSnapshot {
        try await log.load()
    }

    /// Only the network boundary is direct in business integration fixtures.
    /// Both processes share this durable quorum and the production coordinator
    /// must wait for the old physical Host before publishing the successor.
    func transfer<Request: Sendable, Response: Sendable>(from host: V2RoomActivationHost<Request, Response>,
        placement: V2RoomActorPlacementRuntime, to successor: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws {
        let current = try await log.load()
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: .init(snapshot: current),
            authorizeSuccessor: { [log] identity in
                guard .now < deadline,
                      try await log.load().registration(for: identity.hostID) == .init(host: identity, retired: false) else {
                    throw V2ActorPlacementError.staleOwner
                }
            }, drain: { [shardID] snapshot, partition in
                try await placement.drainPlacement(snapshot, shard: shardID, partition: partition,
                    host: host, deadline: deadline)
            })
        _ = try await coordinator.transfer(partition: 0, expected: current.slots[0].owner,
            successor: successor, transferID: UUID())
        try await placement.refresh()
    }

    func close() async throws {
        for voter in voters { await voter.stop() }
        for store in stores { try await store.close() }
        try await pool.shutdownGracefully()
        try FileManager.default.removeItem(at: directory)
    }
}

private struct NativePlacementTestTransport: V2PlacementRaftTransport {
    let source: V2ActorHostID
    let voters: [V2ActorHostID: V2PlacementRaftVoter]
    func append(_ request: V2PlacementRaftAppendRequest, to peer: V2ActorHostID,
                deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftAppendReply {
        try Task.checkCancellation()
        guard .now < deadline, request.leader == source, let voter = voters[peer] else {
            throw V2ActorPlacementError.unavailable
        }
        return try await voter.append(request, from: source)
    }
    func snapshot(_ request: V2PlacementRaftSnapshotChunk, to peer: V2ActorHostID,
                  deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftSnapshotReply {
        try Task.checkCancellation()
        guard .now < deadline, request.leader == source, let voter = voters[peer] else {
            throw V2ActorPlacementError.unavailable
        }
        return try await voter.snapshot(request, from: source)
    }

}

func withNativePlacementTestControl<Value: Sendable>(host: V2ActorHostIdentity, shardID: String,
    _ body: (V2NativePlacementTestControl) async throws -> Value) async throws -> Value {
    try await withNativePlacementTestControl(hosts: [host], initialHost: host, shardID: shardID, body)
}

func withNativePlacementTestControl<Value: Sendable>(hosts: [V2ActorHostIdentity], initialHost: V2ActorHostIdentity,
    shardID: String, _ body: (V2NativePlacementTestControl) async throws -> Value) async throws -> Value {
    let control = try await V2NativePlacementTestControl.open(hosts: hosts, initialHost: initialHost, shardID: shardID)
    let value: Value
    do { value = try await body(control) }
    catch { try? await control.close(); throw error }
    try await control.close()
    return value
}
