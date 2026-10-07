import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerApplication

/// Subscribe before fetching: every concurrent commit either appears in the
/// initial snapshot or reaches the subscriber as a versioned update.
package actor V2PolicySnapshotPublisher {
    private let targets: Set<V2PolicySnapshotSubscriberWire>
    private let localHostID: V2ActorHostID
    private let cache: V2NodePolicyStateCache
    private let client: @Sendable () async throws -> V2RoomClusterClient
    private var subscribers: [String: Set<V2PolicySnapshotSubscriberWire>] = [:]
    package init(targets: [V2PolicySnapshotSubscriberWire], localHostID: V2ActorHostID,
        cache: V2NodePolicyStateCache, client: @escaping @Sendable () async throws -> V2RoomClusterClient) {
        self.targets = Set(targets); self.localHostID = localHostID; self.cache = cache; self.client = client
    }
    package func subscribe(scopes: [V2PolicyAuthorizationScope], target: V2PolicySnapshotSubscriberWire) throws {
        guard targets.contains(target) else { throw V2RoomCallFailure.notAccepted(.forbidden) }
        for scope in scopes { subscribers[scope.key, default: []].insert(target) }
    }
    package func publish(_ snapshot: V2PolicyFactsSnapshot) async throws {
        try await cache.install(snapshot, interestedOnly: true)
        let targets = (subscribers[snapshot.scope.key] ?? []).filter { $0.hostID != localHostID }
        guard !targets.isEmpty else { return }
        let client = try await client(), wire = try snapshot.wire
        let deadline = ContinuousClock.now + .seconds(5)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    let host = try await client.resolvePolicyHost(hostID: target.hostID, endpoint: target.endpoint)
                    try await client.updatePolicySnapshot(.init(endpoint: target.endpoint, snapshot: wire), on: host, deadline: deadline)
                }
            }
            try await group.waitForAll()
        }
    }
}
