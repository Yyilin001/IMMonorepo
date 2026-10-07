import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerApplication

/// Serves the node's assigned canonical scopes. Placement is supplied to the
/// directory; the durable journal remains the final epoch/version authority.
package struct V2PolicyOwnershipService: V2PolicyOwnershipServing {
    private let owners: PostgresV2PolicyOwnerDirectory
    private let cache: V2NodePolicyStateCache?
    private let endpoint: String
    package init(owners: PostgresV2PolicyOwnerDirectory, endpoint: String, cache: V2NodePolicyStateCache? = nil) {
        precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512)
        self.owners = owners; self.endpoint = endpoint; self.cache = cache
    }
    package func policySnapshots(_ request: V2PolicySnapshotRequestWire, deadline: ContinuousClock.Instant) async throws -> [V2PolicySnapshotWire] {
        guard request.endpoint == endpoint else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        return try await V2RoomSQLDeadline.withDeadline(deadline) {
            let states = try await owners.registrationSnapshots(scopes: request.scopes.map(\.policyScope), subscriber: request.subscriber, requestedAt: .now)
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            return try states.map { try $0.wire }
        }
    }
    package func updatePolicySnapshot(_ request: V2PolicySnapshotUpdateWire, deadline: ContinuousClock.Instant) async throws {
        guard request.endpoint == endpoint, let cache else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        try await cache.install(.init(wire: request.snapshot), interestedOnly: true)
    }
    package func invalidatePolicyCache(_ request: V2PolicyCacheInvalidationWire, deadline: ContinuousClock.Instant) async throws {
        guard request.endpoint == endpoint, let cache else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        await cache.invalidate(request.scope.key)
    }
    package func claimPolicyOwnership(_ request: V2PolicyOwnershipClaimWire,
        deadline: ContinuousClock.Instant) async throws -> [V2PolicyOwnerStateWire] {
        guard request.endpoint == endpoint else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let states: [V2PolicyOwnerState]
        do {
            if request.cachedOnly {
                guard let cached = try await owners.cachedRegistrationStates(scopes: request.scopes.map(\.policyScope)) else { return [] }
                states = cached
            } else {
                states = try await owners.registrationStates(scopes: request.scopes.map(\.policyScope),
                    minimumRemaining: request.refresh ? .seconds(10) : .zero)
            }
        }
        catch V2PolicyAuthorizationLifecycleError.busy {
            // No room message transaction is part of this state claim. A
            // capacity limit or pending policy seal is a temporary rejection,
            // not an unknown outcome of the caller's message operation.
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        guard deadline > .now else { throw V2RoomCallFailure.outcomeUnknown }
        return try states.map { state in
            let duration = ContinuousClock.now.duration(to: state.deadline).components
            let remaining = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            guard remaining > 0 else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
            let owner = try V2PolicyOwnerLeaseWire(scope: state.owner.scope.policyWire, ownerID: state.owner.ownerID,
                epoch: state.owner.epoch, revision: state.owner.revision, validUntil: state.owner.validUntil)
            return try .init(owner: owner, facts: JSONEncoder().encode(state.facts), remainingSeconds: remaining)
        }
    }
}

extension V2PolicyScopeWire {
    var policyScope: V2PolicyAuthorizationScope {
        switch kind { case .account: .account(first); case .stranger: .stranger(first); case .pair: .pair(first, second!) }
    }
}
extension V2PolicyAuthorizationScope {
    var policyWire: V2PolicyScopeWire {
        get throws {
            switch self {
            case .stranger(let user): .init(stranger: user)
            case .account(let user): .init(account: user)
            case .pair(let first, let second): try .init(pair: first, second)
            }
        }
    }
}
