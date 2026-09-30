import IMV2ServerInfrastructure
import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// 每个配置的物理所有者对应一个值。连接池句柄、额度缓存和批处理器
/// 在多个激活间共享，不按房间分配。
public struct V2RoomServerOwnerResources: Sendable {
    let database: any Database
    let writes: PostgresV2RoomWriteStore
    let mutations: PostgresV2MessageMutationOperationStore
    let identities: any V2MembershipIdentitySnapshotValidating
    let invitationSecretIssuer: V2GroupInviteSecretIssuer
    let invitationIdentities: any V2GroupInvitationIdentityReading
    let receipts: V2ActorRoomReceiptExecutor
    let receiptBatcher: V2HostRoomReceiptBatcher
    let queries: V2ActorRoomQueryExecutor
    let recovery: V2HostRoomRecoveryQueryBatcher
    let sends: V2ActorGrantedSendBatchAdapter
    let capacity: V2CapacityProfile
    let messageLimits: V2MessageCommandLimits
    let maximumEditBytes: Int
    let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    let committedMessageObserver: (any V2CommittedMessageBatchObserving)?
    public let sendOperationMetrics = V2SendOperationBatchMetrics()

    public init(database: any Database, writes: PostgresV2RoomWriteStore,
                sendBatcher: any V2ActorGrantedSendBatching,
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
                committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil) throws {
        guard maximumEditBytes > 0 else {
            throw V2ActorContractError.invalidConfiguration("room edit bytes")
        }
        self.database = database
        self.mutations = .init(database:database,contentReviewMode:contentReviewMode,identities:membershipIdentities,committedMessageObserver:committedMessageObserver)
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
            databaseWorkAdmission: databaseWorkAdmission)
        self.sends = .init(batcher: sendBatcher)
        self.capacity = capacityProfile
        self.messageLimits = messageLimits
        self.maximumEditBytes = maximumEditBytes
        self.databaseWorkAdmission = databaseWorkAdmission
        self.committedMessageObserver = committedMessageObserver
    }
}

/// Server 持有具体的领域处理器；Runtime 负责调度与生命周期，
/// Cluster 负责认证与传输。后两者都不导入 Server。
public struct V2RoomServerActivationFactory: Sendable {
    private let owners: [String: V2RoomServerOwnerResources]
    private let safetyActorUserID: UserID?
    private let now: @Sendable () -> Date

    public init(owners: [String: V2RoomServerOwnerResources], safetyActorUserID: UserID?,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !owners.isEmpty else { throw V2ActorContractError.invalidConfiguration("room owner resources") }
        for key in owners.keys { _ = try V2RoomDataOwner(shardID: key, epoch: 0) }
        self.owners = owners
        self.safetyActorUserID = safetyActorUserID
        self.now = now
    }

    public func runtimeFactory() -> V2RoomActivationFactory<V2RoomRequest, V2RoomResponse> {
        .init { token in
            let instance = V2RoomServerActivation(token: token, resources: owners[token.owner.shardID],
                safetyActorUserID: safetyActorUserID, now: now)
            return .init(restore: { try await instance.restore(deadline: $0) },
                execute: { await instance.execute($0) },
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
    private var handlers: Handlers?
    private var closed = false

    init(token: V2RoomActivationToken, resources: V2RoomServerOwnerResources?,
         safetyActorUserID: UserID?, now: @escaping @Sendable () -> Date) {
        self.token = token
        self.resources = resources
        self.safetyActorUserID = safetyActorUserID
        self.now = now
    }

    func restore(deadline: ContinuousClock.Instant) async throws {
        guard !closed, handlers == nil, let resources else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let created = try Handlers(token: token, resources: resources, now: now)
        let token = self.token
        try await V2RoomSQLDeadline.withDeadline(deadline) {
            try await v2ValidateRoomActivation(database: resources.database, token: token)
        }
        guard !closed, ContinuousClock.now < deadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        handlers = created
    }

    func execute(_ turn: V2RoomTurn<V2RoomRequest>) async -> V2RoomTransactionCompletion<[V2RoomResponse]> {
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
        if isOperationSendTurn { resources.sendOperationMetrics.begin(commandCount: turn.items.count) }
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
                    let results = try await v2WithAdmittedRoomDatabaseWork(resources.databaseWorkAdmission,
                        workClass: .foregroundWrite, callerDeadline: callDeadline) {
                        try await handlers.messages.executeSendOperationBatch(commands)
                    }
                    guard results.count == turn.items.count else { return .outcomeUnknown }
                    return .committed(results.map(V2RoomResponse.messaging))
                }
                let item = turn.items[0]
                let response: V2RoomResponse
                if let workClass = item.request.hostDatabaseWorkClass {
                    response = try await v2WithAdmittedRoomDatabaseWork(resources.databaseWorkAdmission,
                        workClass: workClass, callerDeadline: item.deadline) {
                        try await dispatch(item.request, handlers: handlers, resources: resources,
                            batchDeadline: turn.context.batchDeadline, callDeadline: item.deadline)
                    }
                } else {
                    // 回执和恢复操作在其执行叶子针对实际 SQL 获取许可；
                    // typed scalar 发送在上方取得一次前台写许可。
                    response = try await dispatch(item.request, handlers: handlers, resources: resources,
                        batchDeadline: turn.context.batchDeadline, callDeadline: item.deadline)
                }
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
                          callDeadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        switch request {
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

    func invalidate(_ reservation: V2RoomReservation) async {
        guard reservation.token == token, !closed else { return }
        await resources?.writes.invalidateActorHints(token: token)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        handlers = nil
        await resources?.writes.closeActorState(token: token)
        await resources?.sends.retire(token)
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
            messages = try V2RoomMessagingExecutor(token: token, writes: resources.writes,
                capacityProfile: resources.capacity, limits: resources.messageLimits,
                maximumEditBytes: resources.maximumEditBytes, now: now,
                mutations:resources.mutations,sendOperations:.init(database:resources.database,writes:resources.writes,clock:now,committedMessageObserver:resources.committedMessageObserver),reactionOperations:.init(database:resources.database,clock:now,committedMessageObserver:resources.committedMessageObserver))
            administration = try V2RoomAdministrationDomainExecutor(database: resources.database, invitationSecretIssuer: resources.invitationSecretIssuer, invitationIdentities: resources.invitationIdentities, token: token,
                capacityProfile: resources.capacity, membershipIdentities: resources.identities, now: now)
            audit = try .init(token: token, store: .init(database: resources.database), now: now)
            invitations = try .init(database: resources.database, token: token,
                identities: resources.invitationIdentities, capacityProfile: resources.capacity, now: now)
        }
    }
}

private extension V2RoomRequest {
    var hostDatabaseWorkClass: V2DatabaseWorkClass? {
        switch self {
        case .receipt, .recovery: return nil
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
