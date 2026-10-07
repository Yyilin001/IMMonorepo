import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerApplication

/// Mutation-only propagation. A successful mutation reply follows invalidation
/// on the configured nodes. The durable policy outbox retries interrupted work.
package struct V2PolicyCacheInvalidationPublisher: Sendable {
    package struct Target: Sendable {
        package let hostID: V2ActorHostID
        package let endpoint: String
        package init(hostID: V2ActorHostID, endpoint: String) { self.hostID = hostID; self.endpoint = endpoint }
    }
    private let targets: [Target]
    private let hostID: UUID
    private let cache: V2NodePolicyStateCache
    private let client: @Sendable () async throws -> V2RoomClusterClient
    package init(placement: V2PolicyOwnerPlacementConfiguration, hostID: UUID, cache: V2NodePolicyStateCache,
                 targets: [Target]? = nil, client: @escaping @Sendable () async throws -> V2RoomClusterClient) {
        self.targets = targets ?? placement.owners.map { .init(hostID: .init(uuid: $0.hostID), endpoint: $0.endpoint) }; self.hostID = hostID; self.cache = cache; self.client = client
    }
    package func invalidate(scopeKey: String) async throws {
        let parts = scopeKey.split(separator: ":")
        guard parts.count >= 2, let first = UUID(uuidString: String(parts[1])) else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        let scope: V2PolicyScopeWire
        switch parts[0] {
        case "account": scope = .init(account: first)
        case "stranger": scope = .init(stranger: first)
        case "pair":
            guard parts.count == 3, let second = UUID(uuidString: String(parts[2])) else {
                throw V2PolicyAuthorizationLifecycleError.invalidRequest
            }
            scope = try .init(pair: first, second)
        default: throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        guard scope.key == scopeKey else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        await cache.invalidate(scopeKey)
        let targets = self.targets.filter { $0.hostID != .init(uuid: hostID) }
        guard !targets.isEmpty else { return }
        let client = try await client(), deadline = ContinuousClock.now + .seconds(5)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let target = targets[index]
                group.addTask {
                    let host = try await client.resolvePolicyHost(hostID: target.hostID, endpoint: target.endpoint)
                    let request = try V2PolicyCacheInvalidationWire(endpoint: target.endpoint, scope: scope)
                    try await client.invalidatePolicyCache(request, on: host, deadline: deadline)
                }
            }
            while next < min(8, targets.count) { enqueue(next); next += 1 }
            while try await group.next() != nil {
                if next < targets.count { enqueue(next); next += 1 }
            }
        }
    }
}
