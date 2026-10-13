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
    package func policySnapshots(_ request: V2PolicySnapshotRequestWire, deadline: ContinuousClock.Instant) async throws -> V2PolicySnapshotBatchWire {
        guard request.endpoint == endpoint else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        return try await V2RoomSQLDeadline.withDeadline(deadline) {
            let scopes = request.scopes.map(\.policyScope)
            let session = try await owners.registrationSession(scopes: scopes, subscriber: request.subscriber, interestRevision: request.interestRevision)
            let states = try await owners.registrationSnapshots(scopes: scopes, requestedAt: .now)
            try await owners.confirmRegistration(session, scopes: scopes, interestRevision: request.interestRevision)
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            return try .init(session: session, snapshots: states.map { try $0.wire }, interestRevision: request.interestRevision)
        }
    }
    package func releasePolicyInterests(_ request: V2PolicyInterestReleaseWire, deadline: ContinuousClock.Instant) async throws {
        guard request.endpoint == endpoint else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        try await owners.releaseInterests(request)
    }
    package func updatePolicySnapshot(_ request: V2PolicySnapshotUpdateWire, deadline: ContinuousClock.Instant) async throws {
        guard request.endpoint == endpoint, let cache else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        try await cache.applyControl(request)
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
