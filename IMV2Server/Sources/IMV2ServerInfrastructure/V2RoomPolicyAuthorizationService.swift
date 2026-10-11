import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ActorCluster
import IMV2Core

private func v2CurrentPolicySnapshot(
    sender: UUID, recipient: UUID?, recipientReplyConfirmed: Bool,
    cachedRead: @escaping @Sendable ([V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot]?,
    read: @escaping @Sendable ([V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot],
    metrics: V2SendOperationBatchMetrics?
) async throws -> V2CurrentRoomPolicySnapshot {
    let scopes: [V2PolicyAuthorizationScope] = recipient.map { [.account(sender), .account($0), .pair(sender, $0)] } ?? [.account(sender)]
    let states = try await v2MeasureSendOperationStage(.policyOwnerState, metrics: metrics) {
        let trace = V2SendPathTrace.current
        let probeStartedAt = ContinuousClock.now
        var states = try await v2MeasureSendOperationStage(.policyOwnerMemoryProbe, metrics: metrics) { try await cachedRead(scopes) }
        trace?.record("policy_cache_probe", from: probeStartedAt)
        trace?.mark(states == nil ? "policy_cache_miss" : "policy_cache_hit")
        metrics?.recordPolicyMemoryEvent(states == nil ? .snapshotProbeMiss : .snapshotProbeHit)
        if states == nil {
            let startedAt = ContinuousClock.now
            states = try await read(scopes)
            trace?.record("policy_missing_read", from: startedAt)
        }
        var result = states!
        if let recipient {
            guard let relationship = result.first(where: { $0.scope.key == V2PolicyAuthorizationScope.pair(sender, recipient).key }),
                  case .pair(let pair) = relationship.facts else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
            let ordinaryAccounts = result.filter { snapshot in
                guard case .account(let account) = snapshot.facts else { return false }
                return account.specialKind == nil
            }.count == 2
            if !pair.isFriend && !(recipientReplyConfirmed && ordinaryAccounts) {
                let stranger: [V2PolicyAuthorizationScope] = [.stranger(recipient)]
                let startedAt = ContinuousClock.now
                if let cached = try await cachedRead(stranger) {
                    trace?.mark("policy_stranger_hit")
                    result += cached
                } else {
                    trace?.mark("policy_stranger_miss")
                    result += try await read(stranger)
                }
                trace?.record("policy_stranger_read", from: startedAt)
            }
        }
        return result
    }
    if let recipient { return try .direct(pair: .init(sender: sender, recipient: recipient), snapshots: states, recipientReplyConfirmed: recipientReplyConfirmed) }
    return try .account(sender: sender, snapshots: states)
}

/// Composition capability: policy facts and executing permits stay private to
/// Infrastructure. Install only after policy routing and writers are cut over.
package final class V2RoomPolicyAuthorizationService: Sendable {
    private let directory: PostgresV2RoomPolicyAuthorizationDirectory

    init(directory: PostgresV2RoomPolicyAuthorizationDirectory) { self.directory = directory }

    package var endpoint: String { directory.endpoint }

    package convenience init(roomDatabase: any Database,
        policyOwners: PostgresV2RemotePolicyOwners, locator: V2RoomPolicyEndpointLocator, maximumRooms: Int,
        roomPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
        sendOperationMetrics: V2SendOperationBatchMetrics? = nil) {
        self.init(roomDatabase: roomDatabase, policyOwners: policyOwners,
            endpoint: locator.encoded, maximumRooms: maximumRooms,
            roomPreparationAdmission: roomPreparationAdmission, sendOperationMetrics: sendOperationMetrics)
    }

    package convenience init(roomDatabase: any Database,
        policyOwners: PostgresV2RemotePolicyOwners, endpoint: String, maximumRooms: Int,
        roomPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
        sendOperationMetrics: V2SendOperationBatchMetrics? = nil) {
        self.init(directory: .init(database: roomDatabase, endpoint: endpoint, maximumRooms: maximumRooms,
            databaseWorkAdmission: roomPreparationAdmission, currentLoader: { _, sender, recipient, replied in
                try await v2CurrentPolicySnapshot(sender: sender, recipient: recipient,
                    recipientReplyConfirmed: replied,
                    cachedRead: { try await policyOwners.cachedSnapshots(scopes: $0) },
                    read: { try await policyOwners.registrationSnapshots(scopes: $0) },
                    metrics: sendOperationMetrics)
            }))
    }

    package convenience init(roomDatabase: any Database,
        policyOwners: PostgresV2PolicyOwnerDirectory, endpoint: String, maximumRooms: Int,
        roomPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
        sendOperationMetrics: V2SendOperationBatchMetrics? = nil) {
        self.init(directory: .init(database: roomDatabase, endpoint: endpoint, maximumRooms: maximumRooms,
            databaseWorkAdmission: roomPreparationAdmission, currentLoader: { _, sender, recipient, replied in
                try await v2CurrentPolicySnapshot(sender: sender, recipient: recipient,
                    recipientReplyConfirmed: replied,
                    cachedRead: { try await policyOwners.cachedSnapshots(scopes: $0) },
                    read: { try await policyOwners.registrationSnapshots(scopes: $0) },
                    metrics: sendOperationMetrics)
            }))
    }

    package func prepareOwnerBatches(store: PostgresV2MessageSendOperationStore,
        requests: [V2MessageSendPreparationRequest],
        now: @escaping @Sendable () -> Date) async throws
        -> [Result<V2PreparedMessageSendBatch, any Error>] {
        try await store.prepareOwnerBatches(requests, policyDirectory: directory,
            now: now)
    }

    package func prepareOwnerPolicyInput(store: PostgresV2MessageSendOperationStore,
        input: V2OwnerMessageSendPreparationInput) async throws -> V2PreparedMessageSendBatch {
        try await store.prepareOwnerPolicyInput(input, policyDirectory: directory)
    }

    /// Only trusted forward workflows call this boundary. Their actual room
    /// transaction still validates source/inbox authority and exact command.
    func executeForward<Value: Sendable>(command: V2SendMessageCommand, token: V2RoomActivationToken,
        operation: @escaping @Sendable (V2RoomPolicyExecution) async throws -> Value) async throws -> Value {
        guard command.forwardedFrom != nil, let sender = command.senderUserID.uuidValue,
              command.roomID == token.roomID else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let registry = try await directory.registry(token: token)
        let runtime = try await registry.runtime(sender: sender, token: token)
        let preparation = try await runtime.prepareBatch(commands: [command],
            callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline(), trustedForward: true)
        return try await runtime.executePreparedBatch(preparation, operation: operation)
    }

    package func installRoomInitialization(_ initialization: V2RoomSendInitialization) async throws {
        try await directory.install(initialization)
    }

    package func retire(token: V2RoomActivationToken) async { await directory.retire(token: token) }
    package func shutdown() async { await directory.shutdown() }
}
