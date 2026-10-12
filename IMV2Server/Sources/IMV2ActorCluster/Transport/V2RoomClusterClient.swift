import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

public struct V2RoomClusterHostDescriptor: Sendable {
    public let identity: V2ActorHostIdentity
    public let endpointID: ClusterSystem.ActorID
    public let address: String
    public let port: Int
    public let accessibleShardIDs: Set<String>
    public let availableRooms: Int
    public let isHealthy: Bool

    public init(identity: V2ActorHostIdentity, endpointID: ClusterSystem.ActorID,
                address: String, port: Int, accessibleShardIDs: Set<String>,
                availableRooms: Int, isHealthy: Bool) throws {
        guard !address.isEmpty, (1...65_535).contains(port), !accessibleShardIDs.isEmpty,
              availableRooms >= 0 else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.identity = identity
        self.endpointID = endpointID
        self.address = address
        self.port = port
        self.accessibleShardIDs = accessibleShardIDs
        self.availableRooms = availableRooms
        self.isHealthy = isHealthy
    }
}

/// Immutable directory reads and synchronous Peer selection never enter a global RPC Actor.
public final class V2RoomClusterClient: V2RoomClientTransport, V2RoomHostDiscovering, Sendable {
    private let directory: V2RoomClusterDirectory
    private let control: V2RoomClusterDirectoryControl
    public let callerIncarnation: UUID

    public convenience init(system: ClusterSystem, signer: V2ActorSigningIdentity,
        trust: V2ActorTrustStore, limits: V2ActorAuthenticationLimits,
        configuration: V2RoomRuntimeConfiguration, callerIncarnation: UUID = UUID()) {
        self.init(system: system, signer: signer, trust: trust, limits: limits,
            configuration: configuration, callerIncarnation: callerIncarnation, localPort: nil)
    }
    init(system: ClusterSystem, signer: V2ActorSigningIdentity,
        trust: V2ActorTrustStore, limits: V2ActorAuthenticationLimits,
        configuration: V2RoomRuntimeConfiguration, callerIncarnation: UUID = UUID(),
        localPort: V2RoomLocalPort?) {
        self.callerIncarnation = callerIncarnation
        let directory = V2RoomClusterDirectory()
        self.directory = directory
        let budget = V2RoomClusterBudget(configuration: configuration, maximumSessions: limits.maximumSessions)
        let references = V2RoomClusterReferenceCache(capacity: configuration.maximumCachedLocations)
        self.control = V2RoomClusterDirectoryControl(directory: directory, maximumPeers: limits.maximumSessions,
            join: { system.cluster.join(host: $0.address, port: $0.port) }, factory: { hostID in
                V2RoomClusterPeer(system: system, signer: signer, trust: trust, limits: limits,
                    configuration: configuration, callerIncarnation: callerIncarnation,
                    localPort: localPort, stableHostID: hostID, budget: budget, references: references)
            })
    }
    public func register(_ descriptor: V2RoomClusterHostDescriptor) async throws {
        try await control.install(descriptor, join: true)
    }
    public func installDiscovered(_ descriptor: V2RoomClusterHostDescriptor) async throws {
        try await control.install(descriptor, join: false)
    }
    package func routingSnapshot() -> V2RoomClusterRoutingSnapshot { directory.routingSnapshot() }
    package func resolvePolicyHost(hostID: V2ActorHostID, endpoint: String) throws -> V2ActorHostIdentity {
        try routingSnapshot().resolvePolicyHost(hostID: hostID, endpoint: endpoint)
    }
    public func candidates(for owner: V2RoomDataOwner) async throws -> [V2RoomHostCandidate] {
        try routingSnapshot().candidates()
    }
    public func stop() async { await control.stop() }
    public func quiesce(deadline: ContinuousClock.Instant) async -> Bool {
        await stop()
        return await withTaskGroup(of: Bool.self) { group in
            for peer in directory.allPeers() { group.addTask { await peer.quiesce(deadline: deadline) } }
            var settled = true
            for await result in group { settled = result && settled }
            return settled
        }
    }
    public func retiredIdentityIsDrained(_ host: V2ActorHostIdentity) async -> Bool {
        guard let peer = directory.inspectionPeer(for: host.hostID) else { return true }
        return await peer.retiredIdentityIsDrained(host)
    }
    public func suspendUnreachableHost(_ host: V2ActorHostIdentity) async -> Bool {
        await control.suspend(host)
    }
    package func writePlacement(_ request: V2PlacementRaftWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftWire {
        try await directory.peer(for: host).writePlacement(request, on: host, deadline: deadline)
    }
    package func readPlacement(_ request: V2PlacementRaftWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftWire {
        try await directory.peer(for: host).readPlacement(request, on: host, deadline: deadline)
    }
    package func exchangeRaft(_ request: V2PlacementRaftWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftWire {
        let peer = try directory.peer(for: host)
        return try await peer.exchangeRaft(request, on: host, deadline: deadline)
    }
    package func drainPlacement(_ request: V2ActorPlacementDrainWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws -> V2ActorPlacementDrainReceipt {
        let peer = try directory.peer(for: host)
        return try await peer.drainPlacement(request, on: host, deadline: deadline)
    }

    package func forwardPair(_ pair: V2ActorForwardPairWire, token: V2RoomActivationToken,
        deadline: ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire {
        let peer = try directory.peer(for: token.host)
        return try await peer.forwardPair(pair, token: token, deadline: deadline)
    }

    package func mutatePolicy(_ mutation: V2PolicyMutationWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws -> V2PolicyMutationReceiptWire {
        let peer = try directory.peer(for: host)
        return try await peer.mutatePolicy(mutation, on: host, deadline: deadline)
    }

    package func policySnapshots(_ request: V2PolicySnapshotRequestWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws -> [V2PolicySnapshotWire] {
        let peer = try directory.peer(for: host)
        return try await peer.policySnapshots(request, on: host, deadline: deadline)
    }

    package func updatePolicySnapshot(_ request: V2PolicySnapshotUpdateWire, on host: V2ActorHostIdentity,
        deadline: ContinuousClock.Instant) async throws {
        let peer = try directory.peer(for: host)
        return try await peer.updatePolicySnapshot(request, on: host, deadline: deadline)
    }

    public func activate(on host: V2ActorHostIdentity, roomID: RoomID, owner: V2RoomDataOwner,
                         deadline: ContinuousClock.Instant) async throws -> V2RoomActivationResolution {
        let peer = try directory.peer(for: host)
        return try await peer.activate(on: host, roomID: roomID, owner: owner, deadline: deadline)
    }

    public func lookup(_ token: V2RoomActivationToken,
                       deadline: ContinuousClock.Instant) async throws -> Bool {
        let peer = try directory.peer(for: token.host)
        return try await peer.lookup(token, deadline: deadline)
    }

    public func canInvokeCachedLocally(_ token: V2RoomActivationToken) async -> Bool {
        guard let peer = try? directory.peer(for: token.host) else { return false }
        return await peer.canInvokeCachedLocally(token)
    }

    public func tryInvokeCached(_ token: V2RoomActivationToken, request: V2RoomRequest,
                                principal: V2RoomClientPrincipal,
                                deadline: ContinuousClock.Instant) async throws -> V2CachedRoomCallResult {
        let peer = try directory.peer(for: token.host)
        return try await peer.tryInvokeCached(token, request: request, principal: principal, deadline: deadline)
    }

    public func invoke(_ token: V2RoomActivationToken, request: V2RoomRequest,
                       principal: V2RoomClientPrincipal,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        let peer = try directory.peer(for: token.host)
        return try await peer.invoke(token, request: request, principal: principal, deadline: deadline)
    }

    public func renewRoom(_ command: V2RoomSubscriptionRenewCommand, token: V2RoomActivationToken,
                          deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        let peer = try directory.peer(for: token.host)
        return try await peer.renewRoom(command, token: token, deadline: deadline)
    }

    public func subscribeRoom(_ command: V2RoomSubscriptionSubscribeCommand, token: V2RoomActivationToken,
                              deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        let peer = try directory.peer(for: token.host)
        return try await peer.subscribeRoom(command, token: token, deadline: deadline)
    }

    public func activateRoomSubscription(_ command: V2RoomSubscriptionActivateCommand, token: V2RoomActivationToken,
                                         deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        let peer = try directory.peer(for: token.host)
        return try await peer.activateRoomSubscription(command, token: token, deadline: deadline)
    }

    public func resetRoomSubscription(_ command: V2RoomSubscriptionResetCommand, token: V2RoomActivationToken,
                                      deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        let peer = try directory.peer(for: token.host)
        return try await peer.resetRoomSubscription(command, token: token, deadline: deadline)
    }

    public func unsubscribeRoom(_ command: V2RoomSubscriptionUnsubscribeCommand, token: V2RoomActivationToken,
                                deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult {
        let peer = try directory.peer(for: token.host)
        return try await peer.unsubscribeRoom(command, token: token, deadline: deadline)
    }

    public func invokeCachedLocally(_ token: V2RoomActivationToken, request: V2RoomRequest,
                                    principal: V2RoomClientPrincipal,
                                    deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        let peer = try directory.peer(for: token.host)
        return try await peer.invokeCachedLocally(token, request: request, principal: principal, deadline: deadline)
    }

    public func reserve(_ token: V2RoomActivationToken, requestID: UUID,
                        deadline: ContinuousClock.Instant) async throws -> V2RoomReservation {
        let peer = try directory.peer(for: token.host)
        return try await peer.reserve(token, requestID: requestID, deadline: deadline)
    }

    public func markDispatched(_ grant: V2RoomReservation,
                               deadline: ContinuousClock.Instant) async throws {
        let peer = try directory.peer(for: grant.token.host)
        return try await peer.markDispatched(grant, deadline: deadline)
    }

    public func abort(_ grant: V2RoomReservation, deadline: ContinuousClock.Instant) async -> Bool {
        guard let peer = try? directory.peer(for: grant.token.host) else { return false }
        return await peer.abort(grant, deadline: deadline)
    }

    public func finish(_ grant: V2RoomReservation, completion: V2RoomReservationCompletion,
                       deadline: ContinuousClock.Instant) async -> Bool {
        guard let peer = try? directory.peer(for: grant.token.host) else { return false }
        return await peer.finish(grant, completion: completion, deadline: deadline)
    }

    public func renewRoomSubscriptions(on host: V2ActorHostIdentity,
        items: [V2RoomSubscriptionRenewBatchItem], deadline: ContinuousClock.Instant) async throws -> [V2RoomSubscriptionRenewBatchOutcome] {
        let peer = try directory.peer(for: host)
        return try await peer.renewRoomSubscriptions(on: host, items: items, deadline: deadline)
    }

    public func invokeRecoveryBatch(on host: V2ActorHostIdentity, items: [V2RoomRecoveryBatchCallItem],
                                    deadline: ContinuousClock.Instant) async throws -> [V2RoomRecoveryBatchCallOutcome] {
        let peer = try directory.peer(for: host)
        return try await peer.invokeRecoveryBatch(on: host, items: items, deadline: deadline)
    }

    public func sessionCount() async -> Int {
        var count = 0
        for peer in directory.allPeers() { count += await peer.sessionCount() }
        return count
    }
    public func handshakeWaiterSnapshot() async -> Int {
        var count = 0
        for peer in directory.allPeers() { count += await peer.handshakeWaiterSnapshot() }
        return count
    }
    public func physicalReferenceCount() async -> Int {
        var count = 0
        for peer in directory.allPeers() { count += await peer.physicalReferenceCount() }
        return count
    }
    public func retiredDescriptorCount() async -> Int {
        var count = 0
        for peer in directory.allPeers() { count += await peer.retiredDescriptorCount() }
        return count
    }
    public func dispatchedCallCount() async -> Int {
        var count = 0
        for peer in directory.allPeers() { count += await peer.dispatchedCallCount() }
        return count
    }
     func reservationSlotSnapshot() async -> Int {
        var count = 0
        for peer in directory.allPeers() { count += await peer.reservationSlotSnapshot() }
        return count
    }
    public func callMetricsSnapshot() async -> V2RoomTransportCallMetricsSnapshot {
        var snapshots: [V2RoomTransportCallMetricsSnapshot] = []
        for peer in directory.allPeers() { snapshots.append(await peer.callMetricsSnapshot()) }
        var stages: [V2RoomTransportRecoveryStage: V2RoomTransportRecoveryStageSnapshot] = [:]
        for stage in V2RoomTransportRecoveryStage.allCases {
            let parts = snapshots.compactMap { $0.recoveryStages[stage] }
            let active: Int = parts.reduce(0) { $0 + $1.active }
            let started: UInt64 = parts.reduce(0) { $0 &+ $1.started }
            let completed: UInt64 = parts.reduce(0) { $0 &+ $1.completed }
            let total: Double = parts.reduce(0) { $0 + $1.totalMilliseconds }
            let maximum: Double = parts.map(\.maxMilliseconds).max() ?? 0
            let oldest: Double = parts.map(\.oldestMilliseconds).max() ?? 0
            let items: UInt64 = parts.reduce(0) { $0 &+ $1.itemsStarted }
            stages[stage] = .init(active: active, started: started, completed: completed,
                totalMilliseconds: total, maxMilliseconds: maximum, oldestMilliseconds: oldest, itemsStarted: items)
        }
        var failures: [V2RoomRenewalFailureStage: UInt64] = [:]
        for snapshot in snapshots {
            for (key, count) in snapshot.renewalFailures { failures[key, default: 0] &+= count }
        }
        let cachedLocalCalls: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.cachedLocalCalls }
        let cachedRemoteCalls: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.cachedRemoteCalls }
        let roomLookups: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.roomLookups }
        let roomInvocations: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.roomInvocations }
        let referenceMisses: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.referenceMisses }
        let hostRecoveryProbes: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.hostRecoveryProbes }
        let hostRecoveryWaits: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.hostRecoveryWaits }
        let activeHostRecoveries: Int = snapshots.reduce(Int(0)) { $0 + $1.activeHostRecoveries }
        let batchCallerTimeouts: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.batchCallerTimeouts }
        let batchCallerCancellations: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.batchCallerCancellations }
        let batchRejectedGlobal: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.batchRejectedGlobal }
        let batchRejectedPeer: UInt64 = snapshots.reduce(UInt64(0)) { $0 &+ $1.batchRejectedPeer }
        let renewalActualCalls: Int = snapshots.reduce(Int(0)) { $0 + $1.renewalActualCalls }
        return V2RoomTransportCallMetricsSnapshot(
            cachedLocalCalls: cachedLocalCalls,
            cachedRemoteCalls: cachedRemoteCalls,
            roomLookups: roomLookups,
            roomInvocations: roomInvocations,
            referenceMisses: referenceMisses,
            hostRecoveryProbes: hostRecoveryProbes,
            hostRecoveryWaits: hostRecoveryWaits,
            activeHostRecoveries: activeHostRecoveries,
            recoveryStages: stages,
            batchCallerTimeouts: batchCallerTimeouts,
            batchCallerCancellations: batchCallerCancellations,
            batchRejectedGlobal: batchRejectedGlobal,
            batchRejectedPeer: batchRejectedPeer,
            renewalActualCalls: renewalActualCalls,
            renewalFailures: failures)
    }
    static func recoveryProbeDeadline(for deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant {
        V2RoomClusterPeer.recoveryProbeDeadline(for: deadline, now: now)
    }
    static func renewalBatches(_ items: [V2RoomSubscriptionRenewBatchItem],
        template: V2ActorAuthenticatedCall, maximumBytes: Int) throws -> [[V2RoomSubscriptionRenewBatchItem]] {
        try V2RoomClusterPeer.renewalBatches(items, template: template, maximumBytes: maximumBytes)
    }
}
