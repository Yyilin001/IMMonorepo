import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit

/// V2 接受边界的 PostgreSQL 实现。
///
/// 普通消息由房间 Actor 排序、在内存中授权，独立提交房间事务。
/// 其他业务入口保留各自的持久状态校验。
public struct PostgresV2RoomWriteStore: V2OwnerValidatedRoomWriteStore, V2OwnerValidatedForwardMessageWriteStore {
    private var database: any Database
    private var controlDatabase: (any Database)?
    private var policyAuthorizations: V2RoomPolicyAuthorizationService?
    var usesMemorySendPreparation: Bool { policyAuthorizations != nil }
    private var controlResolution: V2RoomWriteControlResolution = .unresolved
    var authorizationGrants: [String: V2DirectAuthorizationGrant]? { controlResolution.authorization?.grants }
    private var authorizationResolutionDatabase: (any Database)?
    var controlScopeRoomKinds: [UUID: String]? { controlResolution.roomKinds }
    // 在一次限定范围的值拷贝生命周期内保持不可变。共享缓存 Actor
    // 保持原有身份；不使用可变的隐式路由。
    private var ownerSelection = V2RoomWriteOwnerSelection()
    var ownerRoutes: [UUID: V2RoomShardRoute]? { ownerSelection.routes }
    var activationScope: V2RoomActivationWriteScope? { ownerSelection.activation }
    var forwardOwnerSourceRoomID: UUID? { ownerSelection.forwardSource }
    private var controlPolicyScope: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]? { controlResolution.policies }
    let strangerMessagePolicy: V2StrangerMessagePolicy
    let contentReviewMode: V2ContentReviewMode
    private let directSendPolicyCache: V2DirectSendPolicyCache
    private let roomWriteBatchRouteCache: V2RoomWriteBatchRouteCache
    private let appendStageMetrics: V2DirectRoomLogAppendStageMetrics?

    /// 组合数据库与写入策略。
    ///
    /// - Parameters:
    ///   - database: 存放房间、事件与投递的数据库。
    ///   - strangerMessagePolicy: 陌生人消息策略。
    ///   - contentReviewMode: 内容审核模式。
    ///   - directSendPolicyCache: 可选的私聊发送策略缓存。
    ///   - appendStageMetrics: 可选的追加阶段指标。
    public init(
        database: any Database,
        strangerMessagePolicy: V2StrangerMessagePolicy,
        contentReviewMode: V2ContentReviewMode,
        directSendPolicyCache: V2DirectSendPolicyCache = .init(),
        appendStageMetrics: V2DirectRoomLogAppendStageMetrics? = nil
    ) {
        self.database = database
        self.strangerMessagePolicy = strangerMessagePolicy
        self.contentReviewMode = contentReviewMode
        self.directSendPolicyCache = directSendPolicyCache
        self.roomWriteBatchRouteCache = .init()
        self.appendStageMetrics = appendStageMetrics
    }

    /// 为这个确切的物理归属绑定另一个工作负载连接池。
    ///
    /// 值拷贝会保留全部策略以及共享缓存 actor 的身份。
    /// 组合根必须让两个连接池解析到同一个存储 URL。
    ///
    /// - Parameter database: 要绑定的工作负载数据库连接。
    /// - Returns: 绑定了新连接池的副本。
    public func usingWorkloadDatabase(_ database: any Database) -> Self {
        var copy = self
        copy.database = database
        return copy
    }

    /// 绑定已经获准的确切激活权限。每条 SQL 路径仍在自身事务内校验该权限；
    /// 此值拷贝本身不授予权限，并保留共享缓存的身份。
    var strangerQuotaWindowSeconds:TimeInterval { strangerMessagePolicy.window }
    private var transactionOwnership: V2RoomWriteTransactionOwnership = .store

    func usingOperationTransaction() -> Self {
        var copy = self
        copy.transactionOwnership = .operationReceipt
        return copy
    }

    public func usingActivationScope(_ scope: V2RoomActivationWriteScope) -> Self {
        var copy = self
        copy.ownerSelection = ownerSelection.withActivation(scope)
        return copy
    }

    /// 预留操作可能在此执行器的常规轮次之外改变事实。
    /// 释放栅栏前清除提示；SQL 中的事实仍是权威。
    package func invalidateActorHints(token: V2RoomActivationToken) async {
        guard let room = token.roomID.uuidValue else { return }
        await directSendPolicyCache.invalidate(roomID: room)
    }

    /// Host 仅在执行器的 SQL 与批次处理结束后清除该房间的缓存提示。
    package func closeActorState(token: V2RoomActivationToken) async {
        await invalidateActorHints(token: token)
    }

    /// 绑定权威控制连接池。即使连接同一个物理数据库，也必须独立于归属方连接池。
    /// 运行时还须提供独立的解析连接池：策略写入者不能等待某个预留连接，
    /// 而后者又在等待策略写入者持有的排他锁。
    /// 共享回退路径仅供显式组装的本地存储使用。
    public func usingControlDatabase(_ database: any Database, authorizationResolutionDatabase: (any Database)? = nil) -> Self {
        var copy = self
        copy.controlDatabase = database
        copy.authorizationResolutionDatabase = authorizationResolutionDatabase ?? database
        return copy
    }

    /// 绑定控制存储中已提交的授权许可。下方每条归属方写入路径均在操作锁内校验，
    /// 并在与消息或持久业务拒绝相同的事务中记录最终证明。
    /// 自动化的常规、批量和转发入口负责预留并绑定这些许可。
    func usingAuthorizationGrants(_ grants: [V2DirectAuthorizationGrant], now: Date) throws -> Self {
        var copy = self
        copy.controlResolution = try controlResolution.authorizing(grants, now: now)
        return copy
    }

    /// Available only with a live runtime-minted execution and its exact room
    /// activation. Actual SQL also checks the durable lease and activation.
    func usingPolicyExecution(_ execution: V2RoomPolicyExecution) throws -> Self {
        guard let activationScope,
              try activationScope.token(for: execution.activation.roomID.uuidValue!) == execution.activation else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        var copy = self
        copy.controlResolution = .leased(execution)
        return copy
    }

    package func usingPolicyAuthorizations(_ service: V2RoomPolicyAuthorizationService) -> Self {
        var copy = self; copy.policyAuthorizations = service; return copy
    }

    /// Prepares durable control authorization before an operation-owned room
    /// transaction begins. The operation receipt/proof worker settles these
    /// intents after the owner transaction commits or aborts.
    var policyExecution: V2RoomPolicyExecution? { controlResolution.policyExecution }

    var needsOperationAuthorizationPreparation: Bool { controlResolution.needsPreparation }

    func prepareOperationBatchAuthorization(command: V2SendMessageCommand, now: Date, sendOperationMetrics: V2SendOperationBatchMetrics? = nil, preloadedRoutes: [DurableAuthorizationRouteRow]? = nil) async throws -> Self {
        guard controlResolution.needsPreparation else { return self }
        let prepared = try await V2RoomWriteAuthorizationCoordinator(database: database,
            controlDatabase: controlDatabase, resolutionDatabase: authorizationResolutionDatabase)
            .prepare(commands: [command], now: now, sendOperationMetrics: sendOperationMetrics, preloadedRoutes: preloadedRoutes)
        return try operationBatchScopedStore(prepared, now: now)
    }

    func prepareOperationBatchAuthorizations(commands: [V2SendMessageCommand], now: Date, sendOperationMetrics: V2SendOperationBatchMetrics? = nil, preloadedRoutes: [DurableAuthorizationRouteRow]? = nil) async throws -> Self {
        guard controlResolution.needsPreparation else { return self }
        let prepared = try await V2RoomWriteAuthorizationCoordinator(database: database,
            controlDatabase: controlDatabase, resolutionDatabase: authorizationResolutionDatabase)
            .prepare(commands: commands, now: now, sendOperationMetrics: sendOperationMetrics, preloadedRoutes: preloadedRoutes)
        return try operationBatchScopedStore(prepared, now: now)
    }

    private func operationBatchScopedStore(_ prepared: V2RoomWriteAuthorizationCoordinator.Prepared, now: Date) throws -> Self {
        var scoped = self
        scoped.controlResolution = .preparedWithoutGrants(roomKinds: prepared.roomKinds)
        if !prepared.grants.isEmpty {
            scoped = try scoped.usingAuthorizationGrants(prepared.grants, now: now)
        }
        return scoped
    }

    func operationBatchScopedStore(for command: V2SendMessageCommand) throws -> Self {
        if let execution = controlResolution.policyExecution {
            try execution.validate(command)
            return self
        }
        let roomID = try uuid(command.roomID)
        let senderID = try uuid(command.senderUserID)
        let messageID = try uuid(command.clientMessageID)
        var scoped = self
        scoped.controlResolution = .preparedWithoutGrants(roomKinds: controlResolution.roomKinds ?? [:])
        if let authorization = controlResolution.authorization {
            let key = V2RoomWriteAuthorizationBatch.operationKey(roomID: roomID, senderID: senderID, clientMessageID: messageID)
            if let grant = authorization.grants[key] {
                scoped = try scoped.usingAuthorizationGrants([grant], now: authorization.recordedAt)
            }
        }
        return scoped
    }

    private var transactionCoordinator: V2RoomWriteTransactionCoordinator {
        .init(database: database, ownership: transactionOwnership,
              hasActivationScope: activationScope != nil, authorization: controlResolution.authorization)
    }

    private func withRoomWriteTransaction<Result: Sendable>(
        _ operation: @escaping @Sendable (any Database) async throws -> Result
    ) async throws -> Result {
        try await transactionCoordinator.run(operation)
    }

    private func withRoomWriteTransactionWithFenceContext<Result: Sendable>(
        _ operation: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext?) async throws -> Result
    ) async throws -> Result {
        try await transactionCoordinator.runWithFenceContext(operation)
    }

    func validateAuthorizationCommand(_ command: V2SendMessageCommand) throws {
        if let execution = controlResolution.policyExecution { try execution.validate(command); return }
        guard let grants = authorizationGrants else { return }
        let roomID = try uuid(command.roomID), senderID = try uuid(command.senderUserID)
        if controlScopeRoomKinds?[roomID] == "group" { return }
        let key = authorizationOperationKey(roomID: roomID, senderID: senderID, clientMessageID: try uuid(command.clientMessageID))
        guard let grant = grants[key], command.fingerprint.version == 3,
              grant.attempt.fingerprint == command.fingerprint.digest else {
            throw V2DirectAuthorizationIntentError.identityConflict
        }
    }

    private func authorizationOperationKey(roomID: UUID, senderID: UUID, clientMessageID: UUID) -> String {
        [roomID, senderID, clientMessageID].map { $0.uuidString.lowercased() }.joined(separator: ":")
    }

    private func withDurableAuthorizations<Result: Sendable>(
        commands: [V2SendMessageCommand], controlDatabase: any Database, now: Date,
        operation: @escaping @Sendable (Self) async throws -> Result
    ) async throws -> Result {
        let coordinator = V2RoomWriteAuthorizationCoordinator(database: database,
            controlDatabase: controlDatabase, resolutionDatabase: authorizationResolutionDatabase)
        let prepared = try await coordinator.prepare(commands: commands, now: now)
        var scoped = self
        scoped.controlResolution = .preparedWithoutGrants(roomKinds: prepared.roomKinds)
        if !prepared.grants.isEmpty {
            scoped = try scoped.usingAuthorizationGrants(prepared.grants, now: now)
        }
        let result = try await operation(scoped)
        // Outer operation receipts have not committed. Their durable intents are
        // resolved by the owner-proof worker, never by a provisional write body.
        if prepared.grants.isEmpty || transactionOwnership.borrowsTransaction { return result }
        do { try await coordinator.acknowledge(prepared.grants, now: now) }
        catch {
            if activationScope != nil { throw V2RoomTransactionOutcomeUnknown() }
            throw error
        }
        return result
    }

    private func acknowledgeAuthorizations(_ grants: [V2DirectAuthorizationGrant], now: Date) async throws {
        try await V2RoomWriteAuthorizationCoordinator(database: database,
            controlDatabase: controlDatabase, resolutionDatabase: authorizationResolutionDatabase)
            .acknowledge(grants, now: now)
    }

    private var selectedOwnerGuard: V2RoomWriteSelectedOwnerGuard {
        .init(ownerSelection: ownerSelection, controlResolution: controlResolution)
    }

    private var scalarAcceptancePath: V2RoomWriteScalarAcceptancePath {
        .init(ownerGuard: selectedOwnerGuard, policyContext: directPolicyContext,
              strangerMessagePolicy: strangerMessagePolicy, contentReviewMode: contentReviewMode)
    }

    private var directPolicyContext: V2RoomWriteDirectPolicyContext {
        .init(controlPolicyScope: controlPolicyScope, controlScopeRoomKinds: controlScopeRoomKinds)
    }

    public func acceptOwnerValidated(
        request: V2RoomWriteRequest, ownerRoute: V2RoomShardRoute
    ) async throws -> V2SendMessageOutcome {
        guard request.command.forwardedFrom == nil else { throw V2RoomWriteStoreError.actorNotEligible }
        let scoped = try validatingOwners([.init(request: request, ownerRoute: ownerRoute)])
        return try await scoped.accept(command: request.command,
            capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now)
    }

    public func acceptForwardOwnerValidated(request: V2RoomWriteRequest, sourceRoomID: RoomID,
        sourceOwnerRoute: V2RoomShardRoute, targetOwnerRoute: V2RoomShardRoute) async throws -> V2SendMessageOutcome {
        guard request.command.forwardedFrom != nil else { throw V2RoomWriteStoreError.actorNotEligible }
        var scoped = try validatingOwners([.init(request: request, ownerRoute: targetOwnerRoute)])
        let source = try uuid(sourceRoomID)
        scoped.ownerSelection = try scoped.ownerSelection.selectingForwardSource(source, route: sourceOwnerRoute)
        return try await scoped.accept(command: request.command, capacityProfile: request.capacityProfile,
            identifiers: request.identifiers, now: request.now)
    }

    /// 将一对已预留的来源与目标房间及其台账一起接受。
    /// 回调不得再获取其他房间或数据库连接；它们在消息操作锁及规范房间/令牌锁之后，
    /// 于提交接受事实的同一事务内运行。控制授权在事务前准备，仅在提交后确认。
    func acceptActorForwardPair(
        request: V2RoomWriteRequest, sourceRoomID: RoomID,
        activationTokens: [V2RoomActivationToken],
        prepareLedger: @escaping @Sendable (any Database) async throws -> Void,
        recordLedger: @escaping @Sendable (V2SendMessageOutcome, any Database) async throws -> Void
    ) async throws -> V2SendMessageOutcome {
        let rooms = Set([sourceRoomID, request.command.roomID])
        guard request.command.forwardedFrom != nil, activationTokens.count == rooms.count,
              Set(activationTokens.map(\.roomID)) == rooms,
              v2PostgresTimestampCanEncode(request.now) else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let activation = try V2RoomActivationWriteScope(tokens: activationTokens)
        let routes = try Dictionary(uniqueKeysWithValues: activationTokens.map {
            (try uuid($0.roomID), try V2RoomShardRoute(shardID: $0.owner.shardID, epoch: $0.owner.epoch))
        })
        var scoped = self
        scoped.ownerSelection = try .actorForwardPair(
            activation: activation, routes: routes,
            source: uuid(sourceRoomID), target: uuid(request.command.roomID))
        return try await scoped.acceptPreparedActorForwardPair(request: request,
            prepareLedger: prepareLedger, recordLedger: recordLedger)
    }

    private func acceptPreparedActorForwardPair(
        request: V2RoomWriteRequest,
        prepareLedger: @escaping @Sendable (any Database) async throws -> Void,
        recordLedger: @escaping @Sendable (V2SendMessageOutcome, any Database) async throws -> Void
    ) async throws -> V2SendMessageOutcome {
        if let policies = policyAuthorizations, controlResolution.needsPreparation {
            guard let token = try activationScope?.token(for: uuid(request.command.roomID)) else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            do {
                let commit = try await policies.executeForward(command: request.command, token: token) { execution in
                    try await self.usingPolicyExecution(execution).withForwardBudget(command: request.command,
                        capacityProfile: request.capacityProfile, now: request.now) { scoped in
                        try await scoped.commitPreparedActorForwardPair(request: request,
                            prepareLedger: prepareLedger, recordLedger: recordLedger)
                    }
                }
                // The message and pair ledger have physically committed. Do
                // not retain authorization while updating local result caches.
                return try await finalizeCommittedAcceptance(command: request.command,
                    cacheKey: .init(roomID: uuid(request.command.roomID), senderID: uuid(request.command.senderUserID)),
                    commit: commit)
            } catch let rejection as LateShardAdmissionRejection {
                switch rejection {
                case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
                case .unavailable(let reason): return .unavailable(reason)
                }
            }
        }
        if let controlDatabase, controlResolution.needsPreparation {
            return try await withDurableAuthorizations(commands: [request.command],
                controlDatabase: controlDatabase, now: request.now) { scoped in
                try await scoped.acceptPreparedActorForwardPair(request: request,
                    prepareLedger: prepareLedger, recordLedger: recordLedger)
            }
        }
        let commit: RoomWriteCommit
        do {
            commit = try await commitPreparedActorForwardPair(request: request,
                prepareLedger: prepareLedger, recordLedger: recordLedger)
        } catch let rejection as LateShardAdmissionRejection {
            // 成对台账与消息效果一起回滚。
            switch rejection {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            }
        }
        return try await finalizeCommittedAcceptance(command: request.command,
            cacheKey: .init(roomID: uuid(request.command.roomID), senderID: uuid(request.command.senderUserID)), commit: commit)
    }

    private func commitPreparedActorForwardPair(
        request: V2RoomWriteRequest,
        prepareLedger: @escaping @Sendable (any Database) async throws -> Void,
        recordLedger: @escaping @Sendable (V2SendMessageOutcome, any Database) async throws -> Void
    ) async throws -> RoomWriteCommit {
        try validateAuthorizationCommand(request.command)
        let room = try uuid(request.command.roomID), sender = try uuid(request.command.senderUserID)
        guard let source = forwardOwnerSourceRoomID else { throw V2RoomActivationLeaseError.activationChanged }
        return try await withRoomWriteTransaction { transaction in
            let sql = try sqlDatabase(from: transaction)
            try await acquireMessageOperationLock(roomID: room, senderID: sender,
                clientMessageID: uuid(request.command.clientMessageID), sql: sql)
            try await requireSelectedOwners([source, room], sql: sql)
            try await prepareLedger(transaction)
            let accepted = try await scalarAcceptancePath.acceptInTransaction(command: request.command,
                capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now,
                roomID: room, senderID: sender, cachedDirectPolicy: nil,
                sql: sql)
            try await recordLedger(accepted.outcome, transaction)
            return accepted
        }
    }

    public func acceptAtomicallyOwnerValidated(
        requests: [V2OwnerValidatedRoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        guard requests.allSatisfy({ $0.request.command.forwardedFrom == nil }) else { throw V2RoomWriteStoreError.actorNotEligible }
        let scoped = try validatingOwners(requests)
        return try await scoped.acceptAtomically(requests: requests.map(\.request))
    }

    private func validatingOwners(_ requests: [V2OwnerValidatedRoomWriteRequest]) throws -> Self {
        var routes: [UUID: V2RoomShardRoute] = [:]
        for input in requests {
            let room = try uuid(input.request.command.roomID)
            if let previous = routes[room], previous != input.ownerRoute {
                throw V2RoomOwnerFenceError.ownerChanged
            }
            routes[room] = input.ownerRoute
        }
        var scoped = self
        scoped.ownerSelection = try ownerSelection.selectingRoutes(routes)
        return scoped
    }

    func requireSelectedOwners(_ roomIDs: [UUID], sql: any SQLDatabase) async throws {
        if let scope = activationScope, scope.reliesOnRuntimeLifecycle {
            for room in Set(roomIDs) { _ = try scope.token(for: room) }
            return
        }
        try await selectedOwnerGuard.requireSelectedOwners(roomIDs, sql: sql)
    }

    public func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        do {
            guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let roomID = try uuid(command.roomID)
            let senderID = try uuid(command.senderUserID)
            _ = try activationScope?.token(for: roomID)
            if activationScope != nil, command.forwardedFrom != nil,
               forwardOwnerSourceRoomID == nil {
                throw V2RoomActivationLeaseError.activationChanged
            }
            try validateAuthorizationCommand(command)
            if let controlDatabase, controlResolution.needsPreparation {
                do {
                    return try await withDurableAuthorizations(commands: [command], controlDatabase: controlDatabase, now: now) { scoped in
                        try await scoped.accept(command: command, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
                    }
                } catch V2DirectAuthorizationIntentError.identityConflict {
                    return .idempotencyConflict
                }
            }
            let cacheKey = V2DirectSendPolicyCache.Key(roomID: roomID, senderID: senderID)
            let cachedDirectPolicy = await directSendPolicyCache.value(for: cacheKey)
            let commit = try await acceptanceCommit(
                command: command,
                capacityProfile: capacityProfile,
                identifiers: identifiers,
                now: now,
                roomID: roomID,
                senderID: senderID,
                cachedDirectPolicy: cachedDirectPolicy
            )
            return try await finalizeCommittedAcceptance(
                command: command,
                cacheKey: cacheKey,
                commit: commit
            )
        } catch {
            // The single-command transaction can attribute this named trigger
            // to its exact operation. Atomic batches retain their own fallback.
            throw v2NormalizeMessageOperationClosed(error)
        }
    }

    /// 受信的归属者到归属者导入。
    ///
    /// 持久收件箱只授权这一份确切的导出；普通 SendMessage 绝不会获得导入能力。
    ///
    /// - Parameters:
    ///   - export: 待导入的转发导出。
    ///   - capacityProfile: 本次导入使用的容量档位。
    ///   - limits: 消息命令限制。
    ///   - identifiers: 接受标识集合。
    /// - Returns: 导入结果。
    /// - Throws: 收件箱未授权、容量不足或持久化失败时抛出。
    public func importForwardExport(
        _ export: V2ForwardExport,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2ForwardImportOutcome {
        var inbox = PostgresV2ForwardInboxStore(database: database)
        if let token = try activationScope?.token(for: export.intent.targetRoomID) {
            inbox = try inbox.usingActivationToken(token)
        }
        try await inbox.receive(export, now: now)
        do {
            return try await importReceivedForwardExport(export, capacityProfile: capacityProfile,
                limits: limits, identifiers: identifiers, now: now)
        } catch {
            // 接收阶段已提交持久化的工作流事实。后续失败不能证明整个处理轮次已回滚；
            // 保留操作标识，并在下次激活时通过收件箱恢复。
            if activationScope != nil { throw V2RoomTransactionOutcomeUnknown() }
            throw error
        }
    }

    /// Actor 入口将所有阶段（包括不可变回执的重放）绑定到目标的确切实例，
    /// 但不会授予源房间权限。
    public func importForwardExport(
        _ export: V2ForwardExport,
        activationToken: V2RoomActivationToken,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2ForwardImportOutcome {
        guard activationToken.roomID.uuidValue == export.intent.targetRoomID,
              activationToken.owner.shardID == export.intent.targetShardID,
              activationToken.owner.epoch == export.intent.targetEpoch else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        return try await usingActivationScope(.init(tokens: [activationToken]))
            .importForwardExport(export, capacityProfile: capacityProfile, limits: limits,
                identifiers: identifiers, now: now)
    }

    private func importReceivedForwardExport(
        _ export: V2ForwardExport,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2ForwardImportOutcome {
        if let policies = policyAuthorizations, controlResolution.needsPreparation {
            guard let token = try activationScope?.token(for: export.intent.targetRoomID) else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            let preflight = try await withRoomWriteTransaction { transaction in
                try await V2RoomWriteForwardInboxPath(activationScope: activationScope)
                    .preflight(export: export, transaction: transaction)
            }
            if let outcome = preflight.1 { return outcome }
            guard let command = preflight.0 else { throw V2ForwardInboxError.corruptPersistenceState }
            if let commit = preflight.2 {
                return try await completeReceivedForwardExport(export, command: command, commit: commit, now: now)
            }
            let prepared: (outcome: V2ForwardImportOutcome, command: V2SendMessageCommand?, commit: RoomWriteCommit?)
            do {
                prepared = try await policies.executeForward(command: command, token: token) { execution in
                    try await self.usingPolicyExecution(execution).withForwardBudget(command: command,
                        capacityProfile: capacityProfile, now: now) { scoped in
                        try await scoped.acceptReceivedForwardExport(export, capacityProfile: capacityProfile,
                            limits: limits, identifiers: identifiers, now: now)
                    }
                }
            } catch is LateShardAdmissionRejection { return .pending(.admission) }
            // executeForward has joined actual acceptance COMMIT and settled
            // its permit. Finalization uses the immutable accepted receipt.
            guard let acceptedCommand = prepared.command, let commit = prepared.commit else { return prepared.outcome }
            return try await completeReceivedForwardExport(export, command: acceptedCommand, commit: commit, now: now)
        }
        if let controlDatabase, controlResolution.needsPreparation {
            // 此处仅检查所有者的简短预检会在控制侧预留之前结束。
            // 下方的接受事务会在写入任何消息前重新检查收件箱、媒体映射、
            // 命令的精确指纹和所有者。
            let preflight = try await withRoomWriteTransaction { transaction in
                try await V2RoomWriteForwardInboxPath(activationScope: activationScope)
                    .preflight(export: export, transaction: transaction)
            }
            if let outcome = preflight.1 {
                switch outcome {
                case .accepted, .rejected:
                    // 收件箱完成后的 ACK 失败可直接恢复，无须再次解码载荷或媒体，
                    // 也无须预留新的代次。
                    guard let acknowledgement = authorizationResolutionDatabase else { throw V2DirectAuthorizationCoordinationError.ownerUnavailable }
                    do {
                        if let grant = try await PostgresV2DirectAuthorizationIntentStore(database: acknowledgement)
                            .existing(roomID: export.intent.targetRoomID, senderID: export.intent.actorUserID,
                                      clientMessageID: export.intent.targetClientMessageID), grant.receipt == nil {
                            try await acknowledgeAuthorizations([grant], now: now)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { throw V2DirectAuthorizationCoordinationError.ownerUnavailable }
                case .pending: break
                }
                return outcome
            }
            guard let command = preflight.0 else { throw V2ForwardInboxError.corruptPersistenceState }
            do {
                return try await withDurableAuthorizations(commands: [command], controlDatabase: controlDatabase, now: now) { scoped in
                    try await scoped.importForwardExport(export, capacityProfile: capacityProfile, limits: limits,
                        identifiers: identifiers, now: now)
                }
            } catch V2DirectAuthorizationIntentError.identityConflict {
                throw V2ForwardInboxError.idempotencyConflict
            }
        }
        let prepared = try await acceptReceivedForwardExport(export, capacityProfile: capacityProfile,
            limits: limits, identifiers: identifiers, now: now)
        guard let command = prepared.command, let commit = prepared.commit else { return prepared.outcome }
        return try await completeReceivedForwardExport(export, command: command, commit: commit, now: now)
    }

    private func acceptReceivedForwardExport(_ export: V2ForwardExport, capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits, identifiers: V2AcceptanceIdentifiers, now: Date) async throws
        -> (outcome: V2ForwardImportOutcome, command: V2SendMessageCommand?, commit: RoomWriteCommit?) {
        do {
            return try await withRoomWriteTransaction { transaction in
                try await V2RoomWriteForwardInboxPath(activationScope: activationScope).accept(
                    export: export, limits: limits, now: now, transaction: transaction,
                    operations: .init(
                        acquireOperationLock: { roomID, senderID, clientMessageID, sql in
                            try await acquireMessageOperationLock(roomID: roomID, senderID: senderID,
                                clientMessageID: clientMessageID, sql: sql)
                        },
                        validateCommand: { command in try validateAuthorizationCommand(command) },
                        acceptMessage: { command, authority, transaction in
                            try await scalarAcceptancePath.acceptInTransaction(
                                command: command, capacityProfile: capacityProfile,
                                identifiers: identifiers, now: now,
                                roomID: export.intent.targetRoomID,
                                senderID: export.intent.actorUserID,
                                cachedDirectPolicy: nil, importedForward: authority,
                                sql: try sqlDatabase(from: transaction)
                            )
                        }
                    )
                )
            }
        } catch is LateShardAdmissionRejection {
            // 消息、完成记录、准入计数器和收件箱更新均已回滚。
            // 此前的接收记录仍安全地保持待处理状态。
            return (.pending(.admission), nil, nil)
        }
    }

    private func completeReceivedForwardExport(_ export: V2ForwardExport, command: V2SendMessageCommand,
                                              commit: RoomWriteCommit, now: Date) async throws -> V2ForwardImportOutcome {
        _ = try await finalizeCommittedAcceptance(
            command: command,
            cacheKey: .init(roomID: export.intent.targetRoomID, senderID: export.intent.actorUserID), commit: commit
        )
        // 若在此状态转换前崩溃或完成事务失败，已接受的回执仍会持久保存。
        // 重试会先从 message_send_completions 恢复通常的提交后工作，
        // 再向目标方呈现成功结果。
        return try await withRoomWriteTransaction { transaction in
            try await V2RoomWriteForwardInboxPath(activationScope: activationScope)
                .complete(export: export, commit: commit, now: now, transaction: transaction)
        }
    }

    private func withForwardBudget<Value: Sendable>(command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile, now: Date,
        operation: @Sendable (Self) async throws -> Value) async throws -> Value {
        return try await operation(self)
    }

    private struct ForwardBudgetRow: Decodable, Sendable {
        let shard_id: String; let lease_id: UUID; let generation: Int64; let valid_until: Date
        let command_window_limit: Int; let command_window_used: Int; let completed: Bool
    }

    /// 判断各请求是否可用于原子批处理。
    ///
    /// 兼容的冷命令可以进入权威标准批次；
    /// 受修订围栏保护的热命令可以进入加速批次。
    /// 这两种分类都不是授权决定。
    /// 两条路径在追加之前都会重新锁定并校验持久策略行。
    ///
    /// - Parameter requests: 待分类的房间写入请求。
    /// - Returns: 与 `requests` 顺序一致的资格判定。
    public func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool] {
        let partitions = await atomicBatchPartitions(requests: requests)
        return partitions.map { $0 != nil }
    }

    public func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) async -> [V2AtomicRoomWriteBatchPartition?] {
        guard !contentReviewMode.enqueuesJobs else { return Array(repeating: nil, count: requests.count) }
        let rooms = requests.map { try? uuid($0.command.roomID) }
        let routes = await resolvedRoomWriteBatchRoutes(roomIDs: rooms.compactMap { $0 })
        var routeIndex = 0
        return zip(requests, rooms).map { request, room in
            guard room != nil else { return nil }
            let route = routes[routeIndex]
            routeIndex += 1
            guard v2PostgresTimestampCanEncode(request.now),
                  V2RoomWriteFastDirectEligibility.acceptsBatchShape(request) else { return nil }
            switch route {
            case .direct: return .standard
            case .large: return .large
            default: return nil
            }
        }
    }

    public func atomicBatchSupportsRepeatedRooms(
        in partition: V2AtomicRoomWriteBatchPartition
    ) async -> Bool {
        true
    }

    private func resolvedRoomWriteBatchRoutes(roomIDs: [UUID]) async -> [V2RoomWriteBatchRouteCache.Route?] {
        await V2RoomWriteBatchRouteResolver(database: database, cache: roomWriteBatchRouteCache).resolve(roomIDs: roomIDs)
    }

    /// 持有单条逻辑命令的重试边界。
    ///
    /// 事务主体刻意独立出来，使有序批次可以复用完全相同的加锁、授权与幂等代码，
    /// 而不会产生嵌套事务。
    ///
    /// - Parameters:
    ///   - command: 待接受的发送消息命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - identifiers: 接受标识集合。
    ///   - now: 服务端统一授时时刻。
    ///   - roomID: 目标房间标识。
    ///   - senderID: 发送者标识。
    ///   - cachedDirectPolicy: 可选的单聊策略缓存条目。
    /// - Returns: 房间写入提交结果。
    /// - Throws: 准入拒绝或持久化失败时抛出。
    private func acceptanceCommit(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date,
        roomID: UUID,
        senderID: UUID,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        deferShardAdmission: Bool = false,
        priorShardAdmissionReservations: [ShardAdmissionReservation] = []
    ) async throws -> RoomWriteCommit {
        do {
            return try await withRoomWriteTransactionWithFenceContext { transaction, fenceContext in
                try await scalarAcceptancePath.acceptInTransaction(
                    command: command,
                    capacityProfile: capacityProfile,
                    identifiers: identifiers,
                    now: now,
                    roomID: roomID,
                    senderID: senderID,
                    cachedDirectPolicy: cachedDirectPolicy,
                    fenceContext: fenceContext,
                    deferShardAdmission: deferShardAdmission,
                    priorShardAdmissionReservations: priorShardAdmissionReservations,
                    sql: try sqlDatabase(from: transaction)
                )
            }
        } catch let rejection as LateShardAdmissionRejection {
            switch rejection {
            case .rateLimited(let retryAfterSeconds):
                return .init(
                    outcome: .rateLimited(retryAfterSeconds: retryAfterSeconds)
                )
            case .unavailable(let reason):
                return .init(outcome: .unavailable(reason))
            }
        }
    }

    /// Durable sendOperation 批次专用接受入口。
    ///
    /// 它沿用当前借用事务中的完整标量路径。
    /// 只有外层操作事务提交后，调用方才能观察到该接受结果。
    func acceptForOperationBatch(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date,
        priorShardAdmissionReservations: [ShardAdmissionReservation] = []
    ) async throws -> (outcome: V2SendMessageOutcome, shardAdmissionReservation: ShardAdmissionReservation?) {
        guard transactionOwnership.borrowsTransaction,
              v2PostgresTimestampCanEncode(now) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let roomID = try uuid(command.roomID)
        let senderID = try uuid(command.senderUserID)
        _ = try activationScope?.token(for: roomID)
        try validateAuthorizationCommand(command)
        let cacheKey = V2DirectSendPolicyCache.Key(roomID: roomID, senderID: senderID)
        let cachedDirectPolicy = await directSendPolicyCache.value(for: cacheKey)
        let commit = try await acceptanceCommit(
            command: command,
            capacityProfile: capacityProfile,
            identifiers: identifiers,
            now: now,
            roomID: roomID,
            senderID: senderID,
            cachedDirectPolicy: cachedDirectPolicy,
            deferShardAdmission: true,
            priorShardAdmissionReservations: priorShardAdmissionReservations
        )
        let outcome = try await commitEffects.finalize(command: command, cacheKey: cacheKey, commit: commit)
        return (outcome, commit.shardAdmissionReservation)
    }

    /// 一起提交一具有界的普通单聊房间日志消息。
    ///
    /// 只接受纯消息传输形态：没有附件、@ 扇出，也没有回复/转发依赖。
    ///
    /// 批次按房间顺序共用一份事务，处理陌生人权限、首次回复及资料/能力效果。
    /// 任何不受支持的结果都会回滚整批，随后由批处理器逐条重试。
    ///
    /// - Parameter requests: 本批房间写入请求。
    /// - Returns: 与请求顺序对应的发送结果。
    /// - Throws: 配置不兼容、持久化状态损坏或写入失败时抛出。
    public func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        do {
            return try await acceptAtomicallyWithStorageChecks(requests:requests)
        } catch where v2IsMessageOperationClosed(error) {
            // The named PostgreSQL trigger aborted this transaction. Its permanent
            // negative receipt belongs to one operation, never to every batch member.
            // The batcher preserves room order when falling back to individual writes.
            throw V2AtomicRoomWriteBatchError(reason:.preflightMismatch)
        }
    }

    private func acceptAtomicallyWithStorageChecks(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        for request in requests { _ = try activationScope?.token(for: uuid(request.command.roomID)) }
        for request in requests { try validateAuthorizationCommand(request.command) }
        if let controlDatabase, controlResolution.needsPreparation {
            guard requests.count >= 2, requests.count <= 128 else { throw V2DirectSendControlPolicyError.invalidBatch }
            guard requests.allSatisfy({ v2PostgresTimestampCanEncode($0.now) }),
                  let authorizationTime = requests.map(\.now).max() else {
                throw V2AtomicRoomWriteBatchError(reason: .requestShape)
            }
            let operations = try requests.map { authorizationOperationKey(roomID: try uuid($0.command.roomID),
                senderID: try uuid($0.command.senderUserID), clientMessageID: try uuid($0.command.clientMessageID)) }
            guard Set(operations).count == operations.count else { throw V2AtomicRoomWriteBatchError(reason: .duplicateOperation) }
            do {
                return try await withDurableAuthorizations(commands: requests.map(\.command), controlDatabase: controlDatabase, now: authorizationTime) { scoped in
                    try await scoped.acceptAtomically(requests: requests)
                }
            } catch V2DirectAuthorizationIntentError.identityConflict {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
        }
        guard requests.count >= 2, requests.count <= 128,
              !contentReviewMode.enqueuesJobs else {
            throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
        }
        guard requests.allSatisfy({ v2PostgresTimestampCanEncode($0.now) && V2RoomWriteFastDirectEligibility.acceptsBatchShape($0) }) else {
            throw V2AtomicRoomWriteBatchError(reason: .requestShape)
        }
        let operationKeys = try requests.map { authorizationOperationKey(roomID: try uuid($0.command.roomID),
            senderID: try uuid($0.command.senderUserID), clientMessageID: try uuid($0.command.clientMessageID)) }
        guard Set(operationKeys).count == operationKeys.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateOperation)
        }
        let committed = try await withRoomWriteTransaction { transaction in
            let sql = try sqlDatabase(from: transaction)
            let sorted = requests.indices.sorted { operationKeys[$0] < operationKeys[$1] }
            for index in sorted {
                let command = requests[index].command
                try await acquireMessageOperationLock(roomID: uuid(command.roomID), senderID: uuid(command.senderUserID),
                    clientMessageID: uuid(command.clientMessageID), sql: sql)
            }
            try await requireSelectedOwners(requests.map { try uuid($0.command.roomID) }, sql: sql)
            var commits: [OrderedRoomWriteCommit] = []
            for (index, request) in requests.enumerated() {
                let roomID = try uuid(request.command.roomID), senderID = try uuid(request.command.senderUserID)
                let commit: RoomWriteCommit
                do {
                    commit = try await scalarAcceptancePath.acceptInTransaction(command: request.command,
                        capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now,
                        roomID: roomID, senderID: senderID, cachedDirectPolicy: nil, sql: sql)
                } catch let error as V2RoomWriteStoreError where error != .corruptPersistenceState {
                    throw V2AtomicRoomWriteBatchError(reason: .authorizationState, isolatedRequestIndices: [index])
                }
                guard case .accepted = commit.outcome else {
                    throw V2AtomicRoomWriteBatchError(reason: .authorizationState, isolatedRequestIndices: [index])
                }
                commits.append(.init(originalIndex: index, cacheKey: .init(roomID: roomID, senderID: senderID), commit: commit))
            }
            return commits
        }
        return try await finalizeCommittedAcceptances(requests: requests, committed: committed)
    }

    private func sqlDatabase(from transaction: any Database) throws -> any SQLDatabase {
        guard let sql = transaction as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return sql
    }

    /// 只在 Fluent 已提交源事务之后运行。
    ///
    /// 把这些进程本地缓存收尾放在 SQL 接受边界之外，
    /// 才能让未来的原子批次先提交全部规范房间记录，
    /// 再逐条收尾客户端结果，而不会确认一个尚未提交的前缀。
    ///
    /// - Parameters:
    ///   - command: 已提交的发送命令。
    ///   - commit: 对应的房间写入提交结果。
    /// - Returns: 客户端可见的发送结果。
    /// - Throws: 已提交结果无法解码时抛出。
    private var commitEffects: V2RoomWriteCommitEffects {
        .init(ownership: transactionOwnership, directSendPolicyCache: directSendPolicyCache,
              appendStageMetrics: appendStageMetrics)
    }

    private func finalizeCommittedAcceptance(
        command: V2SendMessageCommand,
        cacheKey: V2DirectSendPolicyCache.Key,
        commit: RoomWriteCommit
    ) async throws -> V2SendMessageOutcome {
        do {
            return try await commitEffects.finalize(command: command, cacheKey: cacheKey, commit: commit)
        } catch {
            if activationScope != nil { throw V2RoomTransactionOutcomeUnknown() }
            throw error
        }
    }

    /// 收尾一个已提交微批，且无需为每条消息付出多次 actor 跳转。
    ///
    /// 每次更新都是进程本地或幂等的，且严格发生在 PostgreSQL 提交之后；
    /// 个人事件由已提交的可靠待办异步投递，不阻塞消息确认。
    ///
    /// - Parameters:
    ///   - requests: 本批房间写入请求。
    ///   - committed: 已提交的有序结果。
    /// - Returns: 与请求顺序对应的发送结果。
    /// - Throws: 持久化结果损坏时抛出。
    private func finalizeCommittedAcceptances(
        requests: [V2RoomWriteRequest],
        committed: [OrderedRoomWriteCommit]
    ) async throws -> [V2SendMessageOutcome] {
        do {
            return try await commitEffects.finalize(requests: requests, committed: committed)
        } catch {
            if activationScope != nil { throw V2RoomTransactionOutcomeUnknown() }
            throw error
        }
    }

    /// 在独立语句中获取操作围栏。
    ///
    /// PostgreSQL 会在求值 CTE 之前固定语句快照；
    /// 因此在并发发送方释放该锁之后，随后的读取必须从新快照开始，
    /// 才能观察到已提交的幂等结果。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - senderID: 发送者标识。
    ///   - clientMessageID: 客户端消息标识。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 加锁失败时抛出。
    func acquireMessageOperationLock(
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        sql: any SQLDatabase
    ) async throws {
        if activationScope?.reliesOnRuntimeLifecycle != true {
            try await v2AcquireMessageOperationLock(roomID: roomID, senderID: senderID,
                clientMessageID: clientMessageID, sql: sql)
        }
        try await selectedOwnerGuard.prepareAuthorization(roomID: roomID, senderID: senderID, clientMessageID: clientMessageID, sql: sql)
    }

    /// 在单条语句中获取整个已排序微批的幂等围栏。
    ///
    /// 递归依赖是刻意的：它向 PostgreSQL 显式表达加锁顺序，
    /// 而不是依赖集合返回查询偶然的执行器顺序。
    /// 调用方必须把其权威预检作为*下一条*语句发出，
    /// 以获得加锁后的新快照。
    ///
    /// - Parameter ordered: 已排序的房间写入请求。
    /// - Throws: 加锁失败时抛出。
    private func acquireMessageOperationLocks(
        _ ordered: [OrderedRoomWriteRequest],
        sql: any SQLDatabase
    ) async throws {
        if activationScope?.reliesOnRuntimeLifecycle == true { return }
        guard !ordered.isEmpty,
              ordered.enumerated().allSatisfy({ $0.offset == $0.element.preflightOrdinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let inputs = try ordered.enumerated().map { ordinal, item in
            MessageOperationLockInput(
                ordinal: ordinal,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: try uuid(item.request.command.clientMessageID)
            )
        }
        // 生产环境的 PostgreSQL 通过命名语句接收有类型的数组，省去 JSON
        // 序列化与解析，并让每条前台物理连接复用固定的递归加锁方案，
        // 同时保持事务和有序加锁契约不变。
        if let postgres = sql as? any PostgresDatabase {
            let statement = MessageOperationLockBatchStatement(inputs: inputs)
            let acquiredCount = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let rows = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var result: Int64?
                    for try await row in rows {
                        guard result == nil else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        result = row
                    }
                    return result
                }
            }.get()
            guard acquiredCount == Int64(inputs.count) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await prepareBatchAuthorizations(inputs, sql: sql)
            return
        }
        let inputsJSON = try roomWriteJSON(inputs)
        let expectedCount = Int64(inputs.count)
        guard let row = try await sql.raw("""
            WITH RECURSIVE key_input AS MATERIALIZED (
                SELECT input.ordinal,
                       hashtextextended(
                           'v2-message-operation:' || input.room_id::text || ':' || input.sender_id::text || ':' || input.client_message_id::text,
                           0
                       ) AS lock_key
                FROM jsonb_to_recordset(\(bind: inputsJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    client_message_id uuid
                )
            ), \(unsafeRaw: MessageOperationLockBatchStatement.orderedLocksSQL)
            """).first(decoding: MessageOperationLockBatchRow.self),
              row.acquiredCount == expectedCount
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await prepareBatchAuthorizations(inputs, sql: sql)
    }

    private func prepareBatchAuthorizations(_ inputs: [MessageOperationLockInput], sql: any SQLDatabase) async throws {
        guard authorizationGrants != nil || controlResolution.policyExecution != nil else { return }
        let ordered = inputs.sorted {
            authorizationOperationKey(roomID: $0.roomID, senderID: $0.senderID, clientMessageID: $0.clientMessageID)
                < authorizationOperationKey(roomID: $1.roomID, senderID: $1.senderID, clientMessageID: $1.clientMessageID)
        }
        for input in ordered {
            try await selectedOwnerGuard.prepareAuthorization(roomID: input.roomID, senderID: input.senderID, clientMessageID: input.clientMessageID, sql: sql)
        }
    }

}

extension V2SendMessageAcceptanceResult {
    func outcome(
        mediaPresentations: [V2MediaPresentation] = [],
        groupCapacityClass: V2GroupCapacityClass? = nil
    ) -> V2SendMessageOutcome {
        switch self {
        case .accepted:
            preconditionFailure("accepted transactions must be persisted before becoming a send outcome")
        case .idempotent(let message): .idempotent(message.materialized(
            mediaPresentations: mediaPresentations,
            groupCapacityClass: groupCapacityClass
        ).receipt)
        case .idempotencyConflict: .idempotencyConflict
        case .rateLimited(let seconds): .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}

/// 在相加之前先检查已持久化的取值范围：
/// 把一个已经溢出的有符号表达式再转换回来，是无法恢复出合法协议序号的。
///
/// - Parameter current: 当前已持久化的序号。
/// - Returns: 加一后的序号。
/// - Throws: 当前值超出可编码范围时抛出。
func roomWriteNextSequence(_ current: Int64) throws -> UInt64 {
    guard current >= 0, current < Int64.max else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return UInt64(current + 1)
}

func roomLogReduction(
    command: V2SendMessageCommand,
    roomState: V2RoomCommandState,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    now: Date
) throws -> V2SendMessageAcceptanceResult {
    guard roomState.roomID == command.roomID, roomState.nextRoomSequence > 0,
          roomState.nextRoomSequence <= UInt64(Int64.max) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    do {
        let nextAdmission = roomState.admission
        let nextShard = shardState
        let accepted = V2AcceptedMessageDraft(
            messageID: identifiers.messageID,
            roomID: command.roomID,
            roomSequence: roomState.nextRoomSequence,
            senderUserID: command.senderUserID,
            clientMessageID: command.clientMessageID,
            text: command.text,
            media: command.media,
            mentions: command.mentions,
            entities: command.entities,
            replyTo: command.replyTo,
            createdAt: now
        )
        let nextRoom = V2RoomCommandState(
            roomID: roomState.roomID,
            nextRoomSequence: roomState.nextRoomSequence + 1,
            admission: nextAdmission
        )
        return .accepted(.init(
            acceptedMessage: accepted,
            eventID: identifiers.eventID,
            nextRoomState: nextRoom,
            nextShardState: nextShard
        ))
    }
}

func mentionTargetJSON(_ userIDs: [UUID]) throws -> String {
    let values = userIDs.map(\.uuidString)
    let data = try JSONEncoder().encode(values)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

func roomWriteJSON<Value: Encodable>(_ value: Value) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

struct OrderedMediaReferenceInput: Encodable {
    let ordinal: Int
    let mediaID: UUID

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mediaID = "media_id"
    }
}

enum LateShardAdmissionRejection: Error, Sendable {
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2CommandAdmissionUnavailableReason)
}

struct ShardAdmissionMutationRow: Decodable {
    let applied: Int
}

struct ShardAdmissionReservation: Sendable {
    let leaseID: UUID
    let generation: Int64
    let commandDelta: Int
    let roomShardID: String?
    let capacityProfileID: String?

    init(leaseID: UUID, generation: Int64, commandDelta: Int,
         roomShardID: String? = nil, capacityProfileID: String? = nil) {
        self.leaseID = leaseID
        self.generation = generation
        self.commandDelta = commandDelta
        self.roomShardID = roomShardID
        self.capacityProfileID = capacityProfileID
    }
}

struct CurrentShardLeaseRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case generation
        case validUntil = "valid_until"
    }
}

/// 集合式普通单聊房间日志追加所用的 JSONB 输入。
///
/// 它刻意收窄：附件、@ 提及与审核任务仍走各自的专用路径，
/// 直到它们各自的批量写图被设计并验证为止。
struct V2RoomWriteRuntimeGuard: Encodable {
    let capacityProfileID: String
}

struct PlainRoomLogMessageInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let messageID: UUID
    let eventID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    /// 冷房间会在追加事务中更新其持久行；
    /// 热房间则已经改用一个有界的命令额度批次完成扣费。
    let persistsRoomAdmission: Bool
    let roomSequence: Int64
    let timelineSequence: Int64
    let commandWindowUsed: Int
    let text: String
    let entities: [V2MessageEntity]
    let replyToMessageID: UUID?
    let forwardedFromMessageID: UUID?
    let forwardedFromUserID: UUID?
    let membershipRevision: Int64
    let fingerprint: V2SendMessageFingerprint
    let createdAtPostgresMicroseconds: Int64
    var runtimeGuard: V2RoomWriteRuntimeGuard? = nil
    var directRecipientID: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case runtimeGuard = "runtime_guard"
        case directRecipientID = "direct_recipient_id"
        case ordinal
        case roomID = "room_id"
        case messageID = "message_id"
        case eventID = "event_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case persistsRoomAdmission = "persists_room_admission"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case commandWindowUsed = "command_window_used"
        case text = "text_body"
        case entities = "rich_entities"
        case replyToMessageID = "reply_to_message_id"
        case forwardedFromMessageID = "forwarded_from_message_id"
        case forwardedFromUserID = "forwarded_from_user_id"
        case membershipRevision = "membership_revision"
        case fingerprint
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
    }

    func withOrdinal(_ ordinal: Int) -> Self {
        .init(
            ordinal: ordinal,
            roomID: roomID,
            messageID: messageID,
            eventID: eventID,
            senderID: senderID,
            clientMessageID: clientMessageID,
            persistsRoomAdmission: persistsRoomAdmission,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            commandWindowUsed: commandWindowUsed,
            text: text,
            entities: entities,
            replyToMessageID: replyToMessageID,
            forwardedFromMessageID: forwardedFromMessageID,
            forwardedFromUserID: forwardedFromUserID,
            membershipRevision: membershipRevision,
            fingerprint: fingerprint,
            createdAtPostgresMicroseconds: createdAtPostgresMicroseconds,
            runtimeGuard: runtimeGuard,
            directRecipientID: directRecipientID
        )
    }
}

struct OrderedRoomWriteRequest {
    let originalIndex: Int
    let request: V2RoomWriteRequest
    let roomID: UUID
    let senderID: UUID
    let cacheKey: V2DirectSendPolicyCache.Key
    let cachedDirectPolicy: V2DirectSendPolicyCache.Entry?
    let usesRoomAdmissionCredits: Bool
    let preflightOrdinal: Int
}

struct OrderedRoomWriteCommit: Sendable {
    let originalIndex: Int
    let cacheKey: V2DirectSendPolicyCache.Key
    let commit: RoomWriteCommit
}

struct PreparedDirectRoomLogAppend {
    let originalIndex: Int
    let request: V2RoomWriteRequest
    let cacheKey: V2DirectSendPolicyCache.Key
    let roomID: UUID
    let senderID: UUID
    let input: PlainRoomLogMessageInput
    let now: Date
    let directContext: DirectMessageAcceptanceContext
    let policyCacheEntry: V2DirectSendPolicyCache.Entry
    let advancesReplyMarker: Bool
    let commit: RoomWriteCommit
    var publishesPolicyHints: Bool = true
}

struct AuthorizationRow: Decodable { let authorized: Bool }
struct DirectMessageAcceptanceContext: Sendable {
    let recipientID: UUID
    let restriction: V2DirectMessageDenied.Reason?
    let requiresStrangerQuota: Bool
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let senderHasReplied: Bool
    let supportAccountID: UUID?
}
struct DirectReplyCacheUpdate {
    let key: V2DirectSendPolicyCache.Key
    let expectedDirectPairRevision: Int64
}
struct RoomWriteCommit: Sendable {
    let outcome: V2SendMessageOutcome
    let directPolicyCacheUpdate: V2DirectSendPolicyCache.Entry?
    /// 当本次提交设置了某一侧单调的首次发送标记时，
    /// 反方向的缓存可以从紧邻其前的配对修订推进，而无需再做一次完整策略读取。
    ///
    /// PostgreSQL 的修订谓词对之后每一次快速追加仍是权威。
    let reciprocalDirectReplyCacheUpdate: DirectReplyCacheUpdate?
    /// 操作批次可在所有消息与回执写完后统一结算的分片成本。
    /// 普通接受路径已在此提交对象返回前结算，因此此值为空。
    let shardAdmissionReservation: ShardAdmissionReservation?
    init(
        outcome: V2SendMessageOutcome,
        directPolicyCacheUpdate: V2DirectSendPolicyCache.Entry? = nil,
        reciprocalDirectReplyCacheUpdate: DirectReplyCacheUpdate? = nil,
        shardAdmissionReservation: ShardAdmissionReservation? = nil
    ) {
        self.outcome = outcome
        self.directPolicyCacheUpdate = directPolicyCacheUpdate
        self.reciprocalDirectReplyCacheUpdate = reciprocalDirectReplyCacheUpdate
        self.shardAdmissionReservation = shardAdmissionReservation
    }
}
struct DirectPostAcceptanceProjectionChanges {
    let senderCapabilityInserted: Bool
    let recipientProfileInserted: Bool
}
struct DirectCapabilityMutationRow: Decodable {
    let insertedCount: Int64
    let pairCount: Int64
    enum CodingKeys: String, CodingKey {
        case insertedCount = "inserted_count"
        case pairCount = "pair_count"
    }
}

struct DirectMessageWindowRow: Decodable { let messageCount: Int; enum CodingKeys: String, CodingKey { case messageCount = "message_count" } }
struct DirectReplyMarkerMutationRow: Decodable { let roomID: UUID; enum CodingKeys: String, CodingKey { case roomID = "room_id" } }
struct MentionSenderMembershipRow: Decodable { let role: String }
struct MentionMembershipRow: Decodable { let userID: UUID; let mentionable: Bool; enum CodingKeys: String, CodingKey { case userID = "user_id", mentionable } }

private func uuid<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}

private func signed(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}

struct SelectedRoomOwnerRow: Decodable {
    let kind: String
    let roomID: UUID
    let shardID: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", shardID = "room_shard_id", epoch = "owner_epoch", kind = "room_kind"
    }
}

// 对 JSON 和预处理追加输入统一匹配 postgres-nio 的 Date 编码器。
// 持久化期间保持整数形式；转换为 Unix 秒浮点数可能舍入到另一微秒，
// 从而改变已存回执和边界检查结果。
func roomWritePostgresMicroseconds(_ date: Date) throws -> Int64 {
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    guard let value = Int64(exactly: (date.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)),
          v2PostgresTimestampMicrosecondsCanEncode(value)
    else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

// 使用驱动的精确输入，匹配 floor(extract(epoch FROM created_at) * 1000)。
// 先除再加纪元偏移，避免 PostgreSQL 的完整取值范围使中间的 Unix 微秒整数溢出。
func roomWriteProjectionMilliseconds(_ date: Date) throws -> Int64 {
    let microseconds = try roomWritePostgresMicroseconds(date)
    let floorMilliseconds = microseconds / 1_000 - (microseconds % 1_000 < 0 ? 1 : 0)
    return floorMilliseconds + 946_684_800_000
}

// 新生成的确认必须暴露与持久回执一致的 Date。
// 只有新接受的消息需要转换：重放时间已从 PostgreSQL 解码，不能再次编码和舍入。
func roomWritePersistedAcceptanceOutcome(_ outcome: V2SendMessageOutcome) throws -> V2SendMessageOutcome {
    guard case .accepted(let message) = outcome else { return outcome }
    let createdAt = try roomWritePersistedDate(message.createdAt)
    return .accepted(.init(messageID: message.messageID, roomID: message.roomID,
        roomSequence: message.roomSequence, timelineSequence: message.timelineSequence,
        senderUserID: message.senderUserID, clientMessageID: message.clientMessageID,
        text: message.text, media: message.media, mediaPresentations: message.mediaPresentations,
        mentions: message.mentions, entities: message.entities, replyTo: message.replyTo,
        groupCapacityClass: message.groupCapacityClass,
        sourceEventID: message.sourceEventID, acceptedMembershipRevision: message.acceptedMembershipRevision,
        directRecipientUserID: message.directRecipientUserID,
        projectionCreatedAtUnixMilliseconds: try roomWriteProjectionMilliseconds(message.createdAt),
        createdAt: createdAt))
}

func roomWriteStrangerWindowStart(now: Date, interval: TimeInterval) throws -> Date {
    guard let cutoff = v2PostgresPastTimestamp(now: now, interval: interval) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return cutoff
}

// 无须再次读取 SQL，即可模拟 postgres-nio 微秒编码后的 Date 解码。
// 仅用于新生成的响应值，不用于已经读取的记录。
func roomWritePersistedDate(_ date: Date) throws -> Date {
    let microseconds = try roomWritePostgresMicroseconds(date)
    return Date(timeInterval: Double(microseconds) / 1_000_000,
                since: Date(timeIntervalSince1970: 946_684_800))
}
