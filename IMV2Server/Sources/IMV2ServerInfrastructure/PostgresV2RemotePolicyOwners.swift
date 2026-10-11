import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerApplication

/// Versioned snapshots load once and receive committed updates from their owners.
package struct PostgresV2RemotePolicyOwners: Sendable {
    package struct Route: Hashable, Sendable {
        package let host: V2ActorHostIdentity
        package let endpoint: String
        package init(host: V2ActorHostIdentity, endpoint: String) {
            precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512)
            self.host = host; self.endpoint = endpoint
        }
    }
    private let clientProvider: @Sendable () async throws -> V2RoomClusterClient
    private let resolve: @Sendable (String) async throws -> Route
    private let resolveBatch: (@Sendable ([String]) async throws -> [Route])?
    private let timeout: Duration
    private let stateCache: V2NodePolicyStateCache?
    private let localOwners: PostgresV2PolicyOwnerDirectory?
    private let subscriber: V2PolicySnapshotSubscriberWire?
    package init(clientProvider: @escaping @Sendable () async throws -> V2RoomClusterClient,
        timeout: Duration = .seconds(5), localOwners: PostgresV2PolicyOwnerDirectory? = nil, stateCache: V2NodePolicyStateCache? = nil,
        subscriber: V2PolicySnapshotSubscriberWire? = nil,
        resolveBatch: (@Sendable ([String]) async throws -> [Route])? = nil,
        resolve: @escaping @Sendable (String) async throws -> Route) {
        precondition(timeout > .zero && timeout <= .seconds(60))
        self.resolveBatch = resolveBatch
        self.subscriber = subscriber
        self.clientProvider = clientProvider; self.timeout = timeout; self.resolve = resolve
        self.stateCache = stateCache; self.localOwners = localOwners
    }

    package func cachedSnapshots(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot]? {
        if let stateCache { return try await stateCache.cachedSnapshots(scopes: scopes, requestedAt: .now) }
        if let localOwners, scopes.allSatisfy({ localOwners.acceptsScope($0.key) }) {
            return try await localOwners.cachedSnapshots(scopes: scopes)
        }
        return nil
    }
    package func registrationSnapshots(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot] {
        if let stateCache {
            return try await stateCache.loadSnapshots(scopes: scopes, requestedAt: .now) { try await self.fetchSnapshots(scopes: $0) }
        }
        return try await fetchSnapshots(scopes: scopes)
    }
    private func fetchSnapshots(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot] {
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.canonical)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let local = scopes.filter { localOwners?.acceptsScope($0.key) == true }
        let remote = scopes.filter { localOwners?.acceptsScope($0.key) != true }
        if remote.isEmpty, let localOwners { return try await localOwners.registrationSnapshots(scopes: local, requestedAt: .now) }
        let deadline = min(ContinuousClock.now + timeout, V2RoomSQLDeadline.current ?? ContinuousClock.now + timeout)
        let trace = V2SendPathTrace.current
        let clientStartedAt = ContinuousClock.now
        let client = try await clientProvider()
        trace?.record("policy_client_provider", from: clientStartedAt)
        guard let subscriber else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        var groups: [Route: [V2PolicyScopeWire]] = [:]
        let routeStartedAt = ContinuousClock.now
        if let resolveBatch {
            let routes = try await resolveBatch(remote.map(\.key))
            guard routes.count == remote.count else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
            for (scope, route) in zip(remote, routes) { groups[route, default: []].append(try scope.policyWire) }
        } else {
            for scope in remote { groups[try await resolve(scope.key), default: []].append(try scope.policyWire) }
        }
        trace?.record("policy_route_resolve", from: routeStartedAt)
        return try await withThrowingTaskGroup(of: [V2PolicyFactsSnapshot].self) { group in
            if !local.isEmpty, let localOwners {
                group.addTask {
                    let startedAt = ContinuousClock.now
                    defer { trace?.record("policy_local_owner_read", from: startedAt) }
                    return try await localOwners.registrationSnapshots(scopes: local, requestedAt: .now)
                }
            }
            for (route, scopes) in groups {
                group.addTask {
                    let startedAt = ContinuousClock.now
                    defer { trace?.record("policy_snapshot_rpc", from: startedAt) }
                    let request = try V2PolicySnapshotRequestWire(endpoint: route.endpoint, scopes: scopes, subscriber: subscriber)
                    return try await client.policySnapshots(request, on: route.host, deadline: deadline).map { try .init(wire: $0) }
                }
            }
            var states: [V2PolicyFactsSnapshot] = []
            for try await batch in group { states += batch }
            guard states.count == scopes.count, Set(states.map(\.scope)) == Set(scopes.map(\.canonical)) else {
                throw V2PolicyAuthorizationLifecycleError.invalidTarget
            }
            return states.sorted { $0.scope.key < $1.scope.key }
        }
    }

}
