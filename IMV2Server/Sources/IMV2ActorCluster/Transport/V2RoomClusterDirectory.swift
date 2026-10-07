import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2ActorRuntime

/// Published values have no mutable session or RPC lifecycle state.
package struct V2RoomClusterRoutingSnapshot: Sendable {
    let accepting: Bool
    let descriptors: [V2ActorHostID: V2RoomClusterHostDescriptor]
    let suspended: Set<V2ActorHostIdentity>

    package func resolvePolicyHost(hostID: V2ActorHostID, endpoint: String) throws -> V2ActorHostIdentity {
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard let descriptor = descriptors[hostID], descriptor.isHealthy,
              descriptor.accessibleShardIDs.contains(endpoint), !suspended.contains(descriptor.identity) else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        return descriptor.identity
    }
    func candidates() throws -> [V2RoomHostCandidate] {
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        return descriptors.values.map {
            .init(identity: $0.identity, accessibleShardIDs: $0.accessibleShardIDs,
                availableRooms: $0.availableRooms,
                isHealthy: $0.isHealthy && !suspended.contains($0.identity))
        }
    }
}

/// Lock scopes only capture/publish values; never run callbacks or suspend.
final class V2RoomClusterDirectory: Sendable {
    private struct State: Sendable {
        var accepting = true
        var descriptors: [V2ActorHostID: V2RoomClusterHostDescriptor] = [:]
        var suspended: Set<V2ActorHostIdentity> = []
        var peers: [V2ActorHostID: V2RoomClusterPeer] = [:]
    }
    private let state = Mutex(State())
    func routingSnapshot() -> V2RoomClusterRoutingSnapshot {
        state.withLock { .init(accepting: $0.accepting, descriptors: $0.descriptors, suspended: $0.suspended) }
    }
    func peer(for host: V2ActorHostIdentity) throws -> V2RoomClusterPeer {
        try state.withLock {
            guard $0.accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
            guard let peer = $0.peers[host.hostID] else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            // Exact old identities are checked by the Peer, including pinned cleanup.
            return peer
        }
    }
    func inspectionPeer(for id: V2ActorHostID) -> V2RoomClusterPeer? { state.withLock { $0.peers[id] } }
    func allPeers() -> [V2RoomClusterPeer] { state.withLock { Array($0.peers.values) } }
    func publish(_ descriptor: V2RoomClusterHostDescriptor, peer: V2RoomClusterPeer, suspended: Bool) {
        state.withLock {
            guard $0.accepting else { return }
            $0.descriptors[descriptor.identity.hostID] = descriptor
            $0.peers[descriptor.identity.hostID] = peer
            $0.suspended = $0.suspended.filter { $0.hostID != descriptor.identity.hostID }
            if suspended { $0.suspended.insert(descriptor.identity) }
        }
    }
    func suspend(_ host: V2ActorHostIdentity) {
        state.withLock { if $0.descriptors[host.hostID]?.identity == host { $0.suspended.insert(host) } }
    }
    func close() { state.withLock { $0.accepting = false } }
}

/// Discovery updates are rare; serialize replacements per stable host while other hosts progress.
actor V2RoomClusterDirectoryControl {
    private let directory: V2RoomClusterDirectory
    private let maximumPeers: Int
    private let join: @Sendable (V2RoomClusterHostDescriptor) -> Void
    private let factory: @Sendable (V2ActorHostID) -> V2RoomClusterPeer
    private var accepting = true
    private var peers: [V2ActorHostID: V2RoomClusterPeer] = [:]
    private var updates: [V2ActorHostID: (UUID, Task<Void, any Error>)] = [:]
    init(directory: V2RoomClusterDirectory, maximumPeers: Int,
        join: @escaping @Sendable (V2RoomClusterHostDescriptor) -> Void,
        factory: @escaping @Sendable (V2ActorHostID) -> V2RoomClusterPeer) {
        self.directory = directory; self.maximumPeers = maximumPeers
        self.join = join; self.factory = factory
    }
    func install(_ descriptor: V2RoomClusterHostDescriptor, join shouldJoin: Bool) async throws {
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        let id = descriptor.identity.hostID
        let peer: V2RoomClusterPeer
        if let existing = peers[id] { peer = existing }
        else {
            guard peers.count < maximumPeers else { throw V2RoomCallFailure.notAccepted(.overloaded) }
            peer = factory(id); peers[id] = peer
        }
        let previous = updates[id]?.1, ticket = UUID()
        let task = Task {
            _ = await previous?.result
            try await peer.installPublished(descriptor, directory: directory)
        }
        updates[id] = (ticket, task)
        do { try await task.value }
        catch {
            if updates[id]?.0 == ticket { updates[id] = nil }
            throw error
        }
        guard accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        if updates[id]?.0 == ticket {
            updates[id] = nil
        }
        if shouldJoin { join(descriptor) }
    }
    func suspend(_ host: V2ActorHostIdentity) async -> Bool {
        directory.suspend(host)
        guard let peer = peers[host.hostID] else { return false }
        return await peer.suspendPublished(host, directory: directory)
    }
    func stop() async {
        accepting = false
        directory.close()
        let pending = updates.values.map { $0.1 }
        for task in pending { _ = await task.result }
        for peer in peers.values { await peer.stop() }
    }
}
