import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerApplication

package protocol V2PolicyMutationExecuting: Sendable {
    func changeExecution(_ mutation: V2DurablePolicyMutation) async throws -> (result: V2PolicyMutationResult, replayed: Bool)
}
extension V2PolicyMutationExecuting {
    package func change(_ mutation: V2DurablePolicyMutation) async throws -> V2PolicyMutationResult {
        try await changeExecution(mutation).result
    }
}
extension PostgresV2PolicyOwnerDirectory: V2PolicyMutationExecuting {}

/// Only privileged, authenticated server ingress may submit these commands.
/// Existing domain checks run inside the owner's final atomic transaction.
package struct V2PolicyMutationService: V2PolicyMutationServing {
    private let owners: PostgresV2PolicyOwnerDirectory
    private let endpoint: String
    package init(owners: PostgresV2PolicyOwnerDirectory, endpoint: String) {
        precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512)
        self.owners = owners; self.endpoint = endpoint
    }
    package func mutatePolicy(_ request: V2PolicyMutationWire, deadline: ContinuousClock.Instant) async throws -> V2PolicyMutationReceiptWire {
        guard request.endpoint == endpoint else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let mutation = try JSONDecoder().decode(V2DurablePolicyMutation.self, from: request.command)
        try mutation.validate()
        guard mutation.scope.key == request.scope.key, mutation.operationKey == request.operationKey,
              try mutation.fingerprint == request.fingerprint else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        let execution: (result: V2PolicyMutationResult, replayed: Bool)
        do { execution = try await owners.changeExecution(mutation) }
        catch V2PolicyAuthorizationLifecycleError.identityConflict { throw V2PolicyMutationServiceError.identityConflict }
        // A late reply cannot turn an unknown caller outcome into an ACK. The
        // durable operation remains replayable with its original identity.
        guard deadline > .now else { throw V2RoomCallFailure.outcomeUnknown }
        return try .init(scope: request.scope, operationKey: request.operationKey, fingerprint: request.fingerprint,
            receipt: JSONEncoder().encode(execution.result), replayed: execution.replayed)
    }
}

package struct PostgresV2RemotePolicyMutations: V2PolicyMutationExecuting {
    private let client: V2RoomClusterClient
    private let resolve: @Sendable (String) async throws -> PostgresV2RemotePolicyOwners.Route
    private let timeout: Duration
    package init(client: V2RoomClusterClient, timeout: Duration = .seconds(5),
        resolve: @escaping @Sendable (String) async throws -> PostgresV2RemotePolicyOwners.Route) {
        precondition(timeout > .zero && timeout <= .seconds(60))
        self.client = client; self.timeout = timeout; self.resolve = resolve
    }
    package func changeExecution(_ mutation: V2DurablePolicyMutation) async throws -> (result: V2PolicyMutationResult, replayed: Bool) {
        try mutation.validate()
        let deadline = ContinuousClock.now + timeout
        let route = try await resolve(mutation.scope.key)
        let request = try V2PolicyMutationWire(endpoint: route.endpoint, scope: mutation.scope.policyWire,
            operationKey: mutation.operationKey, fingerprint: mutation.fingerprint, command: Data(mutation.json.utf8))
        let receipt: V2PolicyMutationReceiptWire
        do { receipt = try await client.mutatePolicy(request, on: route.host, deadline: deadline) }
        catch V2PolicyMutationServiceError.identityConflict { throw V2PolicyAuthorizationLifecycleError.identityConflict }
        let result = try JSONDecoder().decode(V2PolicyMutationResult.self, from: receipt.receipt)
        switch (mutation, result) {
        case (.social, .social), (.strangerPreference, .preference), (.disable, .disable): break
        default: throw V2PolicyAuthorizationLifecycleError.corruptPersistence
        }
        return (result, receipt.replayed)
    }
}
