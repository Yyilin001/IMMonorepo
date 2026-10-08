import IMV2ServerInfrastructure
import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// 每个配置的物理所有者对应一个值。连接池句柄、额度缓存和批处理器
/// 在多个激活间共享，不按房间分配。
public struct V2RoomServerOwnerResources: Sendable, V2SendOperationOwnerMetricsReading {
    let sendDatabase: any Database
    let database: any Database
    /// Only restoration validation uses the lifecycle sublimit. Business
    /// handlers retain `database`, and both facades share the same physical gate.
    let activationValidationDatabase: any Database
    private(set) var writes: PostgresV2RoomWriteStore
    let mutations: PostgresV2MessageMutationOperationStore
    let identities: any V2MembershipIdentitySnapshotValidating
    let invitationSecretIssuer: V2GroupInviteSecretIssuer
    let invitationIdentities: any V2GroupInvitationIdentityReading
    let receipts: V2ActorRoomReceiptExecutor
    let receiptBatcher: V2HostRoomReceiptBatcher
    let queries: V2ActorRoomQueryExecutor
    let recovery: V2HostRoomRecoveryQueryBatcher
    let capacity: V2CapacityProfile
    let messageLimits: V2MessageCommandLimits
    let maximumEditBytes: Int
    let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    let committedMessageObserver: (any V2CommittedMessageBatchObserving)?
    public let sendOperationMetrics = V2SendOperationBatchMetrics()
    let combineOwnerSendPreflight: Bool
    let durableSendSchedulingConfiguration: V2SendOperationSchedulingConfiguration
    fileprivate let durableOwner = V2RoomDurableOwnerHolder()
    fileprivate let subscriptionHost: V2RoomSubscriptionHost
    fileprivate let committedFacts: V2RoomCommittedFactsFeed
    fileprivate var policyAuthorizations: V2RoomPolicyAuthorizationService?

    /// Bind before the physical-owner factory is installed. Production cutover
    /// also requires the account/pair writers and revocation transport.
    package func usingPolicyAuthorizations(_ service: V2RoomPolicyAuthorizationService) throws -> Self {
        guard durableOwner.current == nil else {
            throw V2ActorContractError.invalidConfiguration("policy authorization factory already bound")
        }
        var copy = self
        copy.policyAuthorizations = service
        copy.writes = writes.usingPolicyAuthorizations(service)
        return copy
    }

    public init(database: any Database, sendDatabase: (any Database)? = nil, writes: PostgresV2RoomWriteStore,
                membershipIdentities: any V2MembershipIdentitySnapshotValidating,
                invitationIdentities: any V2GroupInvitationIdentityReading,
                invitationSecretIssuer: V2GroupInviteSecretIssuer,
                receiptProjectionDelivery: any V2UserShardProjectionDelivering,
                capacityProfile: V2CapacityProfile, messageLimits: V2MessageCommandLimits,
                maximumEditBytes: Int, contentReviewMode: V2ContentReviewMode,
                queryBatchConfiguration: V2HostRoomRecoveryQueryBatcher.Configuration,
                receiptBatchConfiguration: V2ReadReceiptBatcher.Configuration = .init(
                    maximumBatchSize: 64, maximumDelay: .milliseconds(2),
                    maximumInFlightBatches: 4, maximumPendingRequests: 256),
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
                committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil,
                combineOwnerSendPreflight: Bool = false,
                maximumActiveRooms: Int = 8192,
                maximumRoomSubscriptionBindings: Int = 8192,
                durableSendSchedulingConfiguration: V2SendOperationSchedulingConfiguration = .init()) throws {
        guard maximumEditBytes > 0, maximumActiveRooms > 0, maximumRoomSubscriptionBindings > 0 else {
            throw V2ActorContractError.invalidConfiguration("room edit bytes")
        }
        let dirtyHeads = try PostgresV2RoomSubscriptionDirtyHeadStore(database: database, databaseWorkAdmission: databaseWorkAdmission)
        let host = V2RoomSubscriptionHost(maximumRooms: maximumActiveRooms,
            maximumBindings: maximumRoomSubscriptionBindings, dirtyChanges: { host, cursor, limit, deadline in
            try await dirtyHeads.pending(host: host, after: cursor, limit: limit, deadline: deadline)
        }, dirtyAcknowledge: { heads, deadline in
            try await dirtyHeads.acknowledge(heads, deadline: deadline)
        })
        let facts = V2RoomCommittedFactsFeed(downstream: committedMessageObserver,
            notify: { host.signal(room: $0) }, maximumRooms: maximumActiveRooms)
        self.subscriptionHost = host; self.committedFacts = facts
        host.install(feed: facts)
        // Opt in only when writes and database share the physical owner.
        self.combineOwnerSendPreflight = combineOwnerSendPreflight
        self.durableSendSchedulingConfiguration = durableSendSchedulingConfiguration
        self.database = database
        self.sendDatabase = sendDatabase ?? database
        self.activationValidationDatabase = (database as? V2EventLoopBalancedDatabase)?
            .usingLoanClass(.activation) ?? database
        self.mutations = .init(database:database,contentReviewMode:contentReviewMode,identities:membershipIdentities,committedMessageObserver:facts)
        self.writes = writes
        self.identities = membershipIdentities
        self.invitationSecretIssuer = invitationSecretIssuer
        self.invitationIdentities = invitationIdentities
        let receipts = V2ActorRoomReceiptExecutor(database: database, projectionDelivery: receiptProjectionDelivery)
        self.receipts = receipts
        self.receiptBatcher = .init(executor: receipts,
            configuration: receiptBatchConfiguration,
            databaseWorkAdmission: databaseWorkAdmission)
        let queries = V2ActorRoomQueryExecutor(database: database)
        self.queries = queries
        self.recovery = .init(executor: queries, configuration: queryBatchConfiguration,
            databaseWorkAdmission: databaseWorkAdmission,
            sqlContinuationMetrics: sendOperationMetrics)
        self.capacity = capacityProfile
        self.messageLimits = messageLimits
        self.maximumEditBytes = maximumEditBytes
        self.databaseWorkAdmission = databaseWorkAdmission
        self.committedMessageObserver = facts
    }

    public func recoveryBatchPressureSnapshot() -> V2RoomRecoveryBatchPressureSnapshot {
        recovery.pressureSnapshot()
    }

    public func shutdownRoomSubscriptionDelivery() async {
        await subscriptionHost.close()
    }

    public func shutdownRoomReadQueries() async {
        await recovery.shutdown()
    }

    public func sendOperationOwnerMetricsSnapshot() async -> V2SendOperationOwnerMetricsSnapshot {
        guard let context = durableOwner.current else { return .init() }
        return await context.batcher.sendOperationOwnerMetricsSnapshot()
    }

    /// Room lifecycle drains preparation; the dispatcher drains writes before SQL pools close.
    public func shutdownDurableSendOperations() async {
        if let context = durableOwner.current {
            await context.batcher.shutdown()
        }
        try? await policyAuthorizations?.shutdown()
    }
}

private struct V2RoomDurableOwnerContext: Sendable {
    let store: PostgresV2MessageSendOperationStore
    let batcher: V2DurableSendOperationOwnerBatcher
    let directPreparation: V2RoomSendPreparation
}

/// Value copies for logical shards retain this single physical-owner identity.
/// A factory binds its injected clock exactly once; a second factory cannot
/// silently reuse a store carrying a different clock or preparation witness.
private final class V2RoomDurableOwnerHolder: Sendable {
    let id = UUID()
    private let context = Mutex<V2RoomDurableOwnerContext?>(nil)
    var current: V2RoomDurableOwnerContext? { context.withLock { $0 } }

    func install(_ make: () throws -> V2RoomDurableOwnerContext) throws {
        try context.withLock {
            guard $0 == nil else {
                throw V2ActorContractError.invalidConfiguration("durable owner factory already bound")
            }
            $0 = try make()
        }
    }
}

/// Server 持有具体的领域处理器；Runtime 负责调度与生命周期，
/// Cluster 负责认证与传输。后两者都不导入 Server。
public struct V2RoomServerActivationFactory: Sendable {
    private let owners: [String: V2RoomServerOwnerResources]
    private let safetyActorUserID: UserID?
    private let now: @Sendable () -> Date

    /// Optional commit-observer bridge for durable writes outside execute().
    /// Invoke only after the transaction settles; this merely coalesces a room
    /// read. A future committed-facts feed can replace the read without changing
    /// the transport or subscription authority boundary.
    public func notifyCommittedRoomChange(token: V2RoomActivationToken) {
        owners[token.owner.shardID]?.subscriptionHost.signal(room: token.roomID)
    }

    public func configureRoomSubscriptionDelivery(sendBatch: @escaping V2RoomSubscriptionDeliveryPump.SendBatch, maximumCalls: Int) async throws {
        guard maximumCalls > 0 else { throw V2ActorContractError.invalidConfiguration("subscription calls") }
        var seen: Set<UUID> = []
        for resource in owners.values where seen.insert(resource.durableOwner.id).inserted {
            try await resource.subscriptionHost.configure(sendBatch: sendBatch, maximumCalls: maximumCalls)
        }
    }
    public func configureRoomSubscriptionDelivery(send: @escaping V2RoomSubscriptionDeliveryPump.Send) async throws {
        try await configureRoomSubscriptionDelivery(sendBatch: { batch, shard, gateway in
            var receipts: [V2RoomSubscriptionBatchReceipt] = []
            for delivery in batch.deliveries {
                receipts.append(.init(fence: delivery.fence, result: try await send(delivery, shard, gateway)))
            }
            return .init(receipts: receipts)
        }, maximumCalls: 4)
    }
    public func shutdownRoomSubscriptionDelivery() async {
        var seen: Set<UUID> = []
        for resource in owners.values where seen.insert(resource.durableOwner.id).inserted {
            await resource.shutdownRoomSubscriptionDelivery()
        }
    }

    public init(owners: [String: V2RoomServerOwnerResources], safetyActorUserID: UserID?,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !owners.isEmpty else { throw V2ActorContractError.invalidConfiguration("room owner resources") }
        for key in owners.keys { _ = try V2RoomDataOwner(shardID: key, epoch: 0) }
        for aliases in Dictionary(grouping: owners.values, by: { $0.durableOwner.id }).values {
            let service = aliases.first!.policyAuthorizations
            guard aliases.allSatisfy({ $0.policyAuthorizations === service }) else {
                throw V2ActorContractError.invalidConfiguration("physical owner policy authorization aliases")
            }
        }
        var installed: Set<UUID> = []
        for resources in owners.values where installed.insert(resources.durableOwner.id).inserted {
            try resources.durableOwner.install {
                let limit = resources.durableSendSchedulingConfiguration.maximumPendingRequests
                    .multipliedReportingOverflow(by: resources.messageLimits.maxUTF8Bytes)
                guard !limit.overflow, limit.partialValue > 0 else {
                    throw V2ActorContractError.invalidConfiguration("durable owner pending bytes")
                }
                let store = PostgresV2MessageSendOperationStore(database: resources.sendDatabase,
                    writes: resources.writes, clock: now,
                    committedMessageObserver: resources.committedMessageObserver,
                    sendOperationMetrics: resources.sendOperationMetrics,
                    combineOwnerPreflight: resources.combineOwnerSendPreflight,
                    initializationDatabase: resources.database)
                let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                    capacityProfile: resources.capacity, now: now,
                    configuration: resources.durableSendSchedulingConfiguration,
                    maximumRetainedBytes: limit.partialValue)
                let directPreparation: V2RoomSendPreparation
                if let policies = resources.policyAuthorizations {
                    directPreparation = { commands, token, deadline in
                        try await policies.prepareOwnerBatches(store: store,
                            requests: [.init(commands: commands, token: token, deadline: deadline)],
                            readAdmission: nil,
                            now: now)[0].get()
                    }
                } else {
                    directPreparation = { commands, token, deadline in
                        try await store.prepareSendBatch(commands, token: token, deadline: deadline, now: now)
                    }
                }
                return .init(store: store, batcher: batcher, directPreparation: directPreparation)
            }
        }
        self.owners = owners
        self.safetyActorUserID = safetyActorUserID
        self.now = now
    }

    /// Every physical owner must participate in the same authorization mode.
    package var usesPolicyAuthorizations: Bool {
        !owners.isEmpty && owners.values.allSatisfy { $0.policyAuthorizations != nil }
    }

    /// Recorders are aggregated at the Gateway. Physical lease aliases select
    /// one existing owner recorder, so each actual lifecycle SQL is counted once.
    public var sqlContinuationMetricsByOwner: [String: V2SendOperationBatchMetrics] {
        owners.mapValues(\.sendOperationMetrics)
    }

    public func runtimeFactory(
        validation: (@Sendable (V2RoomActivationToken) async throws -> Void)? = nil
    ) -> V2RoomActivationFactory<V2RoomRequest, V2RoomResponse> {
        .init(recoveryBatch: { items in
            guard let first = items.first, let resources = owners[first.token.owner.shardID],
                  items.allSatisfy({ $0.token.owner == first.token.owner && $0.query.kind == .state }) else {
                return .rolledBack(.invalidRequest)
            }
            let deadline = items.map(\.deadline).min()!
            let turns = items.map {
                V2GrantedRoomReadTurn(token: $0.token, actorUserID: $0.query.actorUserID,
                    batchDeadline: deadline, callDeadline: $0.deadline)
            }
            do {
                let values = try await V2RoomSQLContinuationObservation.$metrics.withValue(resources.sendOperationMetrics) {
                    try await resources.recovery.states(turns)
                }
                let outputs = items.map { item -> V2RoomRecoveryBatchCallOutcome in
                    let key = V2RoomStateReadKey(roomID: item.query.roomID, viewerUserID: item.query.actorUserID)
                    guard let result = values[key] else {
                        return .init(token: item.token, query: item.query, outcome: .failure(.outcomeUnknown))
                    }
                    switch result {
                    case .success(let value):
                        return .init(token: item.token, query: item.query,
                            outcome: .result(.recovery(.state(.init(value)))))
                    case .failure(let error):
                        let classified: V2RoomTransactionCompletion<Void> = v2RoomDomainCompletion(error)
                        let failure: V2RoomCallFailure
                        switch classified {
                        case .rolledBack(let reason): failure = .rolledBack(reason)
                        default: failure = .outcomeUnknown
                        }
                        return .init(token: item.token, query: item.query, outcome: .failure(failure))
                    }
                }
                return .committed(outputs)
            } catch { return v2RoomDomainCompletion(error) }
        }, pureRoomLogPull: { token, request, deadline in
            guard case .roomLog(.pull(let query)) = request,
                  query.roomID == token.roomID, let resources = owners[token.owner.shardID] else {
                return .rolledBack(.invalidRequest)
            }
            do {
                return try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await V2RoomSQLContinuationObservation.$metrics.withValue(resources.sendOperationMetrics) {
                        do {
                            return .committed(.roomLog(try await resources.recovery.pull(.init(
                                token: token, query: query, callDeadline: deadline))))
                        } catch let error as V2GroupEventLogError {
                            return .committed(.roomLog(.failure(.init(error))))
                        }
                    }
                }
            } catch { return v2RoomDomainCompletion(error) }
        }, pureSubscriptionRenew: { token, request, deadline, validUntil in
            guard case .roomSubscription(.renew(let command)) = request,
                  command.roomID == token.roomID, let resources = owners[token.owner.shardID] else {
                return .rolledBack(.invalidRequest)
            }
            do {
                try V2RoomSubscriptionCommand.renew(command).validate()
                let renewal = try await resources.subscriptionHost.renew(command: command, token: token,
                    activationValidUntil: validUntil, deadline: deadline)
                return .committed(.roomSubscription(.renewed(renewal)))
            } catch {
                if let failure = error as? V2RoomSubscriptionOwnerError {
                    switch failure {
                    case .busy: V2RoomSubscriptionOwnerFailureMetrics.shared.record(.busy)
                    case .catchUpRequired:
                        V2RoomSubscriptionOwnerFailureMetrics.shared.record(.catchUpRequired)
                        resources.subscriptionHost.signal(room: token.roomID)
                        return .committed(.roomSubscription(.failure(.unavailable)))
                    case .overloaded: V2RoomSubscriptionOwnerFailureMetrics.shared.record(.overloaded)
                    default: break
                    }
                }
                do { return .committed(.roomSubscription(.failure(try v2RoomSubscriptionFailure(for: error)))) }
                catch { return v2RoomDomainCompletion(error) }
            }
        }) { token in
            let instance = V2RoomServerActivation(token: token, resources: owners[token.owner.shardID],
                safetyActorUserID: safetyActorUserID, now: now, validation: validation)
            let recorder = owners[token.owner.shardID]?.sendOperationMetrics
            return .init(restore: { deadline in
                try await V2RoomSQLContinuationObservation.$metrics.withValue(recorder) {
                    try await instance.restore(deadline: deadline)
                }
            }, execute: { turn in
                await V2RoomSQLContinuationObservation.$metrics.withValue(recorder) {
                    await instance.execute(turn)
                }
            },
                invalidateReservation: { await instance.invalidate($0) },
                close: { await instance.close() })
        }
    }
}

/// 此处不将成员关系、策略、内容或游标快照当作永久权限依据。
/// 恢复会重建处理器并校验持久化房间；
/// 每项操作都在自身激活围栏下读取当前事实。
private actor V2RoomServerActivation {
    private let token: V2RoomActivationToken
    private let resources: V2RoomServerOwnerResources?
    private let safetyActorUserID: UserID?
    private let now: @Sendable () -> Date
    private let validation: (@Sendable (V2RoomActivationToken) async throws -> Void)?
    private var subscriptionOwner: V2RoomSubscriptionOwner?
    private var restoringSubscription = false
    private var subscriptionRestoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var handlers: Handlers?
    private var closed = false

    init(token: V2RoomActivationToken, resources: V2RoomServerOwnerResources?,
         safetyActorUserID: UserID?, now: @escaping @Sendable () -> Date,
         validation: (@Sendable (V2RoomActivationToken) async throws -> Void)?) {
        self.token = token
        self.resources = resources
        self.safetyActorUserID = safetyActorUserID
        self.now = now
        self.validation = validation
    }

    func restore(deadline: ContinuousClock.Instant) async throws {
        guard !closed, handlers == nil, let resources else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let created = try Handlers(token: token, resources: resources, now: now)
        let token = self.token
        let validation = self.validation
        let initialization: V2RoomSendInitialization? = try await V2RoomSQLDeadline.withDeadline(deadline) {
            if let validation { try await validation(token) }
            if resources.policyAuthorizations?.usesMemorySendPreparation == true {
                return try await v2RestoreRoomSendInitialization(database: resources.activationValidationDatabase,
                    token: token, validateActivation: validation == nil)
            }
            if validation == nil {
                try await v2ValidateRoomActivation(database: resources.activationValidationDatabase, token: token)
            }
            return nil
        }
        guard !closed, ContinuousClock.now < deadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        if let initialization {
            try await resources.policyAuthorizations?.installRoomInitialization(initialization)
            await resources.durableOwner.current?.store.installSendInitialization(initialization)
            guard !closed, ContinuousClock.now < deadline else {
                await resources.durableOwner.current?.store.invalidateSendState(token: token)
                try? await resources.policyAuthorizations?.retire(token: token)
                throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
            }
        }
        handlers = created
    }

    func execute(_ turn: V2RoomTurn<V2RoomRequest>) async -> V2RoomTransactionCompletion<[V2RoomResponse]> {
        V2SendPathTrace.current?.mark("turn_executor_enter")
        defer { V2SendPathTrace.current?.mark("turn_executor_return") }
        guard !closed, let handlers, let resources else { return .rolledBack(.notReady) }
        guard turn.context.token == token, !turn.items.isEmpty,
              turn.items.allSatisfy({ $0.request.roomID == token.roomID }),
              zip(turn.items, turn.items.dropFirst()).allSatisfy({ pair in pair.0.ordinal < pair.1.ordinal }) else {
            return .rolledBack(.invalidRequest)
        }
        // 资料读取只合并已逐请求准入的连续信封，不混入发送或其他屏障。
        let profileCounts = turn.items.compactMap { $0.request.profileVisibilityTargetCount }
        let isProfileTurn = profileCounts.count == turn.items.count
            && profileCounts.reduce(0, +) <= 100
        let isOperationSendTurn = turn.items.allSatisfy({
            if case .messaging(.sendOperation(_)) = $0.request { return true }; return false
        })
        guard turn.items.count == 1 || isProfileTurn || isOperationSendTurn || turn.items.allSatisfy({ $0.request.canShareSendTurn }) else {
            return .rolledBack(.invalidRequest)
        }
        guard turn.items.allSatisfy({ ContinuousClock.now < $0.deadline }) else {
            return .rolledBack(.deadlineExceeded)
        }
        let callDeadline = turn.items.map(\.deadline).min()!
        let operationStartedAt: ContinuousClock.Instant? = isOperationSendTurn ? .now : nil
        var operationOutcome: V2SendOperationBatchMetrics.Outcome = .outcomeUnknown
        if isOperationSendTurn {
            resources.sendOperationMetrics.recordCompletedStage(.roomQueueWait, duration: turn.context.queueWaitDuration)
            resources.sendOperationMetrics.begin(commandCount: turn.items.count)
        }
        defer {
            if let operationStartedAt {
                resources.sendOperationMetrics.finish(commandCount: turn.items.count,
                    outcome: operationOutcome, duration: operationStartedAt.duration(to: .now))
            }
        }
        do {
            let completion: V2RoomTransactionCompletion<[V2RoomResponse]> = try await V2RoomSQLDeadline.withDeadline(callDeadline) {
                if isProfileTurn {
                    let requests = turn.items.compactMap { item -> V2ActorProfileVisibilityBatchWire? in
                        if case .mediaAuthorization(.profileVisibilityBatch(let request)) = item.request { return request }
                        return nil
                    }
                    let results = try await v2WithAdmittedRoomDatabaseWork(resources.databaseWorkAdmission,
                        workClass: .interactiveRead, callerDeadline: callDeadline) {
                        try await handlers.media.executeProfileVisibilityBatch(requests)
                    }
                    guard results.count == turn.items.count else { return .outcomeUnknown }
                    return .committed(results.map(V2RoomResponse.mediaAuthorization))
                }
                if isOperationSendTurn {
                    let commands = turn.items.compactMap { item -> V2MessageSendOperationCommand? in
                        if case .messaging(.sendOperation(let command)) = item.request { return command }
                        return nil
                    }
                    guard commands.count == turn.items.count else { return .rolledBack(.invalidRequest) }
                    // Preparation uses read/control connections. The ready room turn
                    // then waits only at the physical write-connection dispatcher.
                    let results = try await v2ExecutePreparedRoomSendOperationBatch {
                        V2SendPathTrace.current?.mark("turn_prepare_closure_enter")
                        return try await handlers.messages.prepareSendOperationBatch(commands, deadline: callDeadline)
                    }
                    guard results.count == turn.items.count else { return .outcomeUnknown }
                    // Durable acceptance publishes exact-token facts itself.
                    // A second generic wake could arrive after their take and
                    // accidentally turn every normal body back into a SQL read.
                    return .committed(results.map(V2RoomResponse.messaging))
                }
                // Only mutations invalidate room-side acceptance state. Read,
                // receipt and subscription progress must retain the warm state.
                switch turn.items[0].request {
                case .administration, .maintenance, .forward, .messaging:
                    await resources.durableOwner.current?.store.invalidateSendState(token: token)
                default: break
                }
                let item = turn.items[0]
                let response: V2RoomResponse
                if let workClass = item.request.hostDatabaseWorkClass {
                    response = try await v2WithAdmittedRoomDatabaseWork(resources.databaseWorkAdmission,
                        workClass: workClass, callerDeadline: item.deadline) {
                        try await dispatch(item.request, handlers: handlers, resources: resources,
                            batchDeadline: turn.context.batchDeadline, callDeadline: item.deadline,
                            activationValidUntil: turn.context.activationValidUntil)
                    }
                } else {
                    // 回执和恢复操作在其执行叶子针对实际 SQL 获取许可；
                    // typed scalar 发送在上方取得一次前台写许可。
                    response = try await dispatch(item.request, handlers: handlers, resources: resources,
                        batchDeadline: turn.context.batchDeadline, callDeadline: item.deadline,
                            activationValidUntil: turn.context.activationValidUntil)
                }
                if item.request.needsSubscriptionReadSignal { resources.subscriptionHost.signal(room: token.roomID) }
                return .committed([response])
            }
            if case .committed = completion { operationOutcome = .committed }
            if case .rolledBack = completion { operationOutcome = .rolledBack }
            return completion
        } catch {
            let completion: V2RoomTransactionCompletion<[V2RoomResponse]> = v2RoomDomainCompletion(error)
            if case .rolledBack = completion { operationOutcome = .rolledBack }
            return completion
        }
    }

    private func dispatch(_ request: V2RoomRequest, handlers: Handlers,
                          resources: V2RoomServerOwnerResources,
                          batchDeadline: ContinuousClock.Instant,
                          callDeadline: ContinuousClock.Instant, activationValidUntil: ContinuousClock.Instant?) async throws -> V2RoomResponse {
        switch request {
        case .roomSubscription(let command):
            try command.validate()
            guard command.roomID == token.roomID else { return .roomSubscription(.failure(.invalidRequest)) }
            do {
                guard let activationValidUntil, activationValidUntil > .now else {
                    throw V2RoomActivationLeaseError.leaseExpired
                }
                let grantValidUntil = min(activationValidUntil, .now + V2RoomSubscriptionHost.controlFreshnessLimit)
                let owner = try await subscriptions(resources: resources, deadline: callDeadline)
                switch command {
                case .renew(let value):
                    let renewal = try await owner.renew(gateway: value.gatewayDescriptor.identity,
                        userID: value.actorUserID, expectedFence: value.expectedFence,
                        appliedControlSequence: value.appliedControlSequence, token: token, deadline: callDeadline,
                        leaseProof: { token, deadline in
                            try await resources.subscriptionHost.renewalProof(token: token, activationValidUntil: activationValidUntil, deadline: deadline)
                        })
                    return .roomSubscription(.renewed(renewal))
                case .subscribe(let value):
                    let grant = try await owner.subscribe(gateway: value.gatewayDescriptor.identity, userID: value.actorUserID, token: token, deadline: callDeadline)
                    return .roomSubscription(.granted(.init(fence: grant.fence, memberRevision: grant.memberRevision, userBaselineSequence: grant.baselineSequence, remainingLeaseMilliseconds: min(grant.remainingLeaseMilliseconds, v2SubscriptionRemainingMilliseconds(until: grantValidUntil)))))
                case .reset(let value):
                    let grant = try await owner.resetGrant(gateway: value.gatewayDescriptor.identity, userID: value.actorUserID, expectedFence: value.expectedFence, token: token, deadline: callDeadline)
                    return .roomSubscription(.granted(.init(fence: grant.fence, memberRevision: grant.memberRevision, userBaselineSequence: grant.baselineSequence, remainingLeaseMilliseconds: min(grant.remainingLeaseMilliseconds, v2SubscriptionRemainingMilliseconds(until: grantValidUntil)))))
                case .activate(let value):
                    guard let pump = await resources.subscriptionHost.currentPump() else { return .roomSubscription(.failure(.unavailable)) }
                    let bound = try await owner.activate(to: pump, descriptor: value.gatewayDescriptor, userID: value.actorUserID, fence: value.fence, token: token, deadline: callDeadline)
                    if !bound { V2RoomSubscriptionOwnerFailureMetrics.shared.record(.pumpBindRefused) }
                    return .roomSubscription(bound ? .activated : .failure(.overloaded))
                case .unsubscribe(let value):
                    try await owner.unsubscribe(gateway: value.gatewayDescriptor.identity, userID: value.actorUserID, memberRevision: value.memberRevision, token: token, deadline: callDeadline)
                    return .roomSubscription(.unsubscribed)
                }
            } catch {
                if let ownerError = error as? V2RoomSubscriptionOwnerError {
                    switch ownerError {
                    case .busy: V2RoomSubscriptionOwnerFailureMetrics.shared.record(.busy)
                    case .catchUpRequired: V2RoomSubscriptionOwnerFailureMetrics.shared.record(.catchUpRequired)
                    case .overloaded: V2RoomSubscriptionOwnerFailureMetrics.shared.record(.overloaded)
                    default: break
                    }
                }
                if case .renew = command, let ownerError = error as? V2RoomSubscriptionOwnerError,
                   ownerError == .catchUpRequired {
                    resources.subscriptionHost.signal(room: token.roomID)
                    return .roomSubscription(.failure(.unavailable))
                }
                return .roomSubscription(.failure(try v2RoomSubscriptionFailure(for: error)))
            }
        case .forward(let command):
            do { return .forward(try await handlers.forwarding.execute(command)) }
            catch V2ForwardExportError.ownerChanged, V2ForwardInboxError.ownerChanged {
                throw V2RoomActivationLeaseError.activationChanged
            } catch {
                if let failure = V2ActorForwardFailureWire(domainError: error) { return .forward(.failure(failure)) }
                throw error
            }
        case .mediaAuthorization(let query):
            do { return .mediaAuthorization(try await handlers.media.execute(query)) }
            catch V2MediaStoreError.downloadNotAuthorized { return .mediaAuthorization(.notVisible) }
        case .maintenance(let command):
            return .maintenance(try await handlers.maintenance.execute(command, token: token))
        case .messaging(let command):
            return .messaging(try await handlers.messages.execute(command))
        case .administration(let command):
            do {
                if case .trustedSafety(let value) = command {
                    guard let safetyActorUserID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                    return .administration(try await handlers.administration.executeTrustedSafety(value,
                        authority: .init(safetyActorUserID: safetyActorUserID)))
                }
                return .administration(try await handlers.administration.executeUser(command))
            } catch {
                if let failure = V2ActorAdministrationFailureWire(domainError: error) {
                    return .administration(.failure(failure))
                }
                throw error
            }
        case .administrationQuery(let query):
            do { return .administration(try await handlers.administration.execute(query)) }
            catch {
                if let failure = V2ActorAdministrationFailureWire(domainError: error) {
                    return .administration(.failure(failure))
                }
                throw error
            }
        case .receipt(let command):
            return .receipt(try await resources.receiptBatcher.record(.init(command: command, token: token,
                batchDeadline: batchDeadline, callDeadline: callDeadline, ingressAt: now())))
        case .receiptQuery(let query):
            return .receipt(try await handlers.receipts.query(query))
        case .roomLog(let query):
            do { return .roomLog(try await handlers.queries.log(query)) }
            catch let failure as V2GroupEventLogError { return .roomLog(.failure(.init(failure))) }
        case .directory(let query):
            return .directory(try await handlers.queries.directory(query))
        case .recovery(let query):
            let granted = V2GrantedRoomReadTurn(token: token, actorUserID: query.actorUserID,
                batchDeadline: batchDeadline, callDeadline: callDeadline)
            switch query.kind {
            case .state: return .recovery(.state(.init(try await resources.recovery.state(granted))))
            case .latestVisible: return .recovery(.latestVisible(.init(try await resources.recovery.latestVisible(granted))))
            }
        case .specialAccountAudit(let command):
            return .specialAccountAudit(try await handlers.audit.execute(command))
        case .invitationQuery(let query):
            do { return .invitation(try await handlers.invitations.execute(query)) }
            catch let failure as V2GroupInvitationServiceError { return .invitation(.failure(.init(domain: failure))) }
            catch let failure as V2GroupInvitationValidationError { return .invitation(.failure(.init(validationError: failure))) }
        }
    }

    private func subscriptions(resources: V2RoomServerOwnerResources, deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionOwner {
        if let subscriptionOwner { return subscriptionOwner }
        guard !closed, !restoringSubscription else { throw V2RoomSubscriptionOwnerError.busy }
        guard await resources.subscriptionHost.currentPump() != nil else { throw V2RoomSubscriptionOwnerError.closed }
        restoringSubscription = true; defer {
            restoringSubscription = false
            let waiters = subscriptionRestoreWaiters; subscriptionRestoreWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let source = try PostgresV2RoomSubscriptionSource(database: resources.database, activation: token, databaseWorkAdmission: resources.databaseWorkAdmission)
        let host = resources.subscriptionHost
        let roomID = token.roomID
        let created = try await V2RoomSubscriptionOwner.restore(source: source, roomID: token.roomID, owner: token.owner, activation: token, deadline: deadline, trackedUserIDs: [], notifyChanged: { host.signal(gateway: .init(roomID: roomID, gateway: $0)) })
        guard !closed else { try await created.close(); throw V2RoomSubscriptionOwnerError.closed }
        try await host.register(created, token: token)
        subscriptionOwner = created
        return created
    }

    func invalidate(_ reservation: V2RoomReservation) async {
        guard reservation.token == token, !closed else { return }
        await resources?.writes.invalidateActorHints(token: token)
        await resources?.durableOwner.current?.store.invalidateSendState(token: token)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        if restoringSubscription { await withCheckedContinuation { subscriptionRestoreWaiters.append($0) } }
        if let subscriptionOwner { try? await subscriptionOwner.close() }
        await resources?.subscriptionHost.unregister(token: token)
        subscriptionOwner = nil
        handlers = nil
        await resources?.durableOwner.current?.store.invalidateSendState(token: token)
        await resources?.writes.closeActorState(token: token)
        try? await resources?.policyAuthorizations?.retire(token: token)
    }

    private struct Handlers: Sendable {
        let messages: any V2RoomMessagingExecuting
        let administration: any V2RoomAdministrationExecuting
        let audit: V2RoomSpecialAccountAuditExecutor
        let invitations: V2RoomInvitationDomainExecutor
        let maintenance: V2ActorRoomMaintenanceExecutor
        let forwarding: V2RoomForwardDomainExecutor
        let media: any V2RoomMediaAuthorizationExecuting
        let queries: any V2RoomQueryExecuting
        let receipts: any V2RoomReceiptQueryExecuting

        init(token: V2RoomActivationToken, resources: V2RoomServerOwnerResources,
             now: @escaping @Sendable () -> Date) throws {
            forwarding = try .init(database: resources.database, token: token, write: resources.writes,
                capacityProfile: resources.capacity, limits: resources.messageLimits, now: now)
            media = try V2RoomMediaAuthorizationDomainExecutor(database: resources.database, token: token)
            queries = V2BoundRoomQueries(token: token, executor: resources.queries)
            receipts = V2BoundRoomReceiptQueries(token: token, executor: resources.receipts)
            maintenance = .init(database: resources.database, now: now)
            guard let durable = resources.durableOwner.current else {
                throw V2RoomCallFailure.notAccepted(.notReady)
            }
            messages = try V2RoomMessagingExecutor(token: token, writes: resources.writes,
                capacityProfile: resources.capacity, limits: resources.messageLimits,
                maximumEditBytes: resources.maximumEditBytes, now: now,
                mutations: resources.mutations, sendOperations: durable.store,
                sendOperationOwnerBatcher: durable.batcher,
                directSendPreparation: durable.directPreparation, reactionOperations:.init(database:resources.database,clock:now,committedMessageObserver:resources.committedMessageObserver))
            administration = try V2RoomAdministrationDomainExecutor(database: resources.database, invitationSecretIssuer: resources.invitationSecretIssuer, invitationIdentities: resources.invitationIdentities, token: token,
                capacityProfile: resources.capacity, membershipIdentities: resources.identities, now: now)
            audit = try .init(token: token, store: .init(database: resources.database), now: now)
            invitations = try .init(database: resources.database, token: token,
                identities: resources.invitationIdentities, capacityProfile: resources.capacity, now: now)
        }
    }
}

private extension V2RoomRequest {
    var needsSubscriptionReadSignal: Bool {
        switch self {
        case .messaging, .administration, .maintenance, .forward, .specialAccountAudit: return true
        case .roomSubscription, .receipt, .recovery, .administrationQuery, .receiptQuery,
             .roomLog, .directory, .invitationQuery, .mediaAuthorization: return false
        }
    }
    var hostDatabaseWorkClass: V2DatabaseWorkClass? {
        switch self {
        case .receipt, .recovery, .roomSubscription: return nil
        case .administrationQuery, .receiptQuery, .roomLog, .directory,
             .invitationQuery, .mediaAuthorization: return .interactiveRead
        case .forward, .maintenance, .messaging, .administration,
             .specialAccountAudit: return .foregroundWrite
        }
    }
}

extension V2RoomMessagingExecutor: V2RoomMessagingExecuting {}
extension V2RoomAdministrationDomainExecutor: V2RoomAdministrationExecuting {}
extension V2RoomMediaAuthorizationDomainExecutor: V2RoomMediaAuthorizationExecuting {}

private struct V2BoundRoomQueries: V2RoomQueryExecuting {
    let token: V2RoomActivationToken
    let executor: V2ActorRoomQueryExecutor

    func log(_ query: V2RoomLogQuery) async throws -> V2RoomLogQueryResult {
        try await executor.log(query, token: token)
    }

    func directory(_ query: V2RoomDirectoryQuery) async throws -> V2RoomDirectoryResult {
        try await executor.directory(query, token: token)
    }
}

private struct V2BoundRoomReceiptQueries: V2RoomReceiptQueryExecuting {
    let token: V2RoomActivationToken
    let executor: V2ActorRoomReceiptExecutor

    func query(_ query: V2RoomReceiptQuery) async throws -> V2RoomReceiptResult {
        try await executor.query(query, token: token)
    }
}

/// One bounded drain worker and transport pump per physical owner. Commit
/// notifications coalesce synchronously; transactions never await network work.
package actor V2RoomSubscriptionHost {
    private struct Entry: Sendable { let token: V2RoomActivationToken; let owner: V2RoomSubscriptionOwner }
    private struct HeadRefresh: Sendable { let token: V2RoomActivationToken; let highWatermark: UInt64 }
    private struct Pending: Sendable {
        var registeredRooms: Set<RoomID> = []
        var rooms: Set<RoomID> = []
        var deliveryRooms: Set<RoomID> = []
        var heads: [RoomID: HeadRefresh] = [:]
        var closed = false
    }
    private nonisolated let pending = Mutex(Pending())
    private nonisolated let factsFeed = Mutex<V2RoomCommittedFactsFeed?>(nil)
    private nonisolated let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var entries: [RoomID: Entry] = [:]
    private var pump: V2RoomSubscriptionDeliveryPump?
    private var worker: Task<Void, Never>?
    private var checker: Task<Void, Never>?
    private let checkInterval: Duration
    package static let controlFreshnessLimit: Duration = .seconds(15)
    private var checkingChanges = false
    private var controlValidUntil: ContinuousClock.Instant?
    private var controlCycleStarted: ContinuousClock.Instant?
    private let controlFreshness: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let dirtyChanges: V2RoomSubscriptionDirtyChanges
    private var dirtyCursor: V2RoomSubscriptionDirtyCursor?
    private let dirtyAcknowledge: V2RoomSubscriptionDirtyHeadAcknowledge?
    private var dirtyHeads: [RoomID: V2RoomSubscriptionDirtyHead] = [:]
    private var completedDirty: [RoomID: V2RoomSubscriptionDirtyHead] = [:]
    private var closed = false
    private let maximumRooms: Int
    private let maximumBindings: Int

    nonisolated func install(feed: V2RoomCommittedFactsFeed) {
        factsFeed.withLock { precondition($0 == nil); $0 = feed }
    }

    package init(checkInterval: Duration = .seconds(5), controlFreshness: Duration = V2RoomSubscriptionHost.controlFreshnessLimit,
                 maximumRooms: Int = 8192, maximumBindings: Int = 8192,
                 now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                 dirtyChanges: @escaping V2RoomSubscriptionDirtyChanges, dirtyAcknowledge: V2RoomSubscriptionDirtyHeadAcknowledge? = nil) {
        precondition(checkInterval > .zero && controlFreshness > .zero && maximumRooms > 0 && maximumBindings > 0)
        self.maximumRooms = maximumRooms; self.maximumBindings = maximumBindings
        self.checkInterval = checkInterval
        self.controlFreshness = controlFreshness; self.now = now
        self.dirtyChanges = dirtyChanges; self.dirtyAcknowledge = dirtyAcknowledge
    }

    func configure(sendBatch: @escaping V2RoomSubscriptionDeliveryPump.SendBatch, maximumCalls: Int) async throws {
        guard !closed, pump == nil else { throw V2RoomSubscriptionOwnerError.invalidInput }
        let created = V2RoomSubscriptionDeliveryPump(maximumEntries: maximumBindings,
            maximumCalls: maximumCalls, sendBatch: sendBatch,
            requestBaseline: { _, _ in
                // A fresh fence must travel through subscribe/grant/activate;
                // a transport callback cannot install trusted authority.
            })
        pump = created
        await created.start()
        worker = Task { [weak self, stream = wakes.stream] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await self.consume()
            }
        }
        // Correctness does not depend on a final commit notification arriving.
        // One physical-host task consumes durable
        // pending changes, coalescing with foreground commit notifications.
        checker = Task { [weak self, interval = checkInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.checkChanges()
            }
        }
    }
    func currentPump() -> V2RoomSubscriptionDeliveryPump? { closed ? nil : pump }
    func register(_ owner: V2RoomSubscriptionOwner, token: V2RoomActivationToken) async throws {
        guard !closed, pump != nil, entries[token.roomID] == nil, entries.count < maximumRooms else {
            throw V2RoomSubscriptionOwnerError.overloaded
        }
        entries[token.roomID] = .init(token: token, owner: owner)
        pending.withLock { $0.registeredRooms.insert(token.roomID) }
        if let feed = factsFeed.withLock({ $0 }), !feed.register(activation: token) {
            entries.removeValue(forKey: token.roomID)
            pending.withLock { $0.registeredRooms.remove(token.roomID) }
            throw V2RoomSubscriptionOwnerError.overloaded
        }
    }
    func unregister(token: V2RoomActivationToken) {
        guard entries[token.roomID]?.token == token else { return }
        entries.removeValue(forKey: token.roomID)
        dirtyHeads.removeValue(forKey: token.roomID); completedDirty.removeValue(forKey: token.roomID)
        factsFeed.withLock { $0 }?.unregister(activation: token)
        pending.withLock { value in
            value.rooms.remove(token.roomID); value.registeredRooms.remove(token.roomID)
            value.deliveryRooms.remove(token.roomID); value.heads.removeValue(forKey: token.roomID)
        }
    }
    /// One host-level durable control feed. No stationary-room lease/head probes.
    package func checkChanges() async {
        guard !closed, !checkingChanges, let host = entries.values.first?.token.host else { return }
        checkingChanges = true; defer { checkingChanges = false }
        // A durable ACK may have committed before its response was lost. The
        // pending query can then be empty; retained exact receipts still need
        // the existing worker to retry and settle local ownership.
        if !completedDirty.isEmpty { wakes.continuation.yield(()) }
        let deadline = ContinuousClock.now + .seconds(10)
        if dirtyCursor == nil { controlCycleStarted = now() }
        do {
            for _ in 0..<64 {
                let page = try await dirtyChanges(host, dirtyCursor, 128, deadline)
                guard !closed else { return }
                dirtyCursor = page.nextCursor
                for change in page.changes {
                    guard let current = entries[change.activation.roomID], current.token == change.activation else { continue }
                    dirtyHeads[change.activation.roomID] = change
                    try await current.owner.observePermissionVersion(change.roomControlVersion, token: current.token)
                    let consumedThrough = await current.owner.consumedSequence()
                    guard entries[current.token.roomID]?.token == current.token else { continue }
                    retainHead(token: current.token, highWatermark: change.highWatermark)
                    if change.highWatermark > consumedThrough { signal(room: current.token.roomID) }
                }
                if dirtyCursor == nil {
                    // Count SQL/queue time against freshness. A stalled or partial
                    // cycle cannot indefinitely extend old permission grants.
                    controlValidUntil = controlCycleStarted.map { $0 + controlFreshness }
                    controlCycleStarted = nil
                    return
                }
                guard .now < deadline else { return }
            }
        } catch { /* Retain the original freshness boundary and retry the feed. */ }
    }

    package func renewalProof(token: V2RoomActivationToken, activationValidUntil: ContinuousClock.Instant,
                              deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionLeaseProof {
        guard !closed, deadline > .now, let entry = entries[token.roomID], entry.token == token,
              let controlValidUntil, controlValidUntil > now(), activationValidUntil > now() else {
            throw V2RoomSubscriptionOwnerError.catchUpRequired
        }
        let checkpoint = await entry.owner.renewalCheckpoint()
        guard !closed, entries[token.roomID]?.token == token else { throw V2RoomActivationLeaseError.activationChanged }
        let dirty = dirtyHeads[token.roomID]
        guard dirty.map({ $0.roomControlVersion == checkpoint.controlVersion }) ?? true else {
            throw V2RoomSubscriptionOwnerError.catchUpRequired
        }
        // A committed message backlog is not an authorization discontinuity.
        // Share its trusted advisory target without advancing the consumed log
        // or clearing the feed's retained delivery/repair responsibility.
        let committedHead = max(checkpoint.sequence, max(dirty?.highWatermark ?? 0,
            factsFeed.withLock { $0 }?.highWatermark(activation: token) ?? 0))
        let remaining = v2SubscriptionRemainingMilliseconds(until: min(controlValidUntil, activationValidUntil), now: now())
        guard remaining > 0 else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
        return .init(activation: token, committedRoomSequence: committedHead,
            roomControlVersion: checkpoint.controlVersion, remainingLeaseMilliseconds: remaining)
    }
    /// Only an already activated subscription can renew. Missing entries never
    /// restore from SQL or create a grant on this independent read path.
    package func renew(command: V2RoomSubscriptionRenewCommand, token: V2RoomActivationToken,
                       activationValidUntil: ContinuousClock.Instant,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionRenewal {
        guard !closed, let entry = entries[token.roomID], entry.token == token else {
            throw V2RoomSubscriptionOwnerError.catchUpRequired
        }
        return try await entry.owner.renew(gateway: command.gatewayDescriptor.identity,
            userID: command.actorUserID, expectedFence: command.expectedFence,
            appliedControlSequence: command.appliedControlSequence, token: token, deadline: deadline,
            leaseProof: { token, deadline in
                try await self.renewalProof(token: token, activationValidUntil: activationValidUntil, deadline: deadline)
            })
    }
    private func retainHead(token: V2RoomActivationToken, highWatermark: UInt64) {
        guard entries[token.roomID]?.token == token else { return }
        pending.withLock { value in
            guard !value.closed, value.registeredRooms.contains(token.roomID) else { return }
            let old = value.heads[token.roomID]
            value.heads[token.roomID] = .init(token: token,
                highWatermark: old?.token == token ? max(old!.highWatermark, highWatermark) : highWatermark)
        }
        wakes.continuation.yield(())
    }
    nonisolated func signal(room: RoomID) {
        pending.withLock { value in
            guard !value.closed, value.registeredRooms.contains(room) else { return }
            value.rooms.insert(room)
        }
        wakes.continuation.yield(())
    }
    nonisolated func signal(gateway: V2RoomSubscriptionDeliveryPump.Key) {
        pending.withLock { value in
            guard !value.closed, value.registeredRooms.contains(gateway.roomID) else { return }
            value.deliveryRooms.insert(gateway.roomID)
        }
        wakes.continuation.yield(())
    }
    private func consume() async {
        guard !closed else { return }
        let work = pending.withLock { value -> Pending in
            let work = value; value.rooms.removeAll(keepingCapacity: true); value.deliveryRooms.removeAll(keepingCapacity: true); value.heads.removeAll(keepingCapacity: true); return work
        }
        for room in work.deliveryRooms { if let entry = entries[room] { await entry.owner.signalDelivery() } }
        for request in work.heads.values {
            guard !closed, let entry = entries[request.token.roomID], entry.token == request.token else { continue }
            do {
                if let dirty = dirtyHeads[request.token.roomID], dirty.activation == request.token {
                    let complete = try await entry.owner.processControlCut(expectedVersion: dirty.roomControlVersion,
                        token: request.token, deadline: .now + .seconds(10))
                    guard complete else {
                        // Actual terminal receipt, not offer/start, completes a
                        // changed permission cut. The next existing cycle retries.
                        await entry.owner.signalDelivery()
                        continue
                    }
                }
                try await entry.owner.refreshHeads(observedHighWatermark: request.highWatermark,
                    token: request.token, deadline: .now + .seconds(10))
                if let dirty = dirtyHeads[request.token.roomID], dirty.activation == request.token,
                   dirty.highWatermark <= request.highWatermark { completedDirty[request.token.roomID] = dirty }
            } catch V2RoomSubscriptionOwnerError.busy {
                // The shared worker retains this advisory responsibility without
                // another SQL read or an independent timer/Task per room.
                retainHead(token: request.token, highWatermark: request.highWatermark)
                try? await Task.sleep(for: .milliseconds(25))
            } catch V2RoomSubscriptionOwnerError.catchUpRequired {
                if !work.rooms.contains(request.token.roomID) { signal(room: request.token.roomID) }
            } catch { /* Lost activation admits neither a head nor a lease. */ }
        }
        for room in work.rooms {
            guard !closed, let entry = entries[room] else { continue }
            let feed = factsFeed.withLock { $0 }
            do {
                if let dirty = dirtyHeads[room], dirty.activation == entry.token {
                    let complete = try await entry.owner.processControlCut(expectedVersion: dirty.roomControlVersion,
                        token: entry.token, deadline: .now + .seconds(10))
                    guard complete else { await entry.owner.signalDelivery(); continue }
                }
                let batch = feed?.take(activation: entry.token)
                let deadline = ContinuousClock.now + .seconds(10)
                let report = try await V2RoomSQLDeadline.withDeadline(deadline) {
                    if let batch {
                        let fast = try await entry.owner.consumeCommittedMessages(batch, token: entry.token, deadline: deadline)
                        if !fast.hasMore { return fast }
                    }
                    return try await entry.owner.drain(token: entry.token, deadline: deadline)
                }
                // Release only the Owner's actually consumed prefix. A commit
                // that arrived during the await remains in the bounded feed.
                feed?.acknowledge(activation: entry.token, consumedThrough: report.consumedThrough)
                if let dirty = dirtyHeads[room], dirty.activation == entry.token, report.consumedThrough >= dirty.highWatermark {
                    retainHead(token: entry.token, highWatermark: dirty.highWatermark)
                }
                if report.hasMore { signal(room: room) }
            } catch V2RoomSubscriptionOwnerError.busy {
                // Bounded single-owner delay, with no unowned retry tasks.
                try? await Task.sleep(for: .milliseconds(25))
                if !closed { signal(room: room) }
            } catch is V2RoomSubscriptionSourceError {
                // Sequence/persistence loss closes the Owner; only a new
                // trusted activation may restore this stream.
            } catch is V2RoomSubscriptionRelayError {
            } catch is V2RoomActivationLeaseError {
            } catch V2RoomSubscriptionOwnerError.closed {
            } catch {
                // Admission/timeouts/transient DB failures do not transfer or
                // erase the committed-read responsibility. Retry one coalesced
                // room with the same cursor under a fresh bounded deadline.
                try? await Task.sleep(for: .milliseconds(25))
                if !closed { signal(room: room) }
            }
        }
        if let dirtyAcknowledge, !completedDirty.isEmpty, !closed {
            let ready = completedDirty.values.filter { receipt in
                entries[receipt.activation.roomID]?.token == receipt.activation
                    && dirtyHeads[receipt.activation.roomID] == receipt
            }
            do {
                try await dirtyAcknowledge(Array(ready), .now + .seconds(10))
                for receipt in ready where dirtyHeads[receipt.activation.roomID] == receipt {
                    dirtyHeads.removeValue(forKey: receipt.activation.roomID)
                    completedDirty.removeValue(forKey: receipt.activation.roomID)
                }
            } catch { /* Keep exact receipts; the independent change cycle retries. */ }
        }
    }
    func close() async {
        guard !closed else { return }; closed = true
        pending.withLock { $0.closed = true; $0.rooms.removeAll(); $0.deliveryRooms.removeAll(); $0.heads.removeAll(); $0.registeredRooms.removeAll() }
        wakes.continuation.finish()
        checker?.cancel()
        if let checker { await checker.value }; checker = nil
        worker?.cancel()
        if let worker { await worker.value }; worker = nil
        for entry in entries.values { try? await entry.owner.close() }
        entries.removeAll(); dirtyHeads.removeAll(); completedDirty.removeAll()
        let feed = factsFeed.withLock { value in let feed = value; value = nil; return feed }
        feed?.finish()
        if let pump { await pump.close() }; pump = nil
    }
}

/// Read-only subscription commands never reinterpret transient DB admission or
/// transport failure as loss of the room activation. Irrecoverable local
/// authority loss crosses the existing Runtime staleActivation retirement path.
package func v2RoomSubscriptionFailure(for error: any Error) throws -> V2RoomSubscriptionFailure {
    if let value = error as? V2RoomSubscriptionOwnerError {
        switch value {
        case .closed: throw V2RoomActivationLeaseError.activationChanged
        case .unauthorized: return .unauthorized
        case .busy, .overloaded, .catchUpRequired: return .overloaded
        case .invalidInput: return .invalidRequest
        case .stale: return .stale
        case .deadlineExceeded: return .unavailable
        }
    }
    if let value = error as? V2RoomSubscriptionSourceError {
        switch value {
        case .invalidInput: return .invalidRequest
        case .wrongOwner, .roomNotFound, .snapshotRequired, .corruptPersistence:
            throw V2RoomActivationLeaseError.activationChanged
        }
    }
    if error is V2RoomSubscriptionRelayError { throw V2RoomActivationLeaseError.activationChanged }
    if let value = error as? V2RoomActivationLeaseError { throw value }
    if error is V2ActorContractError { return .invalidRequest }
    if let value = error as? V2RoomCallFailure {
        switch value {
        case .notAccepted(.overloaded), .rolledBack(.overloaded): return .overloaded
        case .notAccepted(.staleActivation), .rolledBack(.staleActivation),
             .notAccepted(.leaseLost), .rolledBack(.leaseLost):
            throw V2RoomActivationLeaseError.activationChanged
        default: return .unavailable
        }
    }
    return .unavailable
}

private func v2SubscriptionRemainingMilliseconds(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Int64 {
    let duration = now.duration(to: deadline).components
    return max(0, duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
}
