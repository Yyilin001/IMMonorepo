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
/// 房间本地状态按 `rooms -> room_admission` 的顺序串行化。
/// 分片准入先乐观评估，再在事务的最后一条语句中用一次条件式原子自增完成预留。
/// 这既保持精确的容量与租约围栏，
/// 又无需在策略检查与持久消息写入期间一直持有共享分片行。
public struct PostgresV2RoomWriteStore: V2OwnerValidatedRoomWriteStore, V2OwnerValidatedForwardMessageWriteStore {
    private var database: any Database
    private var controlDatabase: (any Database)?
    private var controlResolution: V2RoomWriteControlResolution = .unresolved
    var authorizationGrants: [String: V2DirectAuthorizationGrant]? { controlResolution.authorization?.grants }
    private var authorizationResolutionDatabase: (any Database)?
    var controlScopeRoomKinds: [UUID: String]? { controlResolution.roomKinds }
    // 在一次限定范围的值拷贝生命周期内保持不可变。共享缓存和额度 Actor
    // 保持原有身份；不使用可变的隐式路由。
    private var ownerSelection = V2RoomWriteOwnerSelection()
    var ownerRoutes: [UUID: V2RoomShardRoute]? { ownerSelection.routes }
    var activationScope: V2RoomActivationWriteScope? { ownerSelection.activation }
    var forwardOwnerSourceRoomID: UUID? { ownerSelection.forwardSource }
    private var controlPolicyScope: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]? { controlResolution.policies }
    let strangerMessagePolicy: V2StrangerMessagePolicy
    let contentReviewMode: V2ContentReviewMode
    private let directSendPolicyCache: V2DirectSendPolicyCache
    private let directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache
    private let roomWriteBatchRouteCache: V2RoomWriteBatchRouteCache
    private let hybridGroupShardCreditSnapshotCache:
        V2HybridGroupShardCreditSnapshotCache
    private var shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool?
    private(set) var roomAdmissionCommandCreditPool: V2RoomAdmissionCommandCreditPool?
    private let appendStageMetrics: V2DirectRoomLogAppendStageMetrics?

    /// 组合数据库与写入策略。
    ///
    /// - Parameters:
    ///   - database: 存放房间、事件与投递的数据库。
    ///   - strangerMessagePolicy: 陌生人消息策略。
    ///   - contentReviewMode: 内容审核模式。
    ///   - directSendPolicyCache: 可选的私聊发送策略缓存。
    ///   - directRoomLogFastAppendCache: 可选的私聊日志快速追加缓存。
    ///   - shardAdmissionCommandCreditPool: 可选的分片准入信用池。
    ///   - roomAdmissionCommandCreditPool: 可选的房间准入信用池。
    ///   - appendStageMetrics: 可选的追加阶段指标。
    public init(
        database: any Database,
        strangerMessagePolicy: V2StrangerMessagePolicy,
        contentReviewMode: V2ContentReviewMode,
        directSendPolicyCache: V2DirectSendPolicyCache = .init(),
        directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache = .init(),
        shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool? = nil,
        roomAdmissionCommandCreditPool: V2RoomAdmissionCommandCreditPool? = nil,
        appendStageMetrics: V2DirectRoomLogAppendStageMetrics? = nil
    ) {
        self.database = database
        self.strangerMessagePolicy = strangerMessagePolicy
        self.contentReviewMode = contentReviewMode
        self.directSendPolicyCache = directSendPolicyCache
        self.directRoomLogFastAppendCache = directRoomLogFastAppendCache
        self.roomWriteBatchRouteCache = .init()
        self.hybridGroupShardCreditSnapshotCache = .init()
        self.shardAdmissionCommandCreditPool = shardAdmissionCommandCreditPool
        self.roomAdmissionCommandCreditPool = roomAdmissionCommandCreditPool
        self.appendStageMetrics = appendStageMetrics
    }

    /// 为这个确切的物理归属绑定另一个工作负载连接池。
    ///
    /// 值拷贝会保留全部策略以及共享缓存/额度 actor 的身份。
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
    /// 此值拷贝本身不授予权限，并保留共享缓存及额度池的身份。
    var strangerQuotaWindowSeconds:TimeInterval { strangerMessagePolicy.window }
    private var transactionOwnership: V2RoomWriteTransactionOwnership = .store

    func usingOperationTransaction() -> Self {
        var copy = self
        copy.transactionOwnership = .operationReceipt
        copy.shardAdmissionCommandCreditPool = nil
        copy.roomAdmissionCommandCreditPool = nil
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
        await directRoomLogFastAppendCache.invalidate(roomID: room)
        await hybridGroupShardCreditSnapshotCache.invalidate([room])
    }

    /// Host 仅在执行器的 SQL 与批次处理结束后调用此方法。
    /// 未使用的额度属于这一确切代次，不能转交给后继代次。
    package func closeActorState(token: V2RoomActivationToken) async {
        await invalidateActorHints(token: token)
        await roomAdmissionCommandCreditPool?.retire(activation: token)
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
              strangerMessagePolicy: strangerMessagePolicy, contentReviewMode: contentReviewMode,
              observesRoomAdmissionHeat: roomAdmissionCommandCreditPool != nil)
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
        if let controlDatabase, controlResolution.needsPreparation {
            return try await withDurableAuthorizations(commands: [request.command],
                controlDatabase: controlDatabase, now: request.now) { scoped in
                try await scoped.acceptPreparedActorForwardPair(request: request,
                    prepareLedger: prepareLedger, recordLedger: recordLedger)
            }
        }
        try validateAuthorizationCommand(request.command)
        let room = try uuid(request.command.roomID), sender = try uuid(request.command.senderUserID)
        guard let source = forwardOwnerSourceRoomID else { throw V2RoomActivationLeaseError.activationChanged }
        let commit: RoomWriteCommit
        do {
            commit = try await withRoomWriteTransaction { transaction in
                let sql = try sqlDatabase(from: transaction)
                try await acquireMessageOperationLock(roomID: room, senderID: sender,
                    clientMessageID: uuid(request.command.clientMessageID), sql: sql)
                try await requireSelectedOwners([source, room], sql: sql)
                try await prepareLedger(transaction)
                let accepted = try await scalarAcceptancePath.acceptInTransaction(command: request.command,
                    capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now,
                    roomID: room, senderID: sender, cachedDirectPolicy: nil, sql: sql)
                try await recordLedger(accepted.outcome, transaction)
                return accepted
            }
        } catch let rejection as LateShardAdmissionRejection {
            // 成对台账与消息效果一起回滚。
            switch rejection {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            }
        }
        return try await finalizeCommittedAcceptance(command: request.command,
            cacheKey: .init(roomID: room, senderID: sender), commit: commit)
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
            let request = V2RoomWriteRequest(
                command: command,
                capacityProfile: capacityProfile,
                identifiers: identifiers,
                now: now
            )
            if !transactionOwnership.borrowsTransaction, let fastCommit = try await acceptFastPlainDirectRoomLogIfEligible(
                request: request,
                roomID: roomID,
                senderID: senderID,
                cacheKey: cacheKey
            ) {
                return try await finalizeCommittedAcceptance(
                    command: command,
                    cacheKey: cacheKey,
                    commit: fastCommit
                )
            }
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
        if let controlDatabase, controlResolution.needsPreparation {
            // 此处仅检查所有者的简短预检会在控制侧预留之前结束。
            // 下方的接受事务会在写入任何消息前重新检查收件箱、媒体映射、
            // 命令的精确指纹和所有者。
            let preflight: (V2SendMessageCommand?, V2ForwardImportOutcome?) = try await withRoomWriteTransaction { transaction in
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
        let prepared: (outcome: V2ForwardImportOutcome, command: V2SendMessageCommand?, commit: RoomWriteCommit?)
        do {
            prepared = try await withRoomWriteTransaction { transaction in
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
            return .pending(.admission)
        }
        guard let command = prepared.command, let commit = prepared.commit else { return prepared.outcome }
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
        guard !contentReviewMode.enqueuesJobs,
              shardAdmissionCommandCreditPool != nil
        else {
            return Array(repeating: false, count: requests.count)
        }

        let partitions = await atomicBatchPartitions(requests: requests)
        return partitions.map { $0 != nil }
    }

    public func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) async -> [V2AtomicRoomWriteBatchPartition?] {
        guard !contentReviewMode.enqueuesJobs,
              shardAdmissionCommandCreditPool != nil
        else { return Array(repeating: nil, count: requests.count) }

        let keys: [V2DirectRoomLogFastAppendCache.Key?] = requests.map { request in
            guard v2PostgresTimestampCanEncode(request.now),
                  V2RoomWriteFastDirectEligibility.acceptsBatchShape(request),
                  let roomID = try? uuid(request.command.roomID),
                  let senderID = try? uuid(request.command.senderUserID)
            else { return nil }
            return .init(roomID: roomID, senderID: senderID)
        }
        let presentKeys = keys.compactMap { $0 }
        let roomIDs = presentKeys.map(\.roomID)
        let routes = await resolvedRoomWriteBatchRoutes(roomIDs: roomIDs)
        let snapshots: [V2DirectRoomLogFastAppendCache.Entry?]
        if routes.contains(where: { $0 == .direct }) {
            snapshots = await directRoomLogFastAppendCache.values(for: presentKeys)
        } else {
            snapshots = Array(repeating: nil, count: presentKeys.count)
        }
        var snapshotIndex = 0
        var partitions: [V2AtomicRoomWriteBatchPartition?] = zip(requests, keys).map { request, key in
            guard key != nil else { return nil }
            defer { snapshotIndex += 1 }
            let route = routes[snapshotIndex]
            if route == .individual { return nil }
            if route == .large {
                return .large
            }
            guard route == .direct else { return nil }
            guard let snapshot = snapshots[snapshotIndex],
                  snapshot.capacityProfileID == request.capacityProfile.id,
                  V2RoomWriteFastDirectEligibility.acceptsSnapshot(snapshot.policy),
                  let lease = snapshot.shardState.lease,
                  lease.validUntil > request.now
            else {
                return nil
            }
            return .accelerated
        }

        // 避免将大部分尚未预热的到达批次拆成两个事务。
        // 标准路径会预热成功的条目，使后续批次自然进入单语句加速路径。
        let acceleratedCount = partitions.lazy.compactMap { $0 }
            .filter { $0 == .accelerated }
            .count
        let compatibleCount = partitions.lazy.compactMap { $0 }.count
        if acceleratedCount < 16 || acceleratedCount * 4 < compatibleCount * 3 {
            for index in partitions.indices where partitions[index] == .accelerated {
                partitions[index] = .standard
            }
        }
        return partitions
    }

    public func atomicBatchSupportsRepeatedRooms(
        in partition: V2AtomicRoomWriteBatchPartition
    ) async -> Bool {
        partition == .large
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
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?
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

    /// 一起提交一具有界的普通单聊房间日志消息。
    ///
    /// 只接受纯消息传输形态：没有附件、@ 扇出，也没有回复/转发依赖。
    ///
    /// 普通直聊仅接受已预热的加速批次，冷请求交由批处理器逐条走完整标量路径；
    /// 加速分支仍在持久锁下处理陌生人配额、首次回复及资料/能力效果。
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
        guard requests.count >= 2,
              !contentReviewMode.enqueuesJobs,
              shardAdmissionCommandCreditPool != nil
        else {
            throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
        }
        let invalidClockIndices = requests.indices.filter { !v2PostgresTimestampCanEncode(requests[$0].now) }
        guard invalidClockIndices.isEmpty else {
            throw V2AtomicRoomWriteBatchError(reason: .requestShape, isolatedRequestIndices: invalidClockIndices)
        }
        guard requests.allSatisfy(V2RoomWriteFastDirectEligibility.acceptsBatchShape) else {
            throw V2AtomicRoomWriteBatchError(reason: .requestShape)
        }

        let roomIDs = try requests.map { try uuid($0.command.roomID) }
        let routes = await resolvedRoomWriteBatchRoutes(roomIDs: roomIDs)
        if routes.allSatisfy({ $0 == .large }) {
            return try await acceptPlainHybridGroupBatch(requests: requests)
        }
        guard routes.allSatisfy({ $0 == .direct }) else {
            throw V2AtomicRoomWriteBatchError(reason: .roomKindMismatch)
        }

        let fastPathStartedAt = ContinuousClock.now
        do {
            if let outcomes = try await acceptFastPlainDirectRoomLogBatchIfEligible(
                requests: requests
            ) {
                let duration = fastPathStartedAt.duration(to: .now)
                appendStageMetrics?.record(.fastPathProbe, duration: duration)
                appendStageMetrics?.record(.acceleratedTotal, duration: duration)
                return outcomes
            }
            appendStageMetrics?.record(
                .fastPathProbe,
                duration: fastPathStartedAt.duration(to: .now)
            )
        } catch {
            appendStageMetrics?.record(
                .fastPathProbe,
                duration: fastPathStartedAt.duration(to: .now)
            )
            throw error
        }
        // 尚未预热的私聊发送使用完整的逐条路径，确保每条命令保有房间级准入围栏。
        throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
    }

    /// 在单个 PostgreSQL 事务中提交普通的、不含 @ 的混合群组消息。
    ///
    /// 房间按 UUID 顺序加锁，同一热房间的重复命令按原始到达顺序归并。
    /// 持久化只按最终归并状态更新该房间一次，同时保留每一条消息/事件/审计行，
    /// 因此批处理既不改动 FIFO，也不改动授权、投递、幂等与恢复契约。
    ///
    /// - Parameter requests: 本批房间写入请求。
    /// - Returns: 与请求顺序对应的发送结果。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    private func acceptPlainHybridGroupBatch(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        guard requests.count >= 2,
              requests.allSatisfy(V2RoomWriteFastDirectEligibility.acceptsBatchShape),
              let shardAdmissionCommandCreditPool,
              let databaseSQL = database as? any SQLDatabase
        else { throw V2AtomicRoomWriteBatchError(reason: .requestShape) }

        var ordered = try requests.enumerated().map { originalIndex, request in
            let roomID = try uuid(request.command.roomID)
            let senderID = try uuid(request.command.senderUserID)
            return OrderedRoomWriteRequest(
                originalIndex: originalIndex,
                request: request,
                roomID: roomID,
                senderID: senderID,
                cacheKey: .init(roomID: roomID, senderID: senderID),
                cachedDirectPolicy: nil,
                usesRoomAdmissionCredits: false,
                preflightOrdinal: -1
            )
        }
        let operationKeys = try ordered.map {
            "\($0.roomID.uuidString):\($0.senderID.uuidString):\(try uuid($0.request.command.clientMessageID).uuidString)"
        }
        guard Set(operationKeys).count == ordered.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateOperation)
        }
        ordered.sort {
            if $0.roomID == $1.roomID {
                return $0.originalIndex < $1.originalIndex
            }
            return $0.roomID < $1.roomID
        }
        ordered = ordered.enumerated().map { ordinal, item in
            .init(
                originalIndex: item.originalIndex,
                request: item.request,
                roomID: item.roomID,
                senderID: item.senderID,
                cacheKey: item.cacheKey,
                cachedDirectPolicy: nil,
                usesRoomAdmissionCredits: false,
                preflightOrdinal: ordinal
            )
        }
        let orderedRequests = ordered

        // 在开启消息事务前扣除命令容量。Actor 先在 PostgreSQL 中持久预留
        // 有界批次，再为每条消息发放一个令牌。下方事务仍会在锁内重新检查
        // 房间分配、租约代次和完整授权关系，因此此快照只作为容量提示。
        let uniqueRoomIDs = Array(Set(orderedRequests.map(\.roomID))).sorted {
            $0.uuidString < $1.uuidString
        }
        var cachedSnapshots = await hybridGroupShardCreditSnapshotCache.values(
            for: uniqueRoomIDs
        )
        let missingRoomIDs = zip(uniqueRoomIDs, cachedSnapshots).compactMap {
            roomID, snapshot in snapshot == nil ? roomID : nil
        }
        if !missingRoomIDs.isEmpty {
            let loaded = try await loadPlainHybridGroupShardCreditSnapshots(
                roomIDs: missingRoomIDs,
                sql: databaseSQL
            )
            await hybridGroupShardCreditSnapshotCache.insert(loaded)
            let loadedByRoomID = Dictionary(
                uniqueKeysWithValues: loaded.map { ($0.roomID, $0.entry) }
            )
            for index in cachedSnapshots.indices where cachedSnapshots[index] == nil {
                cachedSnapshots[index] = loadedByRoomID[uniqueRoomIDs[index]]
            }
        }
        let snapshotsByRoomID = Dictionary(
            uniqueKeysWithValues: zip(uniqueRoomIDs, cachedSnapshots).compactMap {
                roomID, snapshot in snapshot.map { (roomID, $0) }
            }
        )
        guard snapshotsByRoomID.count == uniqueRoomIDs.count else {
            throw V2AtomicRoomWriteBatchError(reason: .admissionState)
        }
        let creditRequests = try orderedRequests.map { item in
            guard let snapshot = snapshotsByRoomID[item.roomID],
                  snapshot.kind == "group",
                  snapshot.capacityClass == .large,
                  snapshot.capacityProfileID == item.request.capacityProfile.id,
                  snapshot.frozenAt == nil,
                  let snapshotLease = snapshot.shardState.lease,
                  UUID(uuidString: snapshotLease.id.rawValue) == snapshot.roomShardLeaseID,
                  Int64(exactly: snapshotLease.generation)
                    == snapshot.roomShardLeaseGeneration
            else { throw V2AtomicRoomWriteBatchError(reason: .admissionState) }
            return V2ShardAdmissionCommandCreditPool.BatchRequest(
                roomShardID: snapshot.roomShardID,
                capacityProfileID: snapshot.capacityProfileID,
                shardState: snapshot.shardState,
                now: item.request.now
            )
        }
        let acquisitions = try await shardAdmissionCommandCreditPool.acquire(creditRequests)
        guard acquisitions.count == orderedRequests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let grantedTokens: [V2ShardAdmissionCommandCreditPool.Token] =
            acquisitions.compactMap { acquisition in
            guard case .granted(let token, _) = acquisition else { return nil }
            return token
        }
        let releaseNow = requests.map(\.now).max() ?? Date()
        guard grantedTokens.count == orderedRequests.count else {
            await shardAdmissionCommandCreditPool.release(grantedTokens, now: releaseNow)
            await hybridGroupShardCreditSnapshotCache.invalidate(uniqueRoomIDs)
            throw V2AtomicRoomWriteBatchError(reason: .admissionState)
        }

        let committed: [OrderedRoomWriteCommit]
        do {
            committed = try await withRoomWriteTransactionWithFenceContext { transaction, fenceContext in
                let sql = try sqlDatabase(from: transaction)
                // PostgreSQL 可在一条条件语句中校验普通群组的完整契约并追加规范记录。
                // 这不是由缓存授权的写入：成员关系、禁言、账号、角色权限、房间配置、
                // 租约和准入条件均根据已加锁的持久化记录检查。若记录过期或异常，
                // 则不会写入；批处理器会通过既有完整路径重试不可变命令。
                if sql is any PostgresDatabase {
                    if ownerRoutes != nil || activationScope != nil {
                        try await acquireMessageOperationLocks(orderedRequests, sql: sql)
                        if let fenceContext, let activationScope,
                           authorizationGrants == nil {
                            try await fenceContext.requireSelectedOwnersAndActivations(
                                roomIDs: orderedRequests.map(\.roomID),
                                expectedRoutes: ownerRoutes,
                                expectedKinds: controlScopeRoomKinds,
                                scope: activationScope)
                        } else {
                            try await requireSelectedOwners(orderedRequests.map(\.roomID), sql: sql)
                        }
                    }
                    return try await persistConditionalPlainHybridGroupMessages(
                        orderedRequests,
                        acquisitions: acquisitions,
                        snapshotsByRoomID: snapshotsByRoomID,
                        sql: sql
                    )
                }
                try await acquireMessageOperationLocks(orderedRequests, sql: sql)
                try await requireSelectedOwners(orderedRequests.map(\.roomID), sql: sql)
                return try await V2RoomWriteHybridBatchPath.persist(
                    orderedRequests, acquisitions: acquisitions,
                    snapshotsByRoomID: snapshotsByRoomID, sql: sql)
            }
        } catch {
            if error is V2RoomTransactionOutcomeUnknown {
                for token in grantedTokens { await shardAdmissionCommandCreditPool.discard(token) }
            } else {
                await shardAdmissionCommandCreditPool.release(grantedTokens, now: releaseNow)
            }
            if v2IsSendCompletionRace(error) {
                await hybridGroupShardCreditSnapshotCache.invalidate(uniqueRoomIDs)
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
            if error is V2AtomicRoomWriteBatchError {
                await hybridGroupShardCreditSnapshotCache.invalidate(uniqueRoomIDs)
            }
            throw error
        }
        do {
            return try await commitEffects.finalizeHybridBatch(
                requests: requests, committed: committed, shardTokens: grantedTokens)
        } catch {
            if activationScope != nil { throw V2RoomTransactionOutcomeUnknown() }
            throw error
        }
    }

    /// 为一条普通单聊消息尝试严格的稳态分支。
    ///
    /// 对调用方而言，返回 `nil` 刻意与缓存未命中无法区分：
    /// 所有拒绝、幂等重放以及特殊单聊副作用都由既有的完整路径负责。
    ///
    /// - Parameters:
    ///   - request: 单条房间写入请求。
    ///   - roomID: 目标房间标识。
    ///   - senderID: 发送者标识。
    ///   - cacheKey: 单聊策略缓存键。
    /// - Returns: 房间写入提交结果；不满足快速路径条件时为 `nil`。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    private func acceptFastPlainDirectRoomLogIfEligible(
        request: V2RoomWriteRequest,
        roomID: UUID,
        senderID: UUID,
        cacheKey: V2DirectSendPolicyCache.Key
    ) async throws -> RoomWriteCommit? {
        guard let commits = try await fastPlainDirectRoomLogCommitsIfEligible(
            requests: [request],
            knownIDs: [(roomID: roomID, senderID: senderID, cacheKey: cacheKey)]
        ) else {
            return nil
        }
        guard commits.count == 1 else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return commits[0].commit
    }

    /// 对一批已经预热好的普通单聊房间日志发送，使用单条条件式 PostgreSQL 语句。
    ///
    /// 该语句仍会获取全部持久房间/成员/配对/版本锁；
    /// 它只是避免了在追加之前展开稳定的策略图并将其返回 Swift。
    ///
    /// - Parameter requests: 本批房间写入请求。
    /// - Returns: 与请求顺序对应的发送结果；不满足快速路径条件时为 `nil`。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    private func acceptFastPlainDirectRoomLogBatchIfEligible(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome]? {
        var knownIDs: [(roomID: UUID, senderID: UUID, cacheKey: V2DirectSendPolicyCache.Key)] = []
        knownIDs.reserveCapacity(requests.count)
        for request in requests {
            let roomID = try uuid(request.command.roomID)
            let senderID = try uuid(request.command.senderUserID)
            knownIDs.append((roomID, senderID, .init(roomID: roomID, senderID: senderID)))
        }
        guard let commits = try await fastPlainDirectRoomLogCommitsIfEligible(
            requests: requests,
            knownIDs: knownIDs
        ) else {
            return nil
        }
        return try await finalizeCommittedAcceptances(
            requests: requests,
            committed: commits
        )
    }

    /// 该快速路径刻意只具备很窄的语义。
    ///
    /// 首次回复标记、特殊账号以及资料/能力投影仍留在完整路径上。
    /// 已经建立过关系的陌生人发送方可以使用该条件式语句，
    /// 因为同一个事务在推进房间游标之前，也会消耗其精确的持久陌生人配额。
    ///
    /// - Parameters:
    ///   - requests: 本批房间写入请求。
    ///   - knownIDs: 预先解析出的房间/发送者/缓存键三元组。
    /// - Returns: 各请求的提交结果；不满足条件时为 `nil`。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    private func fastPlainDirectRoomLogCommitsIfEligible(
        requests: [V2RoomWriteRequest],
        knownIDs: [(roomID: UUID, senderID: UUID, cacheKey: V2DirectSendPolicyCache.Key)]
    ) async throws -> [OrderedRoomWriteCommit]? {
        let path = V2RoomWriteFastDirectPath(
            contentReviewMode: contentReviewMode,
            directRoomLogFastAppendCache: directRoomLogFastAppendCache,
            shardAdmissionCommandCreditPool: shardAdmissionCommandCreditPool,
            roomAdmissionCommandCreditPool: roomAdmissionCommandCreditPool,
            activationScope: activationScope,
            controlPolicyScope: controlPolicyScope,
            controlScopeRoomKinds: controlScopeRoomKinds,
            strangerMessagePolicy: strangerMessagePolicy
        )
        guard let prepared = try await path.prepare(requests: requests, knownIDs: knownIDs)
        else { return nil }
        do {
            await directRoomLogFastAppendCache.recordAttempt(count: prepared.ordered.count)
            let committed = try await withRoomWriteTransaction { transaction in
                let sql = try sqlDatabase(from: transaction)
                // This separate lock statement must precede the conditional
                // append so PostgreSQL observes completed retries in a new snapshot.
                try await acquireMessageOperationLocks(prepared.lockRequests, sql: sql)
                try await requireSelectedOwners(prepared.lockRequests.map(\.roomID), sql: sql)
                return try await path.persist(prepared, sql: sql)
            }
            await directRoomLogFastAppendCache.recordCommitted(count: prepared.ordered.count)
            return committed
        } catch is V2AtomicRoomWriteBatchError {
            for append in prepared.ordered {
                await directRoomLogFastAppendCache.invalidate(.init(
                    roomID: append.roomID, senderID: append.senderID
                ))
            }
            await directRoomLogFastAppendCache.recordFallback(count: prepared.ordered.count)
            await path.releaseCredits(prepared.ordered)
            return nil
        } catch {
            await path.releaseCredits(prepared.ordered,
                outcomeUnknown: error is V2RoomTransactionOutcomeUnknown)
            throw error
        }
    }

    /// 使用与有序微批完全相同的权威预检与追加图，但只针对一个已确证的热单聊房间。
    ///
    /// 批处理器刻意不能把同一房间的两条命令放进同一个原子批次，因为那会削弱 FIFO。
    /// 若没有该分支，最活跃的会话就永远无法享受到安全的每房间额度优化。
    ///
    /// - Parameters:
    ///   - request: 单条房间写入请求。
    ///   - roomID: 目标房间标识。
    ///   - senderID: 发送者标识。
    /// - Returns: 房间写入提交结果。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    private func sqlDatabase(from transaction: any Database) throws -> any SQLDatabase {
        guard let sql = transaction as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return sql
    }

    /// 只在 Fluent 已提交源事务之后运行。
    ///
    /// 把这些进程本地缓存与额度收尾放在 SQL 接受边界之外，
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
              directRoomLogFastAppendCache: directRoomLogFastAppendCache,
              shardAdmissionCommandCreditPool: shardAdmissionCommandCreditPool,
              roomAdmissionCommandCreditPool: roomAdmissionCommandCreditPool,
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
        try await v2AcquireMessageOperationLock(roomID: roomID, senderID: senderID,
            clientMessageID: clientMessageID, sql: sql)
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
            ), input AS MATERIALIZED (
                SELECT (row_number() OVER (ORDER BY lock_key, ordinal) - 1)::integer AS ordinal, lock_key
                FROM key_input
            ), locked(ordinal, lock_acquired) AS (
                SELECT input.ordinal, pg_advisory_xact_lock(input.lock_key)
                FROM input
                WHERE input.ordinal = 0

                UNION ALL

                SELECT input.ordinal, pg_advisory_xact_lock(input.lock_key)
                FROM locked AS previous
                JOIN input
                  ON input.ordinal = previous.ordinal + 1
            )
            SELECT count(*)::bigint AS acquired_count
            FROM locked
            """).first(decoding: MessageOperationLockBatchRow.self),
              row.acquiredCount == expectedCount
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await prepareBatchAuthorizations(inputs, sql: sql)
    }

    private func prepareBatchAuthorizations(_ inputs: [MessageOperationLockInput], sql: any SQLDatabase) async throws {
        guard authorizationGrants != nil else { return }
        let ordered = inputs.sorted {
            authorizationOperationKey(roomID: $0.roomID, senderID: $0.senderID, clientMessageID: $0.clientMessageID)
                < authorizationOperationKey(roomID: $1.roomID, senderID: $1.senderID, clientMessageID: $1.clientMessageID)
        }
        for input in ordered {
            try await selectedOwnerGuard.prepareAuthorization(roomID: input.roomID, senderID: input.senderID, clientMessageID: input.clientMessageID, sql: sql)
        }
    }

    /// 只加载在更长消息事务开始之前、用于预留持久命令额度所需的分片租约。
    ///
    /// 这次读取刻意不是授权决定：
    /// `PlainHybridGroupPreflight.load` 会在持有既定房间本地锁的情况下，
    /// 重新执行分配/租约检查，并校验成员、禁言与角色权限。
    ///
    /// - Parameters:
    ///   - roomIDs: 待查询的房间标识。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 各房间对应的分片额度快照。
    /// - Throws: 查询失败时抛出。
    private func loadPlainHybridGroupShardCreditSnapshots(
        roomIDs: [UUID],
        sql: any SQLDatabase
    ) async throws -> [V2HybridGroupShardCreditSnapshotCache.Update] {
        guard !roomIDs.isEmpty else { return [] }
        let roomIDsJSON = try roomWriteJSON(roomIDs.map(\.uuidString))
        let rows = try await sql.raw("""
            WITH requested AS MATERIALIZED (
                SELECT value::uuid AS room_id
                FROM jsonb_array_elements_text(\(bind: roomIDsJSON)::jsonb) AS value
            )
            SELECT room.room_id, room.room_kind, room.room_shard_id,
                   room.capacity_profile_id, room.capacity_class,
                   room.frozen_at,
                   admission.shard_lease_id AS room_shard_lease_id,
                   admission.shard_lease_generation AS room_shard_lease_generation,
                   shard.lease_id, shard.generation, shard.valid_until,
                   shard.command_window_limit, shard.command_window_used
            FROM requested
            JOIN im_v2.rooms AS room USING (room_id)
            JOIN im_v2.room_admission AS admission USING (room_id)
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = room.room_shard_id
             AND shard.capacity_profile_id = room.capacity_profile_id
            ORDER BY room.room_id
            """).all(decoding: PlainHybridGroupShardCreditSnapshotRow.self)
        return try rows.map { row in
            .init(
                roomID: row.roomID,
                entry: .init(
                    roomShardID: row.roomShardID,
                    capacityProfileID: row.capacityProfileID,
                    kind: row.kind,
                    capacityClass: row.capacityClass,
                    frozenAt: row.frozenAt,
                    roomShardLeaseID: row.roomShardLeaseID,
                    roomShardLeaseGeneration: row.roomShardLeaseGeneration,
                    shardState: try row.shard.admissionState()
                )
            )
        }
    }

    /// 以单张条件式 PostgreSQL 写图执行稳态的普通混合群组契约。
    ///
    /// 分片命令容量已由 `V2ShardAdmissionCommandCreditPool` 持久预扣；
    /// 该语句为那个确切的租约代次建立围栏，
    /// 同时原子地保留房间本地准入、授权、幂等与序号分配。
    ///
    /// - Parameters:
    ///   - ordered: 已排序的房间写入请求。
    ///   - acquisitions: 本批取得的分片额度。
    ///   - snapshotsByRoomID: 各房间对应的分片额度快照。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 影响行数不符或写入失败时抛出。
    private func persistConditionalPlainHybridGroupMessages(
        _ ordered: [OrderedRoomWriteRequest],
        acquisitions: [V2ShardAdmissionCommandCreditPool.Acquisition],
        snapshotsByRoomID: [UUID: V2HybridGroupShardCreditSnapshotCache.Entry],
        sql: any SQLDatabase
    ) async throws -> [OrderedRoomWriteCommit] {
        let allocations = try await PlainHybridGroupConditionalWritePath.execute(
            ordered,
            acquisitions: acquisitions,
            snapshotsByRoomID: snapshotsByRoomID,
            sql: sql
        )
        guard allocations.count == ordered.count,
              zip(allocations, ordered).allSatisfy({ allocation, item in
                  allocation.ordinal == item.preflightOrdinal
                      && allocation.messageID
                        == (try? uuid(item.request.identifiers.messageID))
              })
        else {
            // 快速语句有意不返回逐用户的拒绝详情。在异常的零写入路径上，
            // 趁操作锁和房间锁仍被持有时运行既有权威预检，让批处理器在逐条回退前
            // 精确定位过期或被拒绝的请求。正常接受路径仍只执行一条语句。
            try await requireSelectedOwners(ordered.map(\.roomID), sql: sql)
            let isolated = try await diagnoseConditionalPlainHybridGroupMismatch(
                ordered,
                acquisitions: acquisitions,
                snapshotsByRoomID: snapshotsByRoomID,
                sql: sql
            )
            guard isolated.isEmpty else {
                throw V2AtomicRoomWriteBatchError(
                    reason: .authorizationState,
                    isolatedRequestIndices: isolated
                )
            }
            throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
        }

        return try zip(ordered, allocations).map { item, allocation in
            let command = item.request.command
            let accepted = V2AcceptedMessageDraft(
                messageID: item.request.identifiers.messageID,
                roomID: command.roomID,
                roomSequence: try unsigned(allocation.roomSequence),
                timelineSequence: try unsigned(allocation.timelineSequence),
                senderUserID: command.senderUserID,
                clientMessageID: command.clientMessageID,
                text: command.text,
                media: command.media,
                mentions: command.mentions,
                entities: command.entities,
                replyTo: command.replyTo,
                createdAt: item.request.now
            ).materialized(
                mediaPresentations: [],
                groupCapacityClass: .large,

                sourceEventID: item.request.identifiers.eventID,
                acceptedMembershipRevision: try unsigned(allocation.membershipRevision)
            )
            return OrderedRoomWriteCommit(
                originalIndex: item.originalIndex,
                cacheKey: item.cacheKey,
                commit: .init(
                    outcome: .accepted(accepted)
                )
            )
        }
    }

    private func diagnoseConditionalPlainHybridGroupMismatch(
        _ ordered: [OrderedRoomWriteRequest],
        acquisitions: [V2ShardAdmissionCommandCreditPool.Acquisition],
        snapshotsByRoomID: [UUID: V2HybridGroupShardCreditSnapshotCache.Entry],
        sql: any SQLDatabase
    ) async throws -> [Int] {
        let contexts = try await PlainHybridGroupPreflight.load(ordered, sql: sql)
        guard contexts.count == ordered.count else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        var isolated: [Int] = []
        var reducedRoomStates: [UUID: V2RoomCommandState] = [:]
        isolated.reserveCapacity(ordered.count)
        for ((item, context), acquisition) in zip(zip(ordered, contexts), acquisitions) {
            guard context.ordinal == item.preflightOrdinal,
                  case .granted(_, let effectiveShardState) = acquisition,
                  let effectiveLease = effectiveShardState.lease,
                  let snapshot = snapshotsByRoomID[item.roomID],
                  !context.hasPriorOperation,
                  context.room.kind == "group",
                  context.room.capacityClass == .large,
                  context.room.roomShardID == snapshot.roomShardID,
                  context.room.capacityProfileID == snapshot.capacityProfileID,
                  context.room.capacityProfileID == item.request.capacityProfile.id,
                  context.room.frozenAt == nil,
                  context.senderIsActive == true,
                  context.muted == false,
                  context.allowsSendMessages == true,
                  V2RoomMembershipRole(rawValue: context.actorRole ?? "") != nil,
                  let admission = try? context.admissionSnapshot(),
                  admission.room.shardLeaseID == admission.shard.leaseID,
                  admission.room.shardLeaseGeneration == admission.shard.generation,
                  UUID(uuidString: effectiveLease.id.rawValue)
                    == admission.shard.leaseID,
                  Int64(exactly: effectiveLease.generation)
                    == admission.shard.generation
            else {
                isolated.append(item.originalIndex)
                continue
            }
            let roomState = try reducedRoomStates[item.roomID]
                ?? context.room.commandState(
                    roomID: item.request.command.roomID,
                    admission: admission.room
                )
            let result = try roomLogReduction(
                command: item.request.command,
                roomState: roomState,
                shardState: effectiveShardState,
                profile: item.request.capacityProfile.limits,
                identifiers: item.request.identifiers,
                now: item.request.now
            )
            guard case .accepted(let writeSet) = result else {
                isolated.append(item.originalIndex)
                continue
            }
            reducedRoomStates[item.roomID] = writeSet.nextRoomState
        }
        return isolated.sorted()
    }

    /// 针对策略/缓存命中的单语句追加。
    ///
    /// 策略布尔值绝不会作为 SQL 权威出现：
    /// 它们的三条持久修订会在锁定房间、单聊配对与两条用户策略行之后进行比较。
    /// 一次过期的成员变更、策略变更、禁言、幂等重放或租约替换都会产生零行，
    /// 回滚本事务并把命令交给完整路径。
    /// 房间/时间线序号从当前已锁定的行分配，
    /// 因此对端的一次追加不会使一个本已稳定的授权快照失效。
    ///
    /// - Parameter appends: 本批快速单聊房间日志追加。
    /// - Throws: 影响行数不符或写入失败时抛出。

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
    let admission = try V2CommandAdmissionEvaluator.reserve(profile: profile, roomState: roomState.admission, shardState: shardState, now: now)
    switch admission {
    case .rateLimited(let seconds):
        return .rateLimited(retryAfterSeconds: seconds)
    case .unavailable(let reason):
        return .unavailable(reason)
    case .accepted(_, let nextAdmission, let nextShard):
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

private func requireShardLeaseID(_ state: ShardAdmissionState) throws -> ShardAdmissionLeaseID {
    guard let lease = state.lease else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return lease.id
}

private func requireShardLeaseGeneration(_ state: ShardAdmissionState) throws -> UInt64 {
    guard let lease = state.lease else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return lease.generation
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

private struct PlainHybridGroupShardCreditSnapshotRow: Decodable {
    let roomID: UUID
    let kind: String
    let roomShardID: String
    let capacityProfileID: String
    let capacityClass: V2GroupCapacityClass
    let frozenAt: Date?
    let roomShardLeaseID: UUID
    let roomShardLeaseGeneration: Int64
    let shard: ShardRow

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case kind = "room_kind"
        case roomShardID = "room_shard_id"
        case capacityProfileID = "capacity_profile_id"
        case capacityClass = "capacity_class"
        case frozenAt = "frozen_at"
        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomID = try container.decode(UUID.self, forKey: .roomID)
        kind = try container.decode(String.self, forKey: .kind)
        roomShardID = try container.decode(String.self, forKey: .roomShardID)
        capacityProfileID = try container.decode(String.self, forKey: .capacityProfileID)
        capacityClass = try container.decode(V2GroupCapacityClass.self, forKey: .capacityClass)
        frozenAt = try container.decodeIfPresent(Date.self, forKey: .frozenAt)
        roomShardLeaseID = try container.decode(UUID.self, forKey: .roomShardLeaseID)
        roomShardLeaseGeneration = try container.decode(
            Int64.self,
            forKey: .roomShardLeaseGeneration
        )
        shard = try ShardRow(from: decoder)
    }
}




/// 集合式普通单聊房间日志追加所用的 JSONB 输入。
///
/// 它刻意收窄：附件、@ 提及与审核任务仍走各自的专用路径，
/// 直到它们各自的批量写图被设计并验证为止。
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

    enum CodingKeys: String, CodingKey {
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
            createdAtPostgresMicroseconds: createdAtPostgresMicroseconds
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

struct OrderedRoomWriteCommit {
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
    let fastAppendRoomShardID: String
    let fastAppendCapacityProfileID: String
    let fastAppendShardState: ShardAdmissionState?
    let commit: RoomWriteCommit
}

/// 单语句稳态单聊追加的输入与已准备值。
///
/// 它刻意只包含该语句用于与持久行比较的值；
/// 任何来自缓存的权限布尔值都不会被写入数据库，也不会在那里被当作授权谓词。
struct FastPlainDirectRoomLogCandidate {
    let originalIndex: Int
    let request: V2RoomWriteRequest
    let roomID: UUID
    let senderID: UUID
    let cacheKey: V2DirectSendPolicyCache.Key
    let snapshot: V2DirectRoomLogFastAppendCache.Entry
    let requiresStrangerQuota: Bool
    let usesRoomAdmissionCredits: Bool
}

struct FastPlainDirectRoomLogAppend {
    let originalIndex: Int
    let request: V2RoomWriteRequest
    let roomID: UUID
    let senderID: UUID
    let cacheKey: V2DirectSendPolicyCache.Key
    let snapshot: V2DirectRoomLogFastAppendCache.Entry
    let requiresStrangerQuota: Bool
    let usesRoomAdmissionCredits: Bool
    let roomCreditToken: V2RoomAdmissionCommandCreditPool.Token?
    let shardCreditToken: V2ShardAdmissionCommandCreditPool.Token
}

struct FastPlainDirectRoomLogAppendInput: Sendable {
    let roomID: UUID
    let senderID: UUID
    let recipientID: UUID
    let messageID: UUID
    let eventID: UUID
    let clientMessageID: UUID
    let expectedMembershipRevision: Int64
    let expectedDirectPairRevision: Int64
    let expectedSenderPolicyRevision: Int64
    let expectedRecipientPolicyRevision: Int64
    let roomShardID: String
    let capacityProfileID: String
    let expectedShardLeaseID: UUID
    let expectedShardGeneration: Int64
    let requiresStrangerQuota: Bool
    let usesRoomAdmissionCredits: Bool
    let text: String
    let entitiesJSON: String
    let fingerprint: V2SendMessageFingerprint
    let createdAtPostgresMicroseconds: Int64
    let windowStart: Date

    init(append: FastPlainDirectRoomLogAppend, strangerWindow: TimeInterval) throws {
        guard let lease = append.snapshot.shardState.lease,
              let leaseID = lease.id.uuidValue,
              let generation = Int64(exactly: lease.generation)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        roomID = append.roomID
        senderID = append.senderID
        recipientID = append.snapshot.policy.recipientID
        messageID = try uuid(append.request.identifiers.messageID)
        eventID = try uuid(append.request.identifiers.eventID)
        clientMessageID = try uuid(append.request.command.clientMessageID)
        expectedMembershipRevision = append.snapshot.membershipRevision
        expectedDirectPairRevision = append.snapshot.policy.directPairRevision
        expectedSenderPolicyRevision = append.snapshot.policy.senderPolicyRevision
        expectedRecipientPolicyRevision = append.snapshot.policy.recipientPolicyRevision
        roomShardID = append.snapshot.roomShardID
        capacityProfileID = append.snapshot.capacityProfileID
        expectedShardLeaseID = leaseID
        expectedShardGeneration = generation
        requiresStrangerQuota = append.requiresStrangerQuota
        usesRoomAdmissionCredits = append.usesRoomAdmissionCredits
        text = append.request.command.text
        entitiesJSON = append.request.command.entities.isEmpty
            ? "[]"
            : try roomWriteJSON(append.request.command.entities)
        fingerprint = append.request.command.fingerprint
        createdAtPostgresMicroseconds = try roomWritePostgresMicroseconds(append.request.now)
        windowStart = append.requiresStrangerQuota
            ? try roomWriteStrangerWindowStart(now: append.request.now, interval: strangerWindow)
            : append.request.now
    }
}









struct AuthorizationRow: Decodable { let authorized: Bool }
struct DirectMessageAcceptanceContext {
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
struct RoomWriteCommit {
    let outcome: V2SendMessageOutcome
    let directPolicyCacheUpdate: V2DirectSendPolicyCache.Entry?
    let directRoomLogFastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry?
    /// 当本次提交设置了某一侧单调的首次发送标记时，
    /// 反方向的缓存可以从紧邻其前的配对修订推进，而无需再做一次完整策略读取。
    ///
    /// PostgreSQL 的修订谓词对之后每一次快速追加仍是权威。
    let reciprocalDirectReplyCacheUpdate: DirectReplyCacheUpdate?
    /// 命令额度只有在本事务从 Fluent 成功返回之后才算已提交。
    ///
    /// 所有非成功路径都会在重试闭包内部把它归还给本地池。
    let shardAdmissionCommandCredit: V2ShardAdmissionCommandCreditPool.Token?
    /// 每房间命令额度在消息事务之前就已持久预扣，且只有在该事务提交时才被消耗。
    let roomAdmissionCommandCredit: V2RoomAdmissionCommandCreditPool.Token?
    /// 一次正常提交的追加会贡献证据，表明该房间在本地足够热，
    /// 未来调用可以使用预扣的房间额度。
    /// 它刻意只在规范事务提交之后才被收尾。
    let roomAdmissionHeatObservation: UUID?

    init(
        outcome: V2SendMessageOutcome,
        directPolicyCacheUpdate: V2DirectSendPolicyCache.Entry? = nil,
        directRoomLogFastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry? = nil,
        reciprocalDirectReplyCacheUpdate: DirectReplyCacheUpdate? = nil,
        shardAdmissionCommandCredit: V2ShardAdmissionCommandCreditPool.Token? = nil,
        roomAdmissionCommandCredit: V2RoomAdmissionCommandCreditPool.Token? = nil,
        roomAdmissionHeatObservation: UUID? = nil
    ) {
        self.outcome = outcome
        self.directPolicyCacheUpdate = directPolicyCacheUpdate
        self.directRoomLogFastAppendCacheUpdate = directRoomLogFastAppendCacheUpdate
        self.reciprocalDirectReplyCacheUpdate = reciprocalDirectReplyCacheUpdate
        self.shardAdmissionCommandCredit = shardAdmissionCommandCredit
        self.roomAdmissionCommandCredit = roomAdmissionCommandCredit
        self.roomAdmissionHeatObservation = roomAdmissionHeatObservation
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
