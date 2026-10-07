import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerApplication

/// Versioned snapshots load once and receive active updates. Lease-based
/// registration APIs below remain available only for legacy authorization.
package struct PostgresV2RemotePolicyOwners: Sendable {
    package struct Route: Hashable, Sendable {
        package let host: V2ActorHostIdentity
        package let endpoint: String
        package let ownerID: UUID
        package init(host: V2ActorHostIdentity, endpoint: String, ownerID: UUID) {
            precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512)
            self.host = host; self.endpoint = endpoint; self.ownerID = ownerID
        }
    }
    private let clientProvider: @Sendable () async throws -> V2RoomClusterClient
    private let resolve: @Sendable (String) async throws -> Route
    private let resolveBatch: (@Sendable ([String]) async throws -> [Route])?
    private let timeout: Duration
    private let probesRemoteMemory: Bool
    private let stateCache: V2NodePolicyStateCache?
    private let localOwners: PostgresV2PolicyOwnerDirectory?
    private let subscriber: V2PolicySnapshotSubscriberWire?
    package init(client: V2RoomClusterClient, timeout: Duration = .seconds(5), probesRemoteMemory: Bool = false,
        resolve: @escaping @Sendable (String) async throws -> Route) {
        precondition(timeout > .zero && timeout <= .seconds(60))
        self.clientProvider = { client }; self.timeout = timeout; self.resolve = resolve
        self.resolveBatch = nil
        self.stateCache = nil; self.localOwners = nil; self.subscriber = nil; self.probesRemoteMemory = probesRemoteMemory
    }

    package init(clientProvider: @escaping @Sendable () async throws -> V2RoomClusterClient,
        timeout: Duration = .seconds(5), probesRemoteMemory: Bool = false, localOwners: PostgresV2PolicyOwnerDirectory? = nil, stateCache: V2NodePolicyStateCache? = nil,
        subscriber: V2PolicySnapshotSubscriberWire? = nil,
        resolveBatch: (@Sendable ([String]) async throws -> [Route])? = nil,
        resolve: @escaping @Sendable (String) async throws -> Route) {
        precondition(timeout > .zero && timeout <= .seconds(60))
        self.resolveBatch = resolveBatch
        self.subscriber = subscriber
        self.clientProvider = clientProvider; self.timeout = timeout; self.resolve = resolve
        self.stateCache = stateCache; self.localOwners = localOwners; self.probesRemoteMemory = probesRemoteMemory
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
              Set(scopes.map(\.key)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
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
            guard states.count == scopes.count, Set(states.map { $0.scope.key }) == Set(scopes.map(\.key)) else {
                throw V2PolicyAuthorizationLifecycleError.invalidTarget
            }
            return states.sorted { $0.scope.key < $1.scope.key }
        }
    }

    package func registrationOwners(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyOwnerLease] {
        try await registrationStates(scopes: scopes).map(\.owner)
    }

    /// Locality is determined by the configured policy ownership mapping.
    /// Foreign scopes use authenticated cache-only RPC, without SQL or renewal.
    package func cachedRegistrationStates(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyOwnerState]? {
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.key)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        if let stateCache { return try await stateCache.cached(scopes: scopes) }
        if let localOwners, scopes.allSatisfy({ localOwners.acceptsScope($0.key) }) {
            return try await localOwners.cachedRegistrationStates(scopes: scopes)
        }
        guard probesRemoteMemory else { return nil }
        do { return try await fetchStates(scopes: scopes, cachedOnly: true) }
        catch V2PolicyAuthorizationLifecycleError.staleVersion {
            // Authority that expires in transit is a cache miss, not a grant.
            // The ordinary bounded path may renew it under the scope lock.
            return nil
        }
    }

    package func registrationStates(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyOwnerState] {
        if let stateCache {
            return try await stateCache.load(scopes: scopes) { scopes, refresh in
                try await self.loadUncached(scopes: scopes, refresh: refresh)
            }
        }
        return try await loadUncached(scopes: scopes)
    }

    package func loadUncached(scopes: [V2PolicyAuthorizationScope], refresh: Bool = false) async throws -> [V2PolicyOwnerState] {
        guard let states = try await fetchStates(scopes: scopes, cachedOnly: false, refresh: refresh) else {
            throw V2PolicyAuthorizationLifecycleError.invalidTarget
        }
        return states
    }

    private func fetchStates(scopes: [V2PolicyAuthorizationScope], cachedOnly: Bool, refresh: Bool = false) async throws -> [V2PolicyOwnerState]? {
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.key)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        // Same-host facts belong to the very same directory used by mutations.
        // Do not serialize them through a self RPC or require a cluster client
        // when every requested scope is local. Foreign scopes still use the
        // authenticated route; locality never follows room placement.
        let localScopes = scopes.filter { localOwners?.acceptsScope($0.key) == true }
        let remoteScopes = scopes.filter { localOwners?.acceptsScope($0.key) != true }
        if remoteScopes.isEmpty, let localOwners {
            if cachedOnly { return try await localOwners.cachedRegistrationStates(scopes: localScopes) }
            return try await localOwners.registrationStates(scopes: localScopes, minimumRemaining: refresh ? .seconds(10) : .zero)
        }
        let started = ContinuousClock.now
        let deadline = min(started + timeout, V2RoomSQLDeadline.current ?? started + timeout)
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let client = try await clientProvider()
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        var grouped: [Route: [V2PolicyScopeWire]] = [:]
        for scope in remoteScopes {
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let route = try await resolve(scope.key)
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            grouped[route, default: []].append(try scope.policyWire)
        }
        return try await withThrowingTaskGroup(of: [V2PolicyOwnerState]?.self) { group in
            if !localScopes.isEmpty, let localOwners {
                group.addTask {
                    if cachedOnly { return try await localOwners.cachedRegistrationStates(scopes: localScopes) }
                    return try await localOwners.registrationStates(scopes: localScopes, minimumRemaining: refresh ? .seconds(10) : .zero)
                }
            }
            for (route, scopes) in grouped {
                group.addTask {
                    let claim = try V2PolicyOwnershipClaimWire(endpoint: route.endpoint, scopes: scopes, cachedOnly: cachedOnly, refresh: refresh)
                    let states = try await client.claimPolicyStates(claim, on: route.host,
                        expectedOwnerID: route.ownerID, deadline: deadline)
                    if cachedOnly && states.isEmpty { return nil }
                    return try states.map { wire in
                        let lease = V2PolicyOwnerLease(scope: wire.owner.scope.policyScope, ownerID: wire.owner.ownerID,
                            epoch: wire.owner.epoch, revision: wire.owner.revision, validUntil: wire.owner.validUntil)
                        let facts = try JSONDecoder().decode(V2PolicyOwnerFacts.self, from: wire.facts)
                        switch (lease.scope, facts) {
                        case (.account(let user), .account(let account)) where user == account.userID: break
                        case (.stranger(let user), .stranger(let settings)) where user == settings.userID: break
                        case (.pair, .pair): break
                        default: throw V2PolicyAuthorizationLifecycleError.invalidTarget
                        }
                        // Resolver, handshake, request and response time all consume
                        // this deadline, including a reply from an owner's cache.
                        let stateDeadline = started + .seconds(wire.remainingSeconds)
                        guard stateDeadline > .now else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
                        return .init(owner: lease, facts: facts, deadline: stateDeadline)
                    }
                }
            }
            var leases: [V2PolicyOwnerState] = []
            var missed = false
            for try await batch in group {
                if let batch { leases.append(contentsOf: batch) } else { missed = true }
            }
            if missed { return nil }
            guard leases.count == scopes.count, Set(leases.map { $0.owner.scope.key }) == Set(scopes.map(\.key)) else {
                throw V2PolicyAuthorizationLifecycleError.invalidTarget
            }
            return leases.sorted { $0.owner.scope.key < $1.owner.scope.key }
        }
    }
}
