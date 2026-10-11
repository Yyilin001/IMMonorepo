import IMV2ActorContracts
import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts

/// Reconstructs post-commit propagation from durable commands, including work
/// recovered without the original HTTP caller. No authorization is granted here.
package struct PostgresV2PolicyCommittedEffectsPublisher: Sendable {
    private let journal: PostgresV2PolicyAuthorizationJournal
    private let delivery: any V2UserShardProjectionDelivering
    package init(journal: PostgresV2PolicyAuthorizationJournal, delivery: any V2UserShardProjectionDelivering) {
        self.journal = journal; self.delivery = delivery
    }
    package func publish(_ notification: V2PolicyCommitNotification) async throws {
        let change = try await journal.committedPublication(notification)
        let mutation = try JSONDecoder().decode(V2DurablePolicyMutation.self, from: Data(change.commandJSON.utf8))
        try mutation.validate()
        guard mutation.scope.key == change.scopeKey, mutation.operationKey == change.operationKey,
              try mutation.fingerprint == change.fingerprint, let receipt = change.receipt else {
            throw V2PolicyAuthorizationLifecycleError.corruptPersistence
        }
        let result = try JSONDecoder().decode(V2PolicyMutationResult.self, from: receipt)
        var requests: [V2UserShardProjectionDeliveryRequest] = []
        switch (mutation, result) {
        case (.social(let command), .social(let result)):
            if case .receipt(let receipt) = result, case .applied = receipt.outcome {
                let event = try EventID(command.identity.operation.rawOperationID)
                requests = [command.actorUserID, command.targetUserID].map {
                    .init(userID: $0, sourceEventID: event, projectionKinds: ["relationship", "user_block"])
                }
            }
        case (.strangerPreference(let command), .preference(let result)):
            if case .receipt(let receipt) = result, case .applied = receipt.outcome {
                requests = [.init(userID: command.identity.accountID,
                    sourceEventID: try EventID(command.identity.operation.rawOperationID), projectionKinds: ["stranger_message_permission"])]
            }
        case (.disable, .disable):
            // Device revocation events and profile outbox are atomically created
            // by the disable effect and consumed by their existing workers.
            break
        default: throw V2PolicyAuthorizationLifecycleError.corruptPersistence
        }
        if !requests.isEmpty {
            let acknowledgements = try await delivery.deliverToCurrentShard(requests)
            guard acknowledgements.count == requests.count, acknowledgements.allSatisfy({ ($0 ?? 0) > 0 }) else {
                throw V2PolicyAuthorizationLifecycleError.notDrained
            }
        }
    }
}
