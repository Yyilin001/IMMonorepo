import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ActorCluster
import IMV2Core

/// Friends have no stranger-setting dependency. Never load an extra scope
/// merely to make this memory-only probe succeed.
private func v2CachedDirectPolicyStates(pair: V2DirectSendControlPair,
    read: @Sendable ([V2PolicyAuthorizationScope]) async throws -> [V2PolicyOwnerState]?
) async throws -> [V2PolicyOwnerState]? {
    guard var states = try await read([.account(pair.sender), .account(pair.recipient),
        .pair(pair.sender, pair.recipient)]) else { return nil }
    guard let relationship = states.first(where: { $0.owner.scope.key == V2PolicyAuthorizationScope.pair(pair.sender, pair.recipient).key }),
          case .pair(let social) = relationship.facts else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
    if !social.isFriend {
        guard let settings = try await read([.stranger(pair.recipient)]) else { return nil }
        states += settings
    }
    return states
}

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
    package let usesMemorySendPreparation: Bool

    init(directory: PostgresV2RoomPolicyAuthorizationDirectory) { self.directory = directory; usesMemorySendPreparation = false }

    package var endpoint: String { directory.endpoint }

    package convenience init(roomDatabase: any Database, controlDatabase: any Database,
        policyOwners: PostgresV2RemotePolicyOwners, locator: V2RoomPolicyEndpointLocator, maximumRooms: Int,
        usesCurrentState: Bool = false,
        roomPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
        controlPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
        sendOperationMetrics: V2SendOperationBatchMetrics? = nil) {
        self.init(roomDatabase: roomDatabase, controlDatabase: controlDatabase,
            policyOwners: policyOwners, endpoint: locator.encoded, maximumRooms: maximumRooms,
            usesCurrentState: usesCurrentState, roomPreparationAdmission: roomPreparationAdmission,
            controlPreparationAdmission: controlPreparationAdmission, sendOperationMetrics: sendOperationMetrics)
    }

    package convenience init(roomDatabase: any Database, controlDatabase: any Database,
        policyOwners: PostgresV2PolicyOwnerDirectory, locator: V2RoomPolicyEndpointLocator, maximumRooms: Int,
        usesCurrentState: Bool = false,
        roomPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
        controlPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
        sendOperationMetrics: V2SendOperationBatchMetrics? = nil) {
        self.init(roomDatabase: roomDatabase, controlDatabase: controlDatabase,
            policyOwners: policyOwners, endpoint: locator.encoded, maximumRooms: maximumRooms,
            usesCurrentState: usesCurrentState, roomPreparationAdmission: roomPreparationAdmission,
            controlPreparationAdmission: controlPreparationAdmission, sendOperationMetrics: sendOperationMetrics)
    }

    package init(roomDatabase: any Database, controlDatabase: any Database,
                 policyOwners: PostgresV2PolicyOwnerDirectory, endpoint: String, maximumRooms: Int,
                 usesCurrentState: Bool = false,
        roomPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
        controlPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
                 sendOperationMetrics: V2SendOperationBatchMetrics? = nil) {
        usesMemorySendPreparation = usesCurrentState
        let currentLoader: (@Sendable (V2RoomActivationToken, UUID, UUID?, Bool) async throws -> V2CurrentRoomPolicySnapshot)?
        if usesCurrentState {
            currentLoader = { _, sender, recipient, replied in
                try await v2CurrentPolicySnapshot(sender: sender, recipient: recipient, recipientReplyConfirmed: replied,
                    cachedRead: { try await policyOwners.cachedSnapshots(scopes: $0) },
                    read: { try await policyOwners.registrationSnapshots(scopes: $0) },
                    metrics: sendOperationMetrics)
            }
        } else { currentLoader = nil }
        directory = .init(database: roomDatabase, endpoint: endpoint, maximumRooms: maximumRooms,
            databaseWorkAdmission: roomPreparationAdmission, currentLoader: currentLoader,
            loader: { token, pair, registration, activation in
                let states = try await v2MeasureSendOperationStage(.policyOwnerState, metrics: sendOperationMetrics) {
                    try await v2ReadPolicyState(
                        callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline(), cachedOperation: {
                            try await v2CachedDirectPolicyStates(pair: pair) {
                                try await policyOwners.cachedRegistrationStates(scopes: $0)
                            }
                        }) {
                        var states = try await policyOwners.registrationStates(scopes: [.account(pair.sender),
                            .account(pair.recipient), .pair(pair.sender, pair.recipient)])
                        guard let relationship = states.first(where: { $0.owner.scope.key == V2PolicyAuthorizationScope.pair(pair.sender, pair.recipient).key }),
                              case .pair(let social) = relationship.facts else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                        if !social.isFriend {
                            states += try await policyOwners.registrationStates(scopes: [.stranger(pair.recipient)])
                        }
                        return states
                    }
                }
                return try await v2WithAdmittedRoomDatabaseWork(controlPreparationAdmission, workClass: .sync,
                    callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline()) {
                    try await v2MeasureSendOperationStage(.policySnapshotRegistration, metrics: sendOperationMetrics) {
                        try await PostgresV2DirectPolicySnapshotStore(database: controlDatabase).register(
                            pair: pair, states: states, registrationID: registration, roomID: token.roomID.uuidValue!,
                            activationID: activation, roomOwnerEpoch: token.owner.epoch, endpoint: endpoint, durationSeconds: 20)
                    }
                }
            }, accountLoader: { token, sender, registration, activation in
                let states = try await v2MeasureSendOperationStage(.policyOwnerState, metrics: sendOperationMetrics) {
                    try await v2ReadPolicyState(
                        callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline(), cachedOperation: {
                            try await policyOwners.cachedRegistrationStates(scopes: [.account(sender)])
                        }) {
                        let states = try await policyOwners.registrationStates(scopes: [.account(sender)])
                        guard states.count == 1 else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                        return states
                    }
                }
                return try await v2WithAdmittedRoomDatabaseWork(controlPreparationAdmission, workClass: .sync,
                    callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline()) {
                    try await v2MeasureSendOperationStage(.policySnapshotRegistration, metrics: sendOperationMetrics) {
                        try await PostgresV2AccountPolicySnapshotStore(database: controlDatabase).register(
                            sender: sender, state: states[0], registrationID: registration, roomID: token.roomID.uuidValue!,
                            activationID: activation, roomOwnerEpoch: token.owner.epoch, endpoint: endpoint, durationSeconds: 20)
                    }
                }
            })
    }

    package init(roomDatabase: any Database, controlDatabase: any Database,
                 policyOwners: PostgresV2RemotePolicyOwners, endpoint: String, maximumRooms: Int,
                 usesCurrentState: Bool = false,
        roomPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
        controlPreparationAdmission: V2DatabaseWorkAdmissionController? = nil,
                 sendOperationMetrics: V2SendOperationBatchMetrics? = nil) {
        usesMemorySendPreparation = usesCurrentState
        let currentLoader: (@Sendable (V2RoomActivationToken, UUID, UUID?, Bool) async throws -> V2CurrentRoomPolicySnapshot)?
        if usesCurrentState {
            currentLoader = { _, sender, recipient, replied in
                try await v2CurrentPolicySnapshot(sender: sender, recipient: recipient, recipientReplyConfirmed: replied,
                    cachedRead: { try await policyOwners.cachedSnapshots(scopes: $0) },
                    read: { try await policyOwners.registrationSnapshots(scopes: $0) },
                    metrics: sendOperationMetrics)
            }
        } else { currentLoader = nil }
        directory = .init(database: roomDatabase, endpoint: endpoint, maximumRooms: maximumRooms,
            databaseWorkAdmission: roomPreparationAdmission, currentLoader: currentLoader,
            loader: { token, pair, registration, activation in
                let states = try await v2MeasureSendOperationStage(.policyOwnerState, metrics: sendOperationMetrics) {
                    try await v2ReadPolicyState(
                        callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline(), cachedOperation: {
                            try await v2CachedDirectPolicyStates(pair: pair) {
                                try await policyOwners.cachedRegistrationStates(scopes: $0)
                            }
                        }) {
                        var states = try await policyOwners.registrationStates(scopes: [.account(pair.sender),
                            .account(pair.recipient), .pair(pair.sender, pair.recipient)])
                        guard let relationship = states.first(where: { $0.owner.scope.key == V2PolicyAuthorizationScope.pair(pair.sender, pair.recipient).key }),
                              case .pair(let social) = relationship.facts else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                        if !social.isFriend {
                            states += try await policyOwners.registrationStates(scopes: [.stranger(pair.recipient)])
                        }
                        return states
                    }
                }
                return try await v2WithAdmittedRoomDatabaseWork(controlPreparationAdmission, workClass: .sync,
                    callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline()) {
                    try await v2MeasureSendOperationStage(.policySnapshotRegistration, metrics: sendOperationMetrics) {
                        try await PostgresV2DirectPolicySnapshotStore(database: controlDatabase).register(
                            pair: pair, states: states, registrationID: registration, roomID: token.roomID.uuidValue!,
                            activationID: activation, roomOwnerEpoch: token.owner.epoch, endpoint: endpoint, durationSeconds: 20)
                    }
                }
            }, accountLoader: { token, sender, registration, activation in
                let states = try await v2MeasureSendOperationStage(.policyOwnerState, metrics: sendOperationMetrics) {
                    try await v2ReadPolicyState(
                        callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline(), cachedOperation: {
                            try await policyOwners.cachedRegistrationStates(scopes: [.account(sender)])
                        }) {
                        let states = try await policyOwners.registrationStates(scopes: [.account(sender)])
                        guard states.count == 1 else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                        return states
                    }
                }
                return try await v2WithAdmittedRoomDatabaseWork(controlPreparationAdmission, workClass: .sync,
                    callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline()) {
                    try await v2MeasureSendOperationStage(.policySnapshotRegistration, metrics: sendOperationMetrics) {
                        try await PostgresV2AccountPolicySnapshotStore(database: controlDatabase).register(
                            sender: sender, state: states[0], registrationID: registration, roomID: token.roomID.uuidValue!,
                            activationID: activation, roomOwnerEpoch: token.owner.epoch, endpoint: endpoint, durationSeconds: 20)
                    }
                }
            })
    }

    package func prepareOwnerBatches(store: PostgresV2MessageSendOperationStore,
        requests: [V2MessageSendPreparationRequest],
        readAdmission: V2DatabaseWorkAdmissionController? = nil,
        now: @escaping @Sendable () -> Date) async throws
        -> [Result<V2PreparedMessageSendBatch, any Error>] {
        try await store.prepareOwnerBatches(requests, policyDirectory: directory,
            readAdmission: readAdmission, now: now)
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

    package func revoke(_ holder: V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof {
        try await directory.revoke(holder)
    }
    package func installRoomInitialization(_ initialization: V2RoomSendInitialization) async throws {
        try await directory.install(initialization)
    }

    package func retire(token: V2RoomActivationToken) async throws { try await directory.retire(token: token) }
    package func shutdown() async throws { try await directory.shutdown() }
}

/// A host may serve multiple physical room databases. Bind every route to its
/// actual directory at startup; never search other databases on an unknown ID.
package final class V2RoomPolicyRevocationRouter: V2RoomPolicyRevocationServing, Sendable {
    private let hostID: UUID
    private let services: [String: V2RoomPolicyAuthorizationService]

    package init(hostID: UUID, services: [String: V2RoomPolicyAuthorizationService]) throws {
        guard !services.isEmpty, services.count <= 256 else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        for (alias, service) in services {
            let locator = try V2RoomPolicyEndpointLocator(hostID: hostID, shardID: alias)
            guard locator.encoded == service.endpoint else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        }
        self.hostID = hostID; self.services = services
    }

    package func revokePolicyAuthorization(_ target: V2RoomPolicyRevocationWire,
        deadline: ContinuousClock.Instant) async throws -> V2RoomPolicyRevocationWire {
        let locator = try V2RoomPolicyEndpointLocator(encoded: target.endpoint)
        guard locator.hostID == hostID, let service = services[locator.shardID] else {
            throw V2RoomCallFailure.notAccepted(.forbidden)
        }
        return try await service.revokePolicyAuthorization(target, deadline: deadline)
    }
}

extension V2RoomPolicyAuthorizationService: V2RoomPolicyRevocationServing {
    package func revokePolicyAuthorization(_ target: V2RoomPolicyRevocationWire,
        deadline: ContinuousClock.Instant) async throws -> V2RoomPolicyRevocationWire {
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let holder = V2PolicyAuthorizationHolder(registrationID: target.registrationID, roomID: target.roomID.uuidValue!,
            activationID: target.activationID, roomOwnerEpoch: target.roomOwnerEpoch,
            generation: target.generation, endpoint: target.endpoint, validUntil: target.validUntil)
        return try await V2RoomSQLDeadline.withDeadline(deadline) {
            let proof = try await self.revoke(holder)
            guard proof.holder == holder else { throw V2RoomCallFailure.outcomeUnknown }
            // A late transaction may have succeeded; expiry is still no ACK.
            guard deadline > .now else { throw V2RoomCallFailure.outcomeUnknown }
            return target
        }
    }
}
