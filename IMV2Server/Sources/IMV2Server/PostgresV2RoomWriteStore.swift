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
    var authorizationGrants: [String: V2DirectAuthorizationGrant]?
    private var authorizationRecordedAt: Date?
    private var authorizationResolutionDatabase: (any Database)?
    var controlScopeRoomKinds: [UUID: String]?
    // 在一次限定范围的值拷贝生命周期内保持不可变。共享缓存和额度 Actor
    // 保持原有身份；不使用可变的隐式路由。
    var ownerRoutes: [UUID: V2RoomShardRoute]?
    var activationScope: V2RoomActivationWriteScope?
    var forwardOwnerSourceRoomID: UUID?
    private var controlPolicyScope: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]?
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
    private var existingOperationTransaction = false
    func usingOperationTransaction() -> Self { var copy=self;copy.existingOperationTransaction=true;copy.shardAdmissionCommandCreditPool=nil;copy.roomAdmissionCommandCreditPool=nil;return copy }

    public func usingActivationScope(_ scope: V2RoomActivationWriteScope) -> Self {
        var copy = self
        copy.activationScope = scope
        return copy
    }

    /// 预留操作可能在此执行器的常规轮次之外改变事实。
    /// 释放栅栏前清除提示；SQL 中的事实仍是权威。
    func invalidateActorHints(token: V2RoomActivationToken) async {
        guard let room = token.roomID.uuidValue else { return }
        await directSendPolicyCache.invalidate(roomID: room)
        await directRoomLogFastAppendCache.invalidate(roomID: room)
        await hybridGroupShardCreditSnapshotCache.invalidate([room])
    }

    /// Host 仅在执行器的 SQL 与批次处理结束后调用此方法。
    /// 未使用的额度属于这一确切代次，不能转交给后继代次。
    func closeActorState(token: V2RoomActivationToken) async {
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
        guard !grants.isEmpty, grants.count <= 128, v2PostgresTimestampCanEncode(now) else {
            throw V2DirectAuthorizationIntentError.invalidRequest
        }
        var copy = self
        var attempts: [String: V2DirectAuthorizationGrant] = [:]
        var policies: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy] = [:]
        var kinds = controlScopeRoomKinds ?? [:]
        for grant in grants {
            let attempt = grant.attempt
            try attempt.validate()
            guard grant.policy.sender.userID == attempt.senderID,
                  grant.policy.recipient.userID == attempt.recipientID else {
                throw V2DirectAuthorizationIntentError.identityConflict
            }
            let key = authorizationOperationKey(roomID: attempt.roomID, senderID: attempt.senderID, clientMessageID: attempt.clientMessageID)
            guard attempts.updateValue(grant, forKey: key) == nil else { throw V2DirectAuthorizationIntentError.invalidRequest }
            let cacheKey = V2DirectSendPolicyCache.Key(roomID: attempt.roomID, senderID: attempt.senderID)
            if let existing = policies[cacheKey], existing != grant.policy { throw V2DirectAuthorizationIntentError.identityConflict }
            policies[cacheKey] = grant.policy
            kinds[attempt.roomID] = "direct"
        }
        copy.authorizationGrants = attempts
        copy.authorizationRecordedAt = now
        copy.controlPolicyScope = policies
        copy.controlScopeRoomKinds = kinds
        return copy
    }

    private func withRoomWriteTransaction<Result: Sendable>(
        _ operation: @escaping @Sendable (any Database) async throws -> Result
    ) async throws -> Result {
        try await v2WithPostgresTransactionRetry(database: database,
            classifyCommitFailure: activationScope != nil,
            useRoomDeadline: activationScope != nil,existingTransaction:existingOperationTransaction) { transaction in
            // 房间期限事务在此代码块开始前已设置相同的 LOCAL 限制。
            // 下方激活栅栏仍会在加锁前重新应用；中间再次设置不会增加保护。
            let result = try await operation(transaction)
            if let grants = authorizationGrants {
                guard let recordedAt = authorizationRecordedAt else { throw V2DirectAuthorizationIntentError.corruptPersistence }
                for key in grants.keys.sorted() {
                    guard let grant = grants[key] else { throw V2DirectAuthorizationIntentError.corruptPersistence }
                    _ = try await PostgresV2DirectAuthorizationReceiptStore().finishIfPresent(
                        grant.attempt, now: recordedAt, transaction: transaction)
                }
            }
            return result
        }
    }

    /// 常规标量接受和条件式群组批次使用此事务绑定的栅栏；
    /// 其他写入者仍使用通用 API。
    private func withRoomWriteTransactionWithFenceContext<Result: Sendable>(
        _ operation: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext?) async throws -> Result
    ) async throws -> Result {
        try await v2WithPostgresTransactionRetryWithRoomContext(database: database,
            classifyCommitFailure: activationScope != nil,
            useRoomDeadline: activationScope != nil,existingTransaction:existingOperationTransaction) { transaction, context in
            let result = try await operation(transaction, context)
            if let grants = authorizationGrants {
                guard let recordedAt = authorizationRecordedAt else {
                    throw V2DirectAuthorizationIntentError.corruptPersistence
                }
                for key in grants.keys.sorted() {
                    guard let grant = grants[key] else {
                        throw V2DirectAuthorizationIntentError.corruptPersistence
                    }
                    _ = try await PostgresV2DirectAuthorizationReceiptStore().finishIfPresent(
                        grant.attempt, now: recordedAt, transaction: transaction)
                }
            }
            return result
        }
    }

    private func prepareAuthorization(roomID: UUID, senderID: UUID, clientMessageID: UUID, sql: any SQLDatabase) async throws {
        guard let grants = authorizationGrants else { return }
        if controlScopeRoomKinds?[roomID] == "group" { return }
        let key = authorizationOperationKey(roomID: roomID, senderID: senderID, clientMessageID: clientMessageID)
        guard let grant = grants[key], let transaction = sql as? any Database else {
            throw V2DirectAuthorizationIntentError.identityConflict
        }
        let prior = try await PostgresV2DirectAuthorizationReceiptStore().checkAttempt(grant.attempt, transaction: transaction)
        guard prior?.disposition != .aborted else { throw V2DirectAuthorizationReceiptError.attemptAborted }
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
        guard !commands.isEmpty, commands.count <= 128 else { throw V2DirectAuthorizationIntentError.invalidRequest }
        let keys = try Set(commands.map { V2DirectSendPolicyCache.Key(roomID: try uuid($0.roomID), senderID: try uuid($0.senderUserID)) })
        let input = try roomWriteJSON(keys.map { ["room_id": $0.roomID.uuidString, "sender_id": $0.senderID.uuidString] })
        let sql = try sqlDatabase(from: database)
        let rows = try await sql.raw("""
            SELECT input.room_id, input.sender_id, room.room_kind, room.room_shard_id, room.owner_epoch,
                CASE WHEN pair.lower_user_id = input.sender_id THEN pair.higher_user_id ELSE pair.lower_user_id END AS recipient_id
            FROM jsonb_to_recordset(\(bind: input)::jsonb) AS input(room_id uuid, sender_id uuid)
            JOIN im_v2.rooms room ON room.room_id = input.room_id
            LEFT JOIN im_v2.direct_room_pairs pair ON pair.room_id = input.room_id AND room.room_kind = 'direct'
                AND input.sender_id IN (pair.lower_user_id, pair.higher_user_id)
            """).all(decoding: DurableAuthorizationRouteRow.self)
        guard rows.count == keys.count else { throw V2RoomWriteStoreError.roomNotFound }
        let routes = Dictionary(uniqueKeysWithValues: rows.map { (V2DirectSendPolicyCache.Key(roomID: $0.roomID, senderID: $0.senderID), $0) })
        var base = self
        base.controlScopeRoomKinds = Dictionary(rows.map { ($0.roomID, $0.kind) }, uniquingKeysWith: { first, _ in first })
        base.controlPolicyScope = [:]
        let requests: [V2DirectAuthorizationRequest] = try commands.compactMap { command in
            let room = try uuid(command.roomID), sender = try uuid(command.senderUserID)
            guard let row = routes[.init(roomID: room, senderID: sender)] else { throw V2DirectAuthorizationIntentError.corruptPersistence }
            if row.kind == "group" { return nil }
            guard row.kind == "direct", let recipient = row.recipientID, command.fingerprint.version == 3 else {
                throw V2RoomWriteStoreError.actorNotEligible
            }
            return .init(roomID: room, senderID: sender, clientMessageID: try uuid(command.clientMessageID),
                recipientID: recipient, ownerShardID: row.shardID, ownerEpoch: row.epoch, fingerprint: command.fingerprint.digest)
        }
        if requests.isEmpty { return try await operation(base) }
        let grants = try await PostgresV2DirectAuthorizationIntentStore(database: controlDatabase).reserve(requests, now: now)
        let scoped = try base.usingAuthorizationGrants(grants, now: now)
        // 进入任何归属方事务前，预留操作已经提交。
        let result = try await operation(scoped)
        // The enclosing execution receipt transaction has not committed yet.
        // Its durable control intent is resolved by the existing owner-proof worker after commit.
        if existingOperationTransaction { return result }
        // 在可能失败的 ACK 前，先完成缓存与已消耗准入额度的收尾。
        // 此处传输失败不会解除义务；重试和恢复读取不可变的归属方证明，
        // 也不会返还已消耗的额度。
        do { try await acknowledgeAuthorizations(grants, now: now) }
        catch {
            if activationScope != nil { throw V2RoomTransactionOutcomeUnknown() }
            throw error
        }
        return result
    }

    private func acknowledgeAuthorizations(_ grants: [V2DirectAuthorizationGrant], now: Date) async throws {
        guard let acknowledgement = authorizationResolutionDatabase else { throw V2DirectAuthorizationCoordinationError.ownerUnavailable }
        let intents = PostgresV2DirectAuthorizationIntentStore(database: acknowledgement)
        do {
            for grant in grants {
                if let receipt = try await PostgresV2DirectAuthorizationReceiptStore().committedReceipt(grant.attempt, database: database) {
                    _ = try await intents.resolve(grant.attempt, receipt: receipt, now: now)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 此操作可能已提交。保留持久义务并映射为可重试协议错误，
            // 不得将 ACK 或数据库失败归类为新的命令身份冲突。
            throw V2DirectAuthorizationCoordinationError.ownerUnavailable
        }
    }

    private func controlPolicy(roomID: UUID, senderID: UUID, recipientID: UUID? = nil) throws -> V2DirectSendControlPolicy? {
        guard let scope = controlPolicyScope else { return nil }
        if controlScopeRoomKinds?[roomID] == "group" { return nil }
        guard let policy = scope[.init(roomID: roomID, senderID: senderID)],
              policy.sender.userID == senderID,
              recipientID == nil || recipientID == policy.recipient.userID
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return policy
    }

    func senderIsActive(_ local: Bool?, roomID: UUID, senderID: UUID) throws -> Bool {
        try controlPolicy(roomID: roomID, senderID: senderID)?.sender.isActive ?? (local == true)
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
        if let prior = scoped.ownerRoutes?[source], prior != sourceOwnerRoute { throw V2RoomOwnerFenceError.ownerChanged }
        scoped.ownerRoutes?[source] = sourceOwnerRoute
        scoped.forwardOwnerSourceRoomID = source
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
        var scoped = usingActivationScope(try .init(tokens: activationTokens))
        scoped.ownerRoutes = try Dictionary(uniqueKeysWithValues: activationTokens.map {
            (try uuid($0.roomID), try V2RoomShardRoute(shardID: $0.owner.shardID, epoch: $0.owner.epoch))
        })
        scoped.forwardOwnerSourceRoomID = try uuid(sourceRoomID)
        return try await scoped.acceptPreparedActorForwardPair(request: request,
            prepareLedger: prepareLedger, recordLedger: recordLedger)
    }

    private func acceptPreparedActorForwardPair(
        request: V2RoomWriteRequest,
        prepareLedger: @escaping @Sendable (any Database) async throws -> Void,
        recordLedger: @escaping @Sendable (V2SendMessageOutcome, any Database) async throws -> Void
    ) async throws -> V2SendMessageOutcome {
        if let controlDatabase, controlPolicyScope == nil {
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
                let accepted = try await acceptInTransaction(command: request.command,
                    capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now,
                    roomID: room, senderID: sender, cachedDirectPolicy: nil, transaction: transaction)
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
        scoped.ownerRoutes = routes
        return scoped
    }

    /// 校验给定房间的归属路由均已选定。
    ///
    /// 操作锁必须先于本查询取得。`NO KEY UPDATE` 在围栏任期/分片更新的同时，
    /// 保持与既有追加/外键锁兼容。加锁后读取当前归属，拒绝过期路由。
    ///
    /// - Parameters:
    ///   - roomIDs: 待校验归属的房间标识。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 存在未选定归属的房间时抛出。
    func requireSelectedOwners(_ roomIDs: [UUID], sql: any SQLDatabase) async throws {
        let rooms = Set(roomIDs)
        if let ownerRoutes, !rooms.allSatisfy({ ownerRoutes[$0] != nil }) {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        let requested = try roomWriteJSON(rooms.map(\.uuidString))
        let rows = try await sql.raw("""
            SELECT room_id, room_shard_id, owner_epoch, room_kind FROM im_v2.rooms
            WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: requested)::jsonb))
            ORDER BY room_id FOR NO KEY UPDATE
            """).all(decoding: SelectedRoomOwnerRow.self)
        if let kinds = controlScopeRoomKinds {
            guard rows.allSatisfy({ kinds[$0.roomID] == nil || kinds[$0.roomID] == $0.kind }) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
        }
        if let ownerRoutes {
            guard rows.count == rooms.count, rows.allSatisfy({ row in
                guard let expected = ownerRoutes[row.roomID] else { return false }
                return expected.shardID == row.shardID && expected.epoch == row.epoch
            }) else { throw V2RoomOwnerFenceError.ownerChanged }
        }
        try await activationScope?.require(roomIDs, sql: sql)
        if let grants = authorizationGrants {
            guard let transaction = sql as? any Database else { throw V2DirectAuthorizationIntentError.corruptPersistence }
            for key in grants.keys.sorted() {
                guard let grant = grants[key], rooms.contains(grant.attempt.roomID) else { continue }
                let prior = try await PostgresV2DirectAuthorizationReceiptStore().prepare(grant.attempt, transaction: transaction)
                guard prior?.disposition != .aborted else { throw V2DirectAuthorizationReceiptError.attemptAborted }
            }
        }
        // 没有选定路由时，缺失房间沿用接受路径的普通领域错误。
    }

    public func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let roomID = try uuid(command.roomID)
        let senderID = try uuid(command.senderUserID)
        _ = try activationScope?.token(for: roomID)
        if activationScope != nil, command.forwardedFrom != nil,
           forwardOwnerSourceRoomID == nil {
            throw V2RoomActivationLeaseError.activationChanged
        }
        try validateAuthorizationCommand(command)
        if let controlDatabase, controlPolicyScope == nil {
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
        if !existingOperationTransaction, let fastCommit = try await acceptFastPlainDirectRoomLogIfEligible(
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
        if let controlDatabase, controlPolicyScope == nil {
            // 此处仅检查所有者的简短预检会在控制侧预留之前结束。
            // 下方的接受事务会在写入任何消息前重新检查收件箱、媒体映射、
            // 命令的精确指纹和所有者。
            let preflight: (V2SendMessageCommand?, V2ForwardImportOutcome?) = try await withRoomWriteTransaction { transaction in
                try await preflightForwardInboxInTransaction(export: export, transaction: transaction)
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
                try await acceptForwardInboxInTransaction(
                    export: export, capacityProfile: capacityProfile, limits: limits,
                    identifiers: identifiers, now: now, transaction: transaction
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
            try await completeForwardInboxInTransaction(
                export: export, commit: commit, now: now, transaction: transaction
            )
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
                  Self.isPlainDirectRoomLogBatchShape(request),
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
                  fastPlainDirectPolicyIsEligible(snapshot.policy),
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

    private func resolvedRoomWriteBatchRoutes(
        roomIDs: [UUID]
    ) async -> [V2RoomWriteBatchRouteCache.Route?] {
        var routes = await roomWriteBatchRouteCache.values(for: roomIDs)
        let missingRoomIDs = Set(zip(roomIDs, routes).compactMap { roomID, route in
            route == nil ? roomID : nil
        }).sorted { $0.uuidString < $1.uuidString }
        if !missingRoomIDs.isEmpty,
           let loadedRoutes = try? await loadRoomWriteBatchRoutes(roomIDs: missingRoomIDs)
        {
            await roomWriteBatchRouteCache.insert(loadedRoutes)
            let loadedByRoomID = Dictionary(
                uniqueKeysWithValues: loadedRoutes.map { ($0.roomID, $0.route) }
            )
            for index in routes.indices where routes[index] == nil {
                routes[index] = loadedByRoomID[roomIDs[index]]
            }
        }
        return routes
    }

    /// 只解析建议性批次分类器所需的不可变执行形态。
    ///
    /// 授权、成员、策略、房间状态与容量仍完全只由事务写入路径负责。
    ///
    /// - Parameter roomIDs: 待解析路由的房间标识。
    /// - Returns: 每个房间对应的房间标识与路由。
    /// - Throws: 路由缺失或查询失败时抛出。
    private func loadRoomWriteBatchRoutes(
        roomIDs: [UUID]
    ) async throws -> [(roomID: UUID, route: V2RoomWriteBatchRouteCache.Route)] {
        guard let sql = database as? any SQLDatabase else { return [] }
        let roomIDsJSON = try roomWriteJSON(roomIDs.map(\.uuidString))
        let rows = try await sql.raw("""
            WITH requested AS MATERIALIZED (
                SELECT value::uuid AS room_id
                FROM jsonb_array_elements_text(\(bind: roomIDsJSON)::jsonb) AS value
            )
            SELECT room.room_id, room.room_kind, room.capacity_class
            FROM requested
            JOIN im_v2.rooms AS room USING (room_id)
            """).all(decoding: RoomWriteBatchRouteRow.self)
        return rows.map { row in
            let route: V2RoomWriteBatchRouteCache.Route
            if row.roomKind == "direct" {
                route = .direct
            } else if row.roomKind == "group",
                      row.capacityClass == V2GroupCapacityClass.large.rawValue {
                route = .large
            } else {
                route = .individual
            }
            return (
                roomID: row.roomID,
                route: route
            )
        }
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
                try await acceptInTransaction(
                    command: command,
                    capacityProfile: capacityProfile,
                    identifiers: identifiers,
                    now: now,
                    roomID: roomID,
                    senderID: senderID,
                    cachedDirectPolicy: cachedDirectPolicy,
                    fenceContext: fenceContext,
                    transaction: transaction
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
        if let controlDatabase, controlPolicyScope == nil {
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
        guard requests.allSatisfy(Self.isPlainDirectRoomLogBatchShape) else {
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
              requests.allSatisfy(Self.isPlainDirectRoomLogBatchShape),
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
                let contexts = try await PlainHybridGroupPreflight.load(orderedRequests, sql: sql)
                guard contexts.count == orderedRequests.count else {
                    throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
                }

                var isolatedIndices: [Int] = []
                var prepared: [PreparedPlainHybridGroupAppend] = []
                var reducedRoomStates: [UUID: V2RoomCommandState] = [:]
                var reducedTimelineSequences: [UUID: UInt64] = [:]
                prepared.reserveCapacity(orderedRequests.count)
                for ((item, context), acquisition) in zip(
                    zip(orderedRequests, contexts), acquisitions
                ) {
                    guard context.ordinal == item.preflightOrdinal else {
                        throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
                    }
                    guard case .granted(_, let effectiveShardState) = acquisition,
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
                        isolatedIndices.append(item.originalIndex)
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
                    guard case .accepted(let initialWriteSet) = result else {
                        isolatedIndices.append(item.originalIndex)
                        continue
                    }
                    let previousTimelineSequence = try reducedTimelineSequences[item.roomID]
                        ?? unsigned(context.room.timelineSequence)
                    let (nextTimelineSequence, timelineOverflow) =
                        previousTimelineSequence.addingReportingOverflow(1)
                    guard !timelineOverflow else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    let writeSet = try withTimelineSequence(
                        initialWriteSet,
                        timelineSequence: nextTimelineSequence
                    )
                    reducedRoomStates[item.roomID] = writeSet.nextRoomState
                    reducedTimelineSequences[item.roomID] = nextTimelineSequence
                    let accepted = writeSet.acceptedMessage.materialized(
                        mediaPresentations: [],
                        groupCapacityClass: .large,

                        sourceEventID: writeSet.eventID,
                        acceptedMembershipRevision: try unsigned(context.room.membershipRevision)
                    )
                    let reservation = try shardAdmissionReservation(
                        from: effectiveShardState,
                        to: writeSet.nextShardState
                    )
                    guard reservation.commandDelta == 1
                    else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    prepared.append(try .init(
                        originalIndex: item.originalIndex,
                        request: item.request,
                        room: context.room,
                        writeSet: writeSet,
                        accepted: accepted,
                        reservation: reservation
                    ))
                }
                if !isolatedIndices.isEmpty {
                    throw V2AtomicRoomWriteBatchError(
                        reason: .authorizationState,
                        isolatedRequestIndices: isolatedIndices.sorted()
                    )
                }
                guard prepared.count == orderedRequests.count else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }

                try await PlainHybridGroupWritePath.persist(inputs: prepared.map(\.input), sql: sql)
                return prepared.map { append in
                    OrderedRoomWriteCommit(
                        originalIndex: append.originalIndex,
                        cacheKey: append.cacheKey,
                        commit: .init(
                            outcome: .accepted(append.accepted)
                        )
                    )
                }
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
        await shardAdmissionCommandCreditPool.commit(grantedTokens)
        do {
        var outcomes = Array<V2SendMessageOutcome?>(
            repeating: nil,
            count: requests.count
        )
        for item in committed {
            guard outcomes.indices.contains(item.originalIndex) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            outcomes[item.originalIndex] = try roomWritePersistedAcceptanceOutcome(item.commit.outcome)
        }
        guard outcomes.allSatisfy({ $0 != nil }) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return outcomes.compactMap { $0 }
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
        guard !requests.isEmpty,
              requests.count == knownIDs.count,
              !contentReviewMode.enqueuesJobs,
              let shardAdmissionCommandCreditPool
        else { return nil }

        // 此语句每个房间只推进一次游标。必须在获取任何进程内房间额度之前，
        // 拒绝包含同一房间多条请求的微批次；否则推测性获取可能覆盖预留记录，
        // 而同一房间的另一条请求仍持有执行中的令牌。既有顺序批处理路径会
        // 保留此场景的 FIFO 语义。
        guard Set(knownIDs.map(\.roomID)).count == knownIDs.count else {
            return nil
        }

        // 在预留任何进程内准入额度前，先判定全部缓存和请求形态条件。
        // 缓存命中与未命中混合的批次整体回退；若边遍历边获取额度，
        // 后续输入未命中时会泄漏此前已获取的令牌。
        var candidates: [FastPlainDirectRoomLogCandidate] = []
        candidates.reserveCapacity(requests.count)
        let cacheKeys = knownIDs.map {
            V2DirectRoomLogFastAppendCache.Key(
                roomID: $0.roomID,
                senderID: $0.senderID
            )
        }
        guard let cachedSnapshots = await directRoomLogFastAppendCache.valuesIfAllPresent(
            for: cacheKeys
        ) else {
            return nil
        }
        let roomCreditHints: [Bool]
        if let roomAdmissionCommandCreditPool {
            roomCreditHints = await roomAdmissionCommandCreditPool.shouldUseCredits(
                roomIDs: knownIDs.map(\.roomID),
                now: Date()
            )
        } else {
            roomCreditHints = Array(repeating: false, count: requests.count)
        }
        guard roomCreditHints.count == requests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        for (originalIndex, request) in requests.enumerated() {
            let identity = knownIDs[originalIndex]
            let cached = cachedSnapshots[originalIndex]
            let policy = try controlPolicy(roomID: identity.roomID, senderID: identity.senderID,
                recipientID: cached.policy.recipientID)
            let snapshot = V2DirectRoomLogFastAppendCache.Entry(
                policy: policy.map { cached.policy.applyingControlPolicy($0) } ?? cached.policy,
                roomShardID: cached.roomShardID, capacityProfileID: cached.capacityProfileID,
                membershipRevision: cached.membershipRevision, shardState: cached.shardState)
            guard Self.isPlainDirectRoomLogBatchShape(request),
                  snapshot.capacityProfileID == request.capacityProfile.id,
                  fastPlainDirectPolicyIsEligible(snapshot.policy),
                  let lease = snapshot.shardState.lease,
                  lease.validUntil > request.now
            else {
                return nil
            }

            let usesRoomAdmissionCredits = roomCreditHints[originalIndex]
            candidates.append(.init(
                originalIndex: originalIndex,
                request: request,
                roomID: identity.roomID,
                senderID: identity.senderID,
                cacheKey: identity.cacheKey,
                snapshot: snapshot,
                requiresStrangerQuota: fastPlainDirectPolicyRequiresStrangerQuota(
                    snapshot.policy
                ),
                usesRoomAdmissionCredits: usesRoomAdmissionCredits
            ))
        }

        // 每层进程内准入只进入 Actor 一次。保持先房间、后分片的既有顺序，
        // 同时避免常见的热批次为每条消息创建两个串行执行器任务。
        var roomAcquisitions = Array<V2RoomAdmissionCommandCreditPool.Acquisition?>(
            repeating: nil,
            count: candidates.count
        )
        let roomCreditIndices = candidates.indices.filter {
            candidates[$0].usesRoomAdmissionCredits
        }
        if let roomAdmissionCommandCreditPool, !roomCreditIndices.isEmpty {
            let acquisitions = try await roomAdmissionCommandCreditPool.acquire(
                roomCreditIndices.map {
                    let candidate = candidates[$0]
                    return .init(
                        roomID: candidate.roomID,
                        shardState: candidate.snapshot.shardState,
                        now: candidate.request.now,
                        activation: try activationScope?.token(for: candidate.roomID)
                    )
                }
            )
            guard acquisitions.count == roomCreditIndices.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            for (index, acquisition) in zip(roomCreditIndices, acquisitions) {
                roomAcquisitions[index] = acquisition
            }
            guard acquisitions.allSatisfy({
                if case .granted = $0 { return true }
                return false
            }) else {
                let granted = zip(roomCreditIndices, acquisitions).compactMap {
                    index, acquisition -> (token: V2RoomAdmissionCommandCreditPool.Token, now: Date)? in
                    guard case .granted(let token) = acquisition else { return nil }
                    return (token, candidates[index].request.now)
                }
                await roomAdmissionCommandCreditPool.release(granted)
                return nil
            }
        }

        let shardAcquisitions: [V2ShardAdmissionCommandCreditPool.Acquisition]
        do {
            shardAcquisitions = try await shardAdmissionCommandCreditPool.acquire(
                candidates.map { candidate in
                    .init(
                        roomShardID: candidate.snapshot.roomShardID,
                        capacityProfileID: candidate.snapshot.capacityProfileID,
                        shardState: candidate.snapshot.shardState,
                        now: candidate.request.now
                    )
                }
            )
        } catch {
            await releaseFastPlainDirectRoomLogRoomCredits(
                candidates: candidates,
                acquisitions: roomAcquisitions
            )
            throw error
        }
        guard shardAcquisitions.count == candidates.count else {
            await releaseFastPlainDirectRoomLogRoomCredits(
                candidates: candidates,
                acquisitions: roomAcquisitions
            )
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard shardAcquisitions.allSatisfy({
            if case .granted = $0 { return true }
            return false
        }) else {
            let granted: [V2ShardAdmissionCommandCreditPool.Token] =
                shardAcquisitions.compactMap { acquisition in
                guard case .granted(let token, _) = acquisition else { return nil }
                return token
            }
            await shardAdmissionCommandCreditPool.release(granted, now: Date())
            await releaseFastPlainDirectRoomLogRoomCredits(
                candidates: candidates,
                acquisitions: roomAcquisitions
            )
            return nil
        }

        var prepared: [FastPlainDirectRoomLogAppend] = []
        prepared.reserveCapacity(candidates.count)
        for index in candidates.indices {
            let candidate = candidates[index]
            let roomCreditToken: V2RoomAdmissionCommandCreditPool.Token?
            if case .granted(let token)? = roomAcquisitions[index] {
                roomCreditToken = token
            } else {
                roomCreditToken = nil
            }
            guard case .granted(let shardCreditToken, _) = shardAcquisitions[index] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            prepared.append(.init(
                originalIndex: candidate.originalIndex,
                request: candidate.request,
                roomID: candidate.roomID,
                senderID: candidate.senderID,
                cacheKey: candidate.cacheKey,
                snapshot: candidate.snapshot,
                requiresStrangerQuota: candidate.requiresStrangerQuota,
                usesRoomAdmissionCredits: candidate.usesRoomAdmissionCredits,
                roomCreditToken: roomCreditToken,
                shardCreditToken: shardCreditToken
            ))
        }

        let ordered = prepared.sorted { $0.roomID < $1.roomID }
        let lockRequests = ordered.enumerated().map { ordinal, append in
            OrderedRoomWriteRequest(
                originalIndex: append.originalIndex,
                request: append.request,
                roomID: append.roomID,
                senderID: append.senderID,
                cacheKey: append.cacheKey,
                cachedDirectPolicy: append.snapshot.policy,
                usesRoomAdmissionCredits: append.usesRoomAdmissionCredits,
                preflightOrdinal: ordinal
            )
        }

        do {
            await directRoomLogFastAppendCache.recordAttempt(count: ordered.count)
            let committed = try await withRoomWriteTransaction { transaction in
                let sql = try sqlDatabase(from: transaction)
                // 幂等锁须单独获取。PostgreSQL 在运行 CTE 前固定语句快照；
                // 提前加锁才能让条件语句看到刚提交的重试结果，避免将其当作新追加。
                try await acquireMessageOperationLocks(lockRequests, sql: sql)
                try await requireSelectedOwners(lockRequests.map(\.roomID), sql: sql)
                let allocations = try await persistFastPlainDirectRoomLogMessages(
                    ordered, sql: sql
                )
                guard allocations.count == ordered.count else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return try zip(ordered, allocations).enumerated().map {
                    offset, pair in
                    let (append, allocation) = pair
                    guard allocation.ordinal == offset else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    let draft = V2AcceptedMessageDraft(
                        messageID: append.request.identifiers.messageID,
                        roomID: append.request.command.roomID,
                        roomSequence: try unsigned(allocation.roomSequence),
                        timelineSequence: try unsigned(allocation.timelineSequence),
                        senderUserID: append.request.command.senderUserID,
                        clientMessageID: append.request.command.clientMessageID,
                        text: append.request.command.text,
                        entities: append.request.command.entities,

                        createdAt: append.request.now
                    )
                    let accepted = draft.materialized(
                        mediaPresentations: [],

                        sourceEventID: append.request.identifiers.eventID,
                        acceptedMembershipRevision: try unsigned(
                            append.snapshot.membershipRevision
                        ),
                        directRecipientUserID: try .init(
                            append.snapshot.policy.recipientID.uuidString
                        )
                    )
                    return OrderedRoomWriteCommit(
                        originalIndex: append.originalIndex,
                        cacheKey: append.cacheKey,
                        commit: .init(
                            outcome: .accepted(accepted),
                            // 映射得到的控制侧事实随外层事务失效。
                            // 共享缓存只保留原始的所有者快照。
                            directPolicyCacheUpdate: cachedSnapshots[append.originalIndex].policy,
                            directRoomLogFastAppendCacheUpdate: cachedSnapshots[append.originalIndex],
                            shardAdmissionCommandCredit: append.shardCreditToken,
                            roomAdmissionCommandCredit: append.roomCreditToken,
                            roomAdmissionHeatObservation: append.roomCreditToken == nil
                                && roomAdmissionCommandCreditPool != nil
                                ? append.roomID : nil
                        )
                    )
                }
            }
            await directRoomLogFastAppendCache.recordCommitted(count: ordered.count)
            return committed
        } catch is V2AtomicRoomWriteBatchError {
            for append in ordered {
                await directRoomLogFastAppendCache.invalidate(.init(
                    roomID: append.roomID, senderID: append.senderID
                ))
            }
            await directRoomLogFastAppendCache.recordFallback(count: ordered.count)
            await releaseFastPlainDirectRoomLogCredits(ordered)
            return nil
        } catch {
            await releaseFastPlainDirectRoomLogCredits(ordered,
                outcomeUnknown: error is V2RoomTransactionOutcomeUnknown)
            throw error
        }
    }

    private func releaseFastPlainDirectRoomLogCredits(
        _ appends: [FastPlainDirectRoomLogAppend],
        outcomeUnknown: Bool = false
    ) async {
        for append in appends {
            if outcomeUnknown {
                await shardAdmissionCommandCreditPool?.discard(append.shardCreditToken)
                if let token = append.roomCreditToken {
                    await roomAdmissionCommandCreditPool?.discard(token)
                }
                continue
            }
            if let shardAdmissionCommandCreditPool {
                await shardAdmissionCommandCreditPool.release(
                    append.shardCreditToken, now: append.request.now
                )
            }
            if let roomCreditToken = append.roomCreditToken,
               let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: append.request.now)
            }
        }
    }

    private func releaseFastPlainDirectRoomLogRoomCredits(
        candidates: [FastPlainDirectRoomLogCandidate],
        acquisitions: [V2RoomAdmissionCommandCreditPool.Acquisition?]
    ) async {
        guard let roomAdmissionCommandCreditPool else { return }
        let granted = zip(candidates, acquisitions).compactMap {
            candidate, acquisition -> (token: V2RoomAdmissionCommandCreditPool.Token, now: Date)? in
            guard case .granted(let token)? = acquisition else { return nil }
            return (token, candidate.request.now)
        }
        await roomAdmissionCommandCreditPool.release(granted)
    }

    private func fastPlainDirectPolicyIsEligible(
        _ policy: V2DirectSendPolicyCache.Entry
    ) -> Bool {
        fastPlainDirectPolicyIsCacheCandidate(policy)
            && policy.senderHasReplied
            && (policy.isFriend || policy.recipientHasReplied || policy.allowsStrangers)
    }

    private func fastPlainDirectPolicyRequiresStrangerQuota(
        _ policy: V2DirectSendPolicyCache.Entry
    ) -> Bool {
        !policy.isFriend && !policy.recipientHasReplied
    }

    /// 判断某个单聊策略快照是否适合作为缓存候选。
    ///
    /// 首次被接受的发送可能仍在等待对端的单调回复标记。
    /// 保留这份本已稳定的快照，
    /// 可以让提交后的对向更新直接提升它，而无需再做一次完整授权解码；
    /// 真正的快速追加仍需满足上方完整谓词，并在 PostgreSQL 中逐项校验每个修订。
    ///
    /// - Parameter policy: 待判断的单聊策略快照。
    /// - Returns: 是否可作为缓存候选。
    func fastPlainDirectPolicyIsCacheCandidate(
        _ policy: V2DirectSendPolicyCache.Entry
    ) -> Bool {
        policy.senderIsActive
            && policy.senderProfileVisibleToRecipient
            && policy.senderCanSend == true
            && policy.recipientIsActive
            && !policy.blocked
            && policy.senderAccountKind == nil
            && policy.recipientAccountKind == nil
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
    private func acceptHotDirectRoomLog(
        request: V2RoomWriteRequest,
        roomID: UUID,
        senderID: UUID,
        cacheKey: V2DirectSendPolicyCache.Key,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?
    ) async throws -> RoomWriteCommit {
        guard roomAdmissionCommandCreditPool != nil else {
            throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
        }
        let ordered = OrderedRoomWriteRequest(
            originalIndex: 0,
            request: request,
            roomID: roomID,
            senderID: senderID,
            cacheKey: cacheKey,
            cachedDirectPolicy: cachedDirectPolicy,
            usesRoomAdmissionCredits: true,
            preflightOrdinal: 0
        )
        return try await withRoomWriteTransaction { transaction in
            var prepared: PreparedDirectRoomLogAppend?
            do {
                let sql = try sqlDatabase(from: transaction)
                try await acquireMessageOperationLocks([ordered], sql: sql)
                try await requireSelectedOwners([ordered.roomID], sql: sql)
                let contexts = try await PlainDirectRoomLogPreflight.load([ordered], sql: sql)
                guard contexts.count == 1 else {
                    throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
                }
                switch try await prepareDirectRoomLogAppend(ordered, preflight: contexts[0]) {
                case .outcome(let commit):
                    return commit
                case .append(let append):
                    prepared = append
                    let commits = try await completePreparedDirectRoomLogAppends([append], sql: sql)
                    guard commits.count == 1, let commit = commits.first?.commit else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    return commit
                }
            } catch {
                if let append = prepared {
                    if let token = append.commit.shardAdmissionCommandCredit,
                       let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(token, now: append.now)
                    }
                    if let token = append.commit.roomAdmissionCommandCredit,
                       let roomAdmissionCommandCreditPool {
                        await roomAdmissionCommandCreditPool.release(token, now: append.now)
                    }
                }
                throw error
            }
        }
    }

    /// 在所有受影响的房间、成员、单聊配对与策略行都已完成预检加锁之后，
    /// 完成权威持久追加。
    ///
    /// 让真正的微批与热房间单条路径共享它，
    /// 可以避免授权、投影或令牌收尾逻辑出现行为漂移。
    ///
    /// - Parameters:
    ///   - prepared: 已准备的单聊房间日志追加。
    ///   - sql: 参与当前事务的数据库连接。
    ///   - stageMetrics: 可选的阶段耗时记录器。
    /// - Returns: 各请求对应的有序提交结果。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    private func completePreparedDirectRoomLogAppends(
        _ prepared: [PreparedDirectRoomLogAppend],
        sql: any SQLDatabase,
        stageMetrics: V2DirectRoomLogAppendStageMetrics? = nil
    ) async throws -> [OrderedRoomWriteCommit] {
        guard !prepared.isEmpty else { return [] }
        let policyStartedAt = ContinuousClock.now
        do {
            try await persistPlainDirectRoomLogBatchPolicyMutations(prepared, sql: sql)
        } catch {
            stageMetrics?.record(.policyMutations, duration: policyStartedAt.duration(to: .now))
            throw error
        }
        stageMetrics?.record(.policyMutations, duration: policyStartedAt.duration(to: .now))

        let messageStartedAt = ContinuousClock.now
        do {
            try await persistPlainRoomLogMessages(
                inputs: prepared.enumerated().map { ordinal, append in
                    append.input.withOrdinal(ordinal)
                },
                sql: sql
            )
        } catch {
            stageMetrics?.record(.messagePersistence, duration: messageStartedAt.duration(to: .now))
            throw error
        }
        stageMetrics?.record(.messagePersistence, duration: messageStartedAt.duration(to: .now))

        let projectionStartedAt = ContinuousClock.now
        let projectionChanges: [DirectPostAcceptanceProjectionChanges]
        do {
            projectionChanges = try await appendDirectPostAcceptanceProjections(
                for: prepared,
                sql: sql
            )
        } catch {
            stageMetrics?.record(
                .projectionPersistence,
                duration: projectionStartedAt.duration(to: .now)
            )
            throw error
        }
        stageMetrics?.record(
            .projectionPersistence,
            duration: projectionStartedAt.duration(to: .now)
        )
        guard projectionChanges.count == prepared.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        // 分片额度和可选的房间额度已在开启事务前预扣。
        // 持有这些房间锁期间，不会再次从池中获取额度或进行第二次预留。
        return zip(prepared, projectionChanges).map { append, changes in
            let reciprocalReplyCacheUpdate = append.advancesReplyMarker
                ? DirectReplyCacheUpdate(
                    key: .init(
                        roomID: append.roomID,
                        senderID: append.directContext.recipientID
                    ),
                    expectedDirectPairRevision: append.policyCacheEntry.directPairRevision
                )
                : nil
            var cacheEntry = append.policyCacheEntry
            if append.advancesReplyMarker {
                cacheEntry = cacheEntry.markingSenderHasReplied()
            }
            cacheEntry = cacheEntry.applyingPostAcceptanceProjection(
                senderCapabilityInserted: changes.senderCapabilityInserted,
                recipientProfileInserted: changes.recipientProfileInserted
            )
            let fastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry?
            if fastPlainDirectPolicyIsCacheCandidate(cacheEntry),
               let shardState = append.fastAppendShardState {
                fastAppendCacheUpdate = .init(
                    policy: cacheEntry,
                    roomShardID: append.fastAppendRoomShardID,
                    capacityProfileID: append.fastAppendCapacityProfileID,
                    membershipRevision: append.input.membershipRevision,
                    shardState: shardState
                )
            } else {
                fastAppendCacheUpdate = nil
            }
            return .init(
                originalIndex: append.originalIndex,
                cacheKey: append.cacheKey,
                commit: .init(
                    outcome: append.commit.outcome,
                    directPolicyCacheUpdate: cacheEntry,
                    directRoomLogFastAppendCacheUpdate: fastAppendCacheUpdate,
                    reciprocalDirectReplyCacheUpdate: reciprocalReplyCacheUpdate,
                    shardAdmissionCommandCredit: append.commit.shardAdmissionCommandCredit,
                    roomAdmissionCommandCredit: append.commit.roomAdmissionCommandCredit,
                    roomAdmissionHeatObservation: append.commit.roomAdmissionHeatObservation
                )
            )
        }
    }

    static func isPlainDirectRoomLogBatchShape(
        _ request: V2RoomWriteRequest
    ) -> Bool {
        let command = request.command
        return command.media.isEmpty
            && command.mentions.isEmpty
            && command.replyTo == nil
            && command.forwardedFrom == nil
    }

    private func sqlDatabase(from transaction: any Database) throws -> any SQLDatabase {
        guard let sql = transaction as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return sql
    }

    private func prepareDirectRoomLogAppend(
        _ item: OrderedRoomWriteRequest,
        preflight: PlainDirectRoomLogBatchPreflightRow,
        sequenceOffset: Int64 = 0,
        shardCreditAcquisition: V2ShardAdmissionCommandCreditPool.Acquisition? = nil
    ) async throws -> DirectRoomLogBatchPreparation {
        let request = item.request
        let command = request.command
        let clientMessageID = try uuid(command.clientMessageID)
        guard preflight.ordinal == item.preflightOrdinal else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        let room = try preflight.room.advancingSequences(by: sequenceOffset)
        if let reason = directRoomLogAdmissionMismatchReason(
            room: room,
            request: request
        ) {
            throw V2AtomicRoomWriteBatchError(reason: reason)
        }
        let usesRoomAdmissionCredits = item.usesRoomAdmissionCredits
        // 与激活绑定的额度必须在此事务前预取。
        // 实时热路径在 fastPlainDirectRoomLogCommitsIfEligible 中完成预取；
        // 标准路径则传入 usesRoomAdmissionCredits = false。
        guard activationScope == nil || !usesRoomAdmissionCredits else {
            throw V2AtomicRoomWriteBatchError(reason: .roomCreditModeMismatch)
        }
        let shard: ShardRow
        let roomCommandWindowUsed: Int
        if usesRoomAdmissionCredits {
            shard = try preflight.shard()
            guard try senderIsActive(preflight.senderIsActive, roomID: item.roomID, senderID: item.senderID),
                  let role = preflight.actorRole,
                  V2RoomMembershipRole(rawValue: role) != nil,
                  preflight.muted == false
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
            roomCommandWindowUsed = 0
        } else {
            let admissionSnapshot = try preflight.admissionSnapshot()
            let admission = admissionSnapshot.room
            shard = admissionSnapshot.shard
            guard admission.shardLeaseID == shard.leaseID,
                  admission.shardLeaseGeneration == shard.generation,
                  try senderIsActive(admissionSnapshot.senderIsActive, roomID: item.roomID, senderID: item.senderID),
                  let role = admissionSnapshot.actorRole,
                  V2RoomMembershipRole(rawValue: role) != nil,
                  admissionSnapshot.muted == false
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
            roomCommandWindowUsed = admission.commandWindowUsed
        }
        let directContext = try directMessageContext(from: preflight.directPolicySnapshot(), roomID: item.roomID, senderID: item.senderID)
        guard directContext.restriction == nil,
              directContext.supportAccountID == nil
        else {
            throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
        }

        let shardState = try shard.admissionState()
        let roomCreditToken: V2RoomAdmissionCommandCreditPool.Token?
        if let roomAdmissionCommandCreditPool, usesRoomAdmissionCredits {
            switch try await roomAdmissionCommandCreditPool.acquire(
                roomID: item.roomID,
                shardState: shardState,
                now: request.now
            ) {
            case .granted(let token):
                roomCreditToken = token
            case .rateLimited:
                return .outcome(.init(
                    outcome: .rateLimited(retryAfterSeconds: request.capacityProfile.limits.retryAfterSeconds)
                ))
            case .unavailable(let reason):
                return .outcome(.init(outcome: .unavailable(reason)))
            }
        } else {
            roomCreditToken = nil
        }
        let shardStateForReduction: ShardAdmissionState
        let shardCreditToken: V2ShardAdmissionCommandCreditPool.Token?
        guard let shardPool = shardAdmissionCommandCreditPool else {
            throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
        }
        let acquisition: V2ShardAdmissionCommandCreditPool.Acquisition
        if let shardCreditAcquisition {
            acquisition = shardCreditAcquisition
        } else {
            acquisition = try await shardPool.acquire(
                roomShardID: room.roomShardID,
                capacityProfileID: room.capacityProfileID,
                shardState: shardState,
                now: request.now
            )
        }
        switch acquisition {
        case .granted(let token, let effectiveShardState):
            shardCreditToken = token
            shardStateForReduction = effectiveShardState
        case .rateLimited:
            if let roomCreditToken, let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
            }
            return .outcome(.init(
                outcome: .rateLimited(retryAfterSeconds: request.capacityProfile.limits.retryAfterSeconds)
            ))
        case .unavailable(let reason):
            if let roomCreditToken, let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
            }
            return .outcome(.init(outcome: .unavailable(reason)))
        }
        do {
            let writeSet: PlainDirectRoomLogWriteSet
            if usesRoomAdmissionCredits {
                switch try directRoomLogPrechargedCommandBatchReduction(
                    command: command,
                    nextRoomSequence: roomWriteNextSequence(room.roomSequence),
                    shardState: shardStateForReduction,
                    profile: request.capacityProfile.limits,
                    identifiers: request.identifiers,
                    now: request.now
                ) {
                case .accepted(let transaction):
                    writeSet = .init(
                        acceptedMessage: transaction.acceptedMessage,
                        eventID: transaction.eventID,
                        nextShardState: transaction.nextShardState,
                        roomCommandWindowUsed: roomCommandWindowUsed
                    )
                case .rateLimited(let retryAfterSeconds):
                    if let shardCreditToken, let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                    }
                    if let roomCreditToken, let roomAdmissionCommandCreditPool {
                        await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
                    }
                    return .outcome(.init(
                        outcome: .rateLimited(retryAfterSeconds: retryAfterSeconds)
                    ))
                case .unavailable(let reason):
                    if let shardCreditToken, let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                    }
                    if let roomCreditToken, let roomAdmissionCommandCreditPool {
                        await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
                    }
                    return .outcome(.init(
                        outcome: .unavailable(reason)
                    ))
                }
            } else {
                let admission = try preflight.admissionSnapshot().room
                let roomState = try room.commandState(roomID: command.roomID, admission: admission)
                let result = try roomLogReduction(
                    command: command,
                    roomState: roomState,
                    shardState: shardStateForReduction,
                    profile: request.capacityProfile.limits,
                    identifiers: request.identifiers,
                    now: request.now
                )
                guard case .accepted(let transaction) = result else {
                    if let shardCreditToken, let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                    }
                    return .outcome(.init(
                        outcome: result.outcome()
                    ))
                }
                writeSet = .init(
                    acceptedMessage: transaction.acceptedMessage,
                    eventID: transaction.eventID,
                    nextShardState: transaction.nextShardState,
                    roomCommandWindowUsed: roomCommandWindowUsed
                )
            }
            let timelineMessage = try withTimelineSequence(
                writeSet.acceptedMessage,
                timelineSequence: roomWriteNextSequence(room.timelineSequence)
            )
            let shardReservation = try shardAdmissionReservation(
                from: shardStateForReduction,
                to: writeSet.nextShardState
            )
            guard shardReservation.commandDelta == 1
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let acceptedMessage = timelineMessage.materialized(
                mediaPresentations: [],

                sourceEventID: writeSet.eventID,
                acceptedMembershipRevision: try unsigned(room.membershipRevision),
                directRecipientUserID: .init(uuid: directContext.recipientID)
            )
            let input = try plainRoomLogMessageInput(
                acceptedMessage: timelineMessage,
                fingerprint: request.command.fingerprint,
                eventID: writeSet.eventID,
                commandWindowUsed: writeSet.roomCommandWindowUsed,
                room: room,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: clientMessageID,
                persistsRoomAdmission: !usesRoomAdmissionCredits
            )
            return .append(.init(
                originalIndex: item.originalIndex,
                request: request,
                cacheKey: item.cacheKey,
                roomID: item.roomID,
                senderID: item.senderID,
                input: input,
                now: request.now,
                directContext: directContext,
                policyCacheEntry: try preflight.directPolicyCacheEntry(),
                advancesReplyMarker: !directContext.senderHasReplied,
                fastAppendRoomShardID: room.roomShardID,
                fastAppendCapacityProfileID: room.capacityProfileID,
                fastAppendShardState: writeSet.nextShardState,
                commit: .init(
                    outcome: .accepted(acceptedMessage),
                    directPolicyCacheUpdate: nil,
                    shardAdmissionCommandCredit: shardCreditToken,
                    roomAdmissionCommandCredit: roomCreditToken,
                    roomAdmissionHeatObservation: usesRoomAdmissionCredits ? nil : item.roomID
                )
            ))
        } catch {
            if let shardCreditToken, let shardAdmissionCommandCreditPool {
                await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
            }
            if let roomCreditToken, let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
            }
            throw error
        }
    }

    private func directRoomLogAdmissionMismatchReason(
        room: RoomRow,
        request: V2RoomWriteRequest
    ) -> V2AtomicRoomWriteBatchError.Reason? {
        guard room.kind == "direct" else { return .roomKindMismatch }
        guard room.capacityProfileID == request.capacityProfile.id else {
            return .capacityProfileMismatch
        }
        guard room.frozenAt == nil else { return .roomFrozen }
        return nil
    }

    /// 同房间批次只有在所有单聊配对生产者标记都已建立、
    /// 且房间准入已经由持久额度表示之后才是安全的。
    ///
    /// 这使「每房间一行」的集合追加免于触发陌生人配额、首次回复、
    /// 资料/能力或房间准入等尚未在此建模逐命令顺序的可变效果。
    ///
    /// 该批次仍会锁定权威配对、成员、策略版本与房间行。
    /// 这是一种收窄的有序追加优化，而不是基于缓存的授权捷径。
    ///
    /// - Parameter orderedRequests: 本批有序写入请求。
    /// - Throws: 不满足同房间批次安全前提时抛出。
    private func assertSameRoomBatchSafety(
        orderedRequests: [OrderedRoomWriteRequest],
        contexts: [PlainDirectRoomLogBatchPreflightRow]
    ) throws {
        guard orderedRequests.count == contexts.count else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        let indicesByRoom = Dictionary(grouping: orderedRequests.indices) {
            orderedRequests[$0].roomID
        }
        for indices in indicesByRoom.values where indices.count > 1 {
            guard indices.allSatisfy({ orderedRequests[$0].usesRoomAdmissionCredits }),
                  try indices.allSatisfy({
                      let policy = try contexts[$0].directPolicySnapshot()
                      return policy.senderHasReplied
                          && policy.senderProfileVisibleToRecipient
                          && policy.senderCanSend == true
                  })
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
        }
    }

    private func plainRoomLogMessageInput(
        acceptedMessage: V2AcceptedMessageDraft,
        fingerprint: V2SendMessageFingerprint,
        eventID: EventID,
        commandWindowUsed: Int,
        room: RoomRow,
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        persistsRoomAdmission: Bool
    ) throws -> PlainRoomLogMessageInput {
        return try .init(
            ordinal: 0,
            roomID: roomID,
            messageID: uuid(acceptedMessage.messageID),
            eventID: uuid(eventID),
            senderID: senderID,
            clientMessageID: clientMessageID,
            persistsRoomAdmission: persistsRoomAdmission,
            roomSequence: signed(acceptedMessage.roomSequence),
            timelineSequence: signed(acceptedMessage.timelineSequence),
            commandWindowUsed: commandWindowUsed,
            text: acceptedMessage.text,
            entities: acceptedMessage.entities,
            replyToMessageID: nil,
            forwardedFromMessageID: nil,
            forwardedFromUserID: nil,
            membershipRevision: room.membershipRevision,
            fingerprint: fingerprint,
            createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(acceptedMessage.createdAt)
        )
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
    private func finalizeCommittedAcceptance(
        command: V2SendMessageCommand,
        cacheKey: V2DirectSendPolicyCache.Key,
        commit: RoomWriteCommit
    ) async throws -> V2SendMessageOutcome {
        do {
            return try await finalizeAcceptedValue(command: command, cacheKey: cacheKey, commit: commit)
        } catch {
            if activationScope != nil { throw V2RoomTransactionOutcomeUnknown() }
            throw error
        }
    }

    private func finalizeAcceptedValue(
        command: V2SendMessageCommand,
        cacheKey: V2DirectSendPolicyCache.Key,
        commit: RoomWriteCommit
    ) async throws -> V2SendMessageOutcome {
        // The bound operation still owns the surrounding transaction. Its receipt
        // insert can fail, so no process cache may observe this provisional write.
        if existingOperationTransaction {
            return try roomWritePersistedAcceptanceOutcome(commit.outcome)
        }
        let cacheStartedAt = ContinuousClock.now
        if let entry = commit.directPolicyCacheUpdate {
            await directSendPolicyCache.insert(entry, for: cacheKey)
        }
        if let entry = commit.directRoomLogFastAppendCacheUpdate {
            await directRoomLogFastAppendCache.insert(entry, for: .init(
                roomID: cacheKey.roomID, senderID: cacheKey.senderID
            ))
        }
        if let update = commit.reciprocalDirectReplyCacheUpdate {
            await directSendPolicyCache.markRecipientsHaveReplied([.init(
                key: update.key,
                expectedDirectPairRevision: update.expectedDirectPairRevision
            )])
            await directRoomLogFastAppendCache.markRecipientsHaveReplied([.init(
                key: .init(roomID: update.key.roomID, senderID: update.key.senderID),
                expectedDirectPairRevision: update.expectedDirectPairRevision
            )])
        }
        if let shardCreditToken = commit.shardAdmissionCommandCredit,
           let shardAdmissionCommandCreditPool {
            await shardAdmissionCommandCreditPool.commit(shardCreditToken)
        }
        if let roomCreditToken = commit.roomAdmissionCommandCredit,
           let roomAdmissionCommandCreditPool {
            await roomAdmissionCommandCreditPool.commit(roomCreditToken)
        }
        if let roomID = commit.roomAdmissionHeatObservation,
           let roomAdmissionCommandCreditPool {
            await roomAdmissionCommandCreditPool.recordNormalAdmissionCommit(
                roomID: roomID,
                now: Date()
            )
        }
        appendStageMetrics?.record(
            .cacheFinalization,
            duration: cacheStartedAt.duration(to: .now)
        )
        return try roomWritePersistedAcceptanceOutcome(commit.outcome)
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
            return try await finalizeAcceptedValues(requests: requests, committed: committed)
        } catch {
            if activationScope != nil { throw V2RoomTransactionOutcomeUnknown() }
            throw error
        }
    }

    private func finalizeAcceptedValues(
        requests: [V2RoomWriteRequest],
        committed: [OrderedRoomWriteCommit]
    ) async throws -> [V2SendMessageOutcome] {
        guard committed.count == requests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let cacheFinalizationStartedAt = ContinuousClock.now

        var policyUpdates: [V2DirectSendPolicyCache.Update] = []
        var fastAppendUpdates: [V2DirectRoomLogFastAppendCache.Update] = []
        var reciprocalPolicyUpdates: [V2DirectSendPolicyCache.RecipientReplyUpdate] = []
        var reciprocalFastAppendUpdates: [V2DirectRoomLogFastAppendCache.RecipientReplyUpdate] = []
        var shardTokens: [V2ShardAdmissionCommandCreditPool.Token] = []
        var roomTokens: [V2RoomAdmissionCommandCreditPool.Token] = []
        var heatObservations: [(UUID, Date)] = []
        policyUpdates.reserveCapacity(committed.count)
        fastAppendUpdates.reserveCapacity(committed.count)
        reciprocalPolicyUpdates.reserveCapacity(committed.count)
        reciprocalFastAppendUpdates.reserveCapacity(committed.count)
        shardTokens.reserveCapacity(committed.count)
        roomTokens.reserveCapacity(committed.count)
        heatObservations.reserveCapacity(committed.count)
        // 准入热度属于进程内运行时状态，因此必须像原先逐次提交的收尾逻辑一样
        // 使用运行时时钟。请求时间戳可能是确定生成或重放的，不能用于判断缓存新鲜度。
        let heatObservationNow = Date()

        for item in committed {
            guard requests.indices.contains(item.originalIndex) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            if let entry = item.commit.directPolicyCacheUpdate {
                policyUpdates.append(.init(entry: entry, key: item.cacheKey))
            }
            if let entry = item.commit.directRoomLogFastAppendCacheUpdate {
                fastAppendUpdates.append(.init(
                    entry: entry,
                    key: .init(roomID: item.cacheKey.roomID, senderID: item.cacheKey.senderID)
                ))
            }
            if let update = item.commit.reciprocalDirectReplyCacheUpdate {
                reciprocalPolicyUpdates.append(.init(
                    key: update.key,
                    expectedDirectPairRevision: update.expectedDirectPairRevision
                ))
                reciprocalFastAppendUpdates.append(.init(
                    key: .init(roomID: update.key.roomID, senderID: update.key.senderID),
                    expectedDirectPairRevision: update.expectedDirectPairRevision
                ))
            }
            if let token = item.commit.shardAdmissionCommandCredit {
                shardTokens.append(token)
            }
            if let token = item.commit.roomAdmissionCommandCredit {
                roomTokens.append(token)
            }
            if let roomID = item.commit.roomAdmissionHeatObservation {
                heatObservations.append((roomID, heatObservationNow))
            }
        }

        // 这些修改只是 Actor 隔离的少量字典和计数器更新。
        // 每个 Actor 批量调用一次，比每个 PostgreSQL 微批次创建四个子任务
        // 成本更低且更可预测。
        await directSendPolicyCache.insert(policyUpdates)
        await directRoomLogFastAppendCache.insert(fastAppendUpdates)
        await directSendPolicyCache.markRecipientsHaveReplied(reciprocalPolicyUpdates)
        await directRoomLogFastAppendCache.markRecipientsHaveReplied(
            reciprocalFastAppendUpdates
        )
        if let shardAdmissionCommandCreditPool {
            await shardAdmissionCommandCreditPool.commit(shardTokens)
        }
        if let roomAdmissionCommandCreditPool {
            await roomAdmissionCommandCreditPool.commit(roomTokens)
            await roomAdmissionCommandCreditPool.recordNormalAdmissionCommits(heatObservations)
        }
        appendStageMetrics?.record(
            .cacheFinalization,
            duration: cacheFinalizationStartedAt.duration(to: .now)
        )

        var outcomes = Array<V2SendMessageOutcome?>(repeating: nil, count: requests.count)
        for item in committed {
            outcomes[item.originalIndex] = try roomWritePersistedAcceptanceOutcome(item.commit.outcome)
        }
        guard outcomes.allSatisfy({ $0 != nil }) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return outcomes.compactMap { $0 }
    }

    /// 把归并器算出的分片增量应用到当前行，而不是覆盖基于更早快照推导出的计数器。
    ///
    /// 这样并发房间可以并行完成全部昂贵工作，只在最后一次尾部更新时串行化。
    /// 谓词与 schema 约束保持一致，
    /// 使一次容量竞争变成普通的准入拒绝，而绝不会成为部分提交或约束错误。
    ///
    /// - Parameter initial: 预检得到的初始分片准入状态。
    /// - Returns: 预留结果。
    func shardAdmissionReservation(
        from initial: ShardAdmissionState,
        to next: ShardAdmissionState
    ) throws -> ShardAdmissionReservation {
        guard let initialLease = initial.lease, let nextLease = next.lease,
              initialLease.id == nextLease.id,
              initialLease.generation == nextLease.generation
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        let commandDelta = nextLease.commandWindow.used - initialLease.commandWindow.used
        guard commandDelta >= 0
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        return try .init(
            leaseID: uuid(nextLease.id),
            generation: signed(nextLease.generation),
            commandDelta: commandDelta
        )
    }

    func reserveShardAdmission(
        _ reservation: ShardAdmissionReservation,
        room: RoomRow,
        retryAfterSeconds: Int,
        now: Date,
        sql: any SQLDatabase
    ) async throws {
        let applied = try await sql.raw("""
            UPDATE im_v2.shard_admission_pools
            SET command_window_used = command_window_used + \(bind: reservation.commandDelta)
            WHERE room_shard_id = \(bind: room.roomShardID)
              AND capacity_profile_id = \(bind: room.capacityProfileID)
              AND lease_id = \(bind: reservation.leaseID)
              AND generation = \(bind: reservation.generation)
              AND valid_until > \(bind: now)
              AND command_window_used <= command_window_limit - \(bind: reservation.commandDelta)
            RETURNING 1 AS applied
            """).first(decoding: ShardAdmissionMutationRow.self)
        guard applied != nil else {
            try await throwShardAdmissionRejection(
                reservation,
                room: room,
                retryAfterSeconds: retryAfterSeconds,
                now: now,
                sql: sql
            )
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// 在不削弱权威谓词的前提下，对条件预留的「零行」结果进行分类。
    ///
    /// 这次额外读取只在事务被拒绝时发生；成功预留无需额外读取。
    ///
    /// - Parameters:
    ///   - reservation: 本次分片准入预留。
    ///   - room: 目标房间行。
    ///   - retryAfterSeconds: 建议的重试等待秒数。
    ///   - now: 服务端统一授时时刻。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 租约缺失、过期或触发限流时抛出。
    private func throwShardAdmissionRejection(
        _ reservation: ShardAdmissionReservation,
        room: RoomRow,
        retryAfterSeconds: Int,
        now: Date,
        sql: any SQLDatabase
    ) async throws {
        guard let current = try await sql.raw("""
            SELECT lease_id, generation, valid_until
            FROM im_v2.shard_admission_pools
            WHERE room_shard_id = \(bind: room.roomShardID)
              AND capacity_profile_id = \(bind: room.capacityProfileID)
            """).first(decoding: CurrentShardLeaseRow.self)
        else { throw LateShardAdmissionRejection.unavailable(.missingShardLease) }
        guard current.leaseID == reservation.leaseID,
              current.generation == reservation.generation
        else { throw LateShardAdmissionRejection.unavailable(.missingShardLease) }
        guard current.validUntil > now else {
            throw LateShardAdmissionRejection.unavailable(.expiredShardLease)
        }
        throw LateShardAdmissionRejection.rateLimited(retryAfterSeconds: retryAfterSeconds)
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
        try await prepareAuthorization(roomID: roomID, senderID: senderID, clientMessageID: clientMessageID, sql: sql)
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
            try await prepareAuthorization(roomID: input.roomID, senderID: input.senderID, clientMessageID: input.clientMessageID, sql: sql)
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

    /// `ScalarMessagePreflight.load` 负责一致的数据库快照与锁；
    /// 这次纯映射刻意保持既有的单聊策略判定表不变。
    ///
    /// - Parameter policy: 单聊策略快照行。
    /// - Returns: 单聊消息接受上下文。
    /// - Throws: 快照字段非法时抛出。
    func directMessageContext(
        from localPolicy: DirectMessagePolicySnapshotRow, roomID: UUID, senderID: UUID
    ) throws -> DirectMessageAcceptanceContext {
        let authority = try controlPolicy(roomID: roomID, senderID: senderID, recipientID: localPolicy.recipientUserID)
        let policy = authority.map { localPolicy.applyingControlPolicy($0) } ?? localPolicy
        let recipientID = policy.recipientUserID
        let restriction: V2DirectMessageDenied.Reason?
        if policy.senderAccountKind != nil {
            restriction = policy.senderAccountStatus == "active" && policy.senderAllowsServiceMessages == true ? nil : .generic
            // 特殊主体没有公共网关凭据；到达此分支的调用来自可信服务边界。
        } else if let recipientAccountKind = policy.recipientAccountKind {
            if policy.recipientAccountStatus != "active" {
                restriction = .generic
            } else if recipientAccountKind == "system" {
                restriction = .systemAccountReadOnly
            } else {
                restriction = policy.recipientAllowsCustomerMessages == true ? nil : .generic
            }
        } else if !policy.recipientIsActive || policy.blocked {
            restriction = .generic
        } else if policy.isFriend || policy.recipientHasReplied {
            restriction = nil
        } else {
            restriction = policy.allowsStrangers ? nil : .generic
        }
        return .init(
            recipientID: recipientID,
            restriction: restriction,
            requiresStrangerQuota: policy.senderAccountKind == nil && policy.recipientAccountKind == nil && !policy.isFriend && !policy.recipientHasReplied,
            senderProfileVisibleToRecipient: policy.senderProfileVisibleToRecipient,
            senderCanSend: policy.senderCanSend,
            senderHasReplied: policy.senderHasReplied,
            supportAccountID: policy.recipientAccountKind == "customer_support" && policy.recipientAccountStatus == "active"
                ? recipientID
                : nil
        )
    }

    /// 只有在通用准入归并器接受之后才消耗容量，
    /// 从而为被拒绝的发送保留既有的「配额不丢失」不变量。
    ///
    /// - Parameters:
    ///   - senderID: 发送者标识。
    ///   - recipientID: 接收者标识。
    ///   - policy: 陌生人消息策略。
    ///   - now: 服务端统一授时时刻。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 额度耗尽或写入失败时抛出。
    func consumeDirectMessageQuota(senderID: UUID, recipientID: UUID, policy: V2StrangerMessagePolicy, now: Date, sql: any SQLDatabase) async throws {
        let windowStart = try roomWriteStrangerWindowStart(now: now, interval: policy.window)
        let consumed = try await sql.raw("""
            INSERT INTO im_v2.stranger_message_windows (sender_user_id, recipient_user_id, window_started_at, message_count)
            VALUES (\(bind: senderID), \(bind: recipientID), \(bind: now), 1)
            ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
            SET window_started_at = CASE WHEN im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart) THEN EXCLUDED.window_started_at ELSE im_v2.stranger_message_windows.window_started_at END,
                message_count = CASE WHEN im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart) THEN 1 ELSE im_v2.stranger_message_windows.message_count + 1 END
            WHERE im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart)
               OR im_v2.stranger_message_windows.message_count < \(bind: policy.maximumMessagesPerWindow)
            RETURNING message_count
            """).first(decoding: DirectMessageWindowRow.self)
        guard consumed != nil else { throw V2RoomWriteStoreError.strangerMessageLimitReached }
    }

    /// 陌生人消息策略只需要知道对端是否曾经回复过。
    ///
    /// 把这个单调事实保存在已加锁的单聊配对上，
    /// 可以省去每次发送时的一次 `messages` 存在性扫描，同时不改变回复变得可见的时点：
    /// 该更新与已接受消息原子提交。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - senderID: 发送者标识。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 是否发生了首次回复状态迁移。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    @discardableResult
    func markDirectSenderHasReplied(
        roomID: UUID,
        senderID: UUID,
        sql: any SQLDatabase
    ) async throws -> Bool {
        let updated = try await sql.raw("""
            UPDATE im_v2.direct_room_pairs AS pair
            SET lower_has_replied = CASE
                    WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                    ELSE pair.lower_has_replied
                END,
                higher_has_replied = CASE
                    WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                    ELSE pair.higher_has_replied
                END,
                direct_policy_revision = pair.direct_policy_revision + 1
            WHERE pair.room_id = \(bind: roomID)
              AND pair.direct_policy_revision < \(bind: Int64.max)
              AND (pair.lower_user_id = \(bind: senderID)
                   OR pair.higher_user_id = \(bind: senderID))
              AND ((pair.lower_user_id = \(bind: senderID) AND NOT pair.lower_has_replied)
                   OR (pair.higher_user_id = \(bind: senderID) AND NOT pair.higher_has_replied))
            RETURNING pair.room_id
            """).first(decoding: DirectReplyMarkerMutationRow.self)
        // 加锁预检要求完成首次回复状态转换。若更新缺失，不能让已接受的消息
        // 带着过期的回复标记或策略修订号继续存在。
        guard updated != nil else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return true
    }

    /// 一次拒绝只是属于发送者的私有事实，既不是消息，也不是房间事件。
    ///
    /// 操作表让传输层重试保持幂等，并防止同一个客户端消息 ID 产生重复的活动行。
    ///
    /// - Parameters:
    ///   - fingerprint: 请求指纹。
    ///   - roomID: 目标房间标识。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 拒绝的特有记录。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    func persistDirectMessageDenied(
        fingerprint: V2SendMessageFingerprint,
        roomID: RoomID,
        roomUUID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        sourceEventID: UUID,
        nextTimelineSequence: UInt64,
        createdAt: Date,
        reason: V2DirectMessageDenied.Reason,
        currentCanSend: Bool?,
        sql: any SQLDatabase
    ) async throws -> V2DirectMessageDenied {
        // 保留下方原生 Date 绑定，但对外返回未来重放时会解码出的确切时间。
        // 重新绑定已解码的 Date 可能再次损失一微秒，因此响应规范化不能改动持久化值。
        let persistedCreatedAt = try roomWritePersistedDate(createdAt)
        let createdAtMilliseconds = try v2GatewayMilliseconds(persistedCreatedAt)
        let timelineSequence = try signed(nextTimelineSequence)
        let activityType = directMessageTimelineActivityType(for: reason)
        try await sql.raw("UPDATE im_v2.rooms SET timeline_sequence = \(bind: timelineSequence) WHERE room_id = \(bind: roomUUID)").run()
        // 拒绝记录引用其私有时间线活动。先插入被引用的事实；
        // 两条记录仍在外围消息事务中原子提交。
        try await sql.raw("INSERT INTO im_v2.room_timeline_activities (source_event_id, room_id, timeline_sequence, activity_type, recipient_user_id, created_at) VALUES (\(bind: sourceEventID), \(bind: roomUUID), \(bind: timelineSequence), \(bind: activityType), \(bind: senderID), \(bind: createdAt))").run()
        try await sql.raw("INSERT INTO im_v2.direct_message_denials (sender_user_id, client_message_id, room_id, source_event_id, timeline_sequence, created_at, reason, fingerprint_version, request_fingerprint) VALUES (\(bind: senderID), \(bind: clientMessageID), \(bind: roomUUID), \(bind: sourceEventID), \(bind: timelineSequence), \(bind: createdAt), \(bind: reason.rawValue), \(bind: Int16(fingerprint.version)), \(bind: fingerprint.digest))").run()
        let activityPayload = try JSONSerialization.data(withJSONObject: ["event_type": activityType, "room_id": roomUUID.uuidString, "timeline_sequence": timelineSequence, "server_created_at_ms": createdAtMilliseconds])
        try await enqueuePrivateStateEvent(sourceRoomID: roomUUID, userID: senderID, sourceEventID: sourceEventID, projectionKind: "timeline_activity", payload: activityPayload, createdAt: createdAt, sql: sql)
        try await appendDirectSendingCapabilityIfChanged(
            roomID: roomUUID,
            recipientID: senderID,
            sourceEventID: sourceEventID,
            canSend: false,
            currentCanSend: currentCanSend,
            createdAt: createdAt,
            createdAtMilliseconds: createdAtMilliseconds,
            timelineSequence: timelineSequence,
            sql: sql
        )
        return .init(roomID: roomID, sourceEventID: .init(uuid: sourceEventID), timelineSequence: nextTimelineSequence, createdAt: persistedCreatedAt, reason: reason)
    }

    /// 公开的拒绝原因刻意隐藏了究竟是拉黑、陌生人偏好还是失活的特殊账号导致了拒绝。
    ///
    /// 私有时间线仍使用 SQLite 消费、PostgreSQL 约束的稳定投影词汇表。
    ///
    /// - Parameter reason: 私有拒绝原因。
    /// - Returns: 稳定的时间线活动类型字符串。
    private func directMessageTimelineActivityType(for reason: V2DirectMessageDenied.Reason) -> String {
        switch reason {
        case .generic:
            "direct_message_restricted"
        case .systemAccountReadOnly:
            "system_account_read_only"
        }
    }

    private func appendDirectSendingCapabilityIfChanged(
        roomID: UUID,
        recipientID: UUID,
        sourceEventID: UUID,
        canSend: Bool,
        currentCanSend: Bool?,
        createdAt: Date,
        createdAtMilliseconds: Int64,
        timelineSequence: Int64,
        sql: any SQLDatabase
    ) async throws {
        guard currentCanSend != canSend else { return }
        guard let mutation = try await sql.raw("""
            WITH event_insert AS (
                INSERT INTO im_v2.user_state_event_outbox
                    (user_id, source_event_id, projection_kind, payload, created_at, next_attempt_at, source_room_id)
                VALUES (\(bind: recipientID), \(bind: sourceEventID), 'direct_sending_capability',
                        jsonb_build_object('room_id', \(bind: roomID.uuidString),
                                           'can_send', \(bind: canSend),
                                           'state_version', \(bind: timelineSequence),
                                           'updated_at_ms', \(bind: createdAtMilliseconds)),
                        \(bind: createdAt), \(bind: createdAt), \(bind: roomID))
                RETURNING user_id
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_can_send = CASE
                        WHEN pair.lower_user_id = \(bind: recipientID) THEN \(bind: canSend)
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = \(bind: recipientID) THEN \(bind: canSend)
                        ELSE pair.higher_can_send
                    END
                WHERE pair.room_id = \(bind: roomID)
                  AND EXISTS (SELECT 1 FROM event_insert)
                RETURNING pair.room_id
            )
            SELECT (SELECT count(*) FROM event_insert) AS inserted_count,
                   (SELECT count(*) FROM pair_update) AS pair_count
            """).first(decoding: DirectCapabilityMutationRow.self),
              mutation.insertedCount == 1,
              mutation.pairCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// 客户的首条已接受消息会在与消息相同的事务中创建服务会话。
    ///
    /// 重试消息会复用该房间行；
    /// 而已关闭的会话刻意不会被一次过期的重复操作重新打开。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - senderID: 客户用户标识。
    ///   - supportAccountID: 客服账号标识。
    ///   - createdAt: 会话创建时间。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 写入失败时抛出。
    func openSupportSessionIfNeeded(roomID: UUID, senderID: UUID, supportAccountID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
        try await sql.raw("INSERT INTO im_v2.support_conversation_sessions (room_id, support_account_user_id, customer_user_id, state, opened_at, last_activity_at, closed_at) VALUES (\(bind: roomID), \(bind: supportAccountID), \(bind: senderID), 'open', \(bind: createdAt), \(bind: createdAt), NULL) ON CONFLICT (room_id) DO UPDATE SET last_activity_at = EXCLUDED.last_activity_at, state = CASE WHEN im_v2.support_conversation_sessions.state = 'resolved' THEN 'open' ELSE im_v2.support_conversation_sessions.state END, closed_at = CASE WHEN im_v2.support_conversation_sessions.state = 'resolved' THEN NULL ELSE im_v2.support_conversation_sessions.closed_at END").run()
    }

    private func enqueuePrivateStateEvent(sourceRoomID: UUID, userID: UUID, sourceEventID: UUID, projectionKind: String, payload: Data, createdAt: Date, sql: any SQLDatabase) async throws {
        guard let kind = V2UserStateEventKind(rawValue: projectionKind) else {
            throw V2UserStateEventError.invalidEvent
        }
        let event = try V2UserStateEvent(sourceEventID: .init(uuid: sourceEventID),
            userID: .init(uuid: userID), kind: kind, payload: payload, createdAt: createdAt)
        try await PostgresV2UserStateEventOutbox(database: database).enqueue(event, sourceRoomID: .init(uuid: sourceRoomID), in: sql)
    }

    func withTimelineSequence(_ writeSet: V2MessageAcceptanceTransaction, timelineSequence: UInt64) throws -> V2MessageAcceptanceTransaction {
        let revisedMessage = try withTimelineSequence(writeSet.acceptedMessage, timelineSequence: timelineSequence)
        return .init(acceptedMessage: revisedMessage, eventID: writeSet.eventID, nextRoomState: writeSet.nextRoomState, nextShardState: writeSet.nextShardState)
    }

    private func withTimelineSequence(
        _ message: V2AcceptedMessageDraft,
        timelineSequence: UInt64
    ) throws -> V2AcceptedMessageDraft {
        .init(
            messageID: message.messageID,
            roomID: message.roomID,
            roomSequence: message.roomSequence,
            timelineSequence: timelineSequence,
            senderUserID: message.senderUserID,
            clientMessageID: message.clientMessageID,
            text: message.text,
            media: message.media,
            mentions: message.mentions,
            entities: message.entities,
            replyTo: message.replyTo,
            groupCapacityClass: message.groupCapacityClass,
            createdAt: message.createdAt
        )
    }


    /// 各准入路径已持有房间锁。独立于用户级投递工作检查固定的私聊关系。
    func assertDirectMemberships(roomIDs: [UUID], sql: any SQLDatabase) async throws {
        let roomsJSON = try roomWriteJSON(Array(Set(roomIDs)).map { $0.uuidString })
        guard try await sql.raw("""
            SELECT 1 FROM im_v2.rooms AS room
            LEFT JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
            WHERE room.room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: roomsJSON)::jsonb))
              AND room.room_kind = 'direct'
              AND (pair.room_id IS NULL OR NOT COALESCE((
                  SELECT count(*) = 2 AND bool_and(member.user_id IN (pair.lower_user_id, pair.higher_user_id))
                  FROM (
                      SELECT user_id FROM im_v2.room_memberships
                      WHERE room_id = room.room_id AND joined_revision <= room.membership_revision
                        AND (left_revision IS NULL OR left_revision > room.membership_revision)
                      LIMIT 3
                  ) AS member
              ), FALSE))
            LIMIT 1
            """).first() == nil else { throw V2RoomWriteStoreError.corruptPersistenceState }
    }


    /// 为一个房间、成员、配对与用户策略行均已由权威预检锁定的批次，
    /// 应用仅限单聊的可变策略效果。
    ///
    /// 每次变更都是集合式的，调用方会把部分影响行数视为不受支持的形态，
    /// 于是外层事务回滚，改由既有的逐命令路径在不丢配额的前提下决定各结果。
    ///
    /// - Parameters:
    ///   - appends: 已准备的单聊房间日志追加。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 影响行数不符或写入失败时抛出。
    private func persistPlainDirectRoomLogBatchPolicyMutations(
        _ appends: [PreparedDirectRoomLogAppend],
        sql: any SQLDatabase
    ) async throws {
        let quotaInputs = try appends.compactMap { append -> DirectRoomLogQuotaMutationInput? in
            guard append.directContext.requiresStrangerQuota else { return nil }
            return .init(
                senderID: append.senderID,
                recipientID: append.directContext.recipientID,
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(append.now),
                windowStartPostgresMicroseconds: try roomWritePostgresMicroseconds(
                    roomWriteStrangerWindowStart(now: append.now, interval: strangerMessagePolicy.window))
            )
        }
        guard Set(quotaInputs.map { "\($0.senderID.uuidString)|\($0.recipientID.uuidString)" }).count == quotaInputs.count else {
            // 私聊关系按设计唯一，且此批次每个房间仅有一条命令。
            // 保留显式断言：即使将来该不变量改变，下方 upsert 也不能
            // 为同一逻辑关系消耗两份配额。
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        if !quotaInputs.isEmpty {
            let inputJSON = try roomWriteJSON(quotaInputs)
            let expectedCount = Int64(quotaInputs.count)
            guard let result = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT input.sender_id, input.recipient_id,
                           input.now_postgres_microseconds,
                           ((TIMESTAMP '2000-01-01 00:00:00'
                             + (input.window_start_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (input.window_start_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC') AS window_start
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                        sender_id uuid,
                        recipient_id uuid,
                        now_postgres_microseconds bigint,
                        window_start_postgres_microseconds bigint
                    )
                ), consumed AS (
                    INSERT INTO im_v2.stranger_message_windows AS existing_window
                        (sender_user_id, recipient_user_id, window_started_at, message_count)
                    SELECT input.sender_id, input.recipient_id,
                           ((TIMESTAMP '2000-01-01 00:00:00'
                             + (input.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (input.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC'), 1
                    FROM input
                    ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
                    SET window_started_at = CASE
                            WHEN existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                            THEN EXCLUDED.window_started_at
                            ELSE existing_window.window_started_at
                        END,
                        message_count = CASE
                            WHEN existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                            THEN 1
                            ELSE existing_window.message_count + 1
                        END
                    WHERE existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                       OR existing_window.message_count < \(bind: strangerMessagePolicy.maximumMessagesPerWindow)
                    RETURNING sender_user_id, recipient_user_id
                )
                SELECT \(bind: expectedCount)::bigint AS expected_count,
                       (SELECT count(*) FROM consumed)::bigint AS applied_count
                """).first(decoding: DirectRoomLogBatchMutationCounts.self),
                  result.expectedCount == expectedCount,
                  result.appliedCount == expectedCount
            else {
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
        }

        let markerInputs = appends.compactMap { append -> DirectRoomLogReplyMarkerMutationInput? in
            guard append.advancesReplyMarker else { return nil }
            return .init(roomID: append.roomID, senderID: append.senderID)
        }
        guard Set(markerInputs.map(\.roomID)).count == markerInputs.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        if !markerInputs.isEmpty {
            let inputJSON = try roomWriteJSON(markerInputs)
            let expectedCount = Int64(markerInputs.count)
            guard let result = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT input.room_id, input.sender_id
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                        room_id uuid,
                        sender_id uuid
                    )
                ), advanced AS (
                    UPDATE im_v2.direct_room_pairs AS pair
                    SET lower_has_replied = CASE
                            WHEN pair.lower_user_id = input.sender_id THEN TRUE
                            ELSE pair.lower_has_replied
                        END,
                        higher_has_replied = CASE
                            WHEN pair.higher_user_id = input.sender_id THEN TRUE
                            ELSE pair.higher_has_replied
                        END,
                        direct_policy_revision = pair.direct_policy_revision + 1
                    FROM input
                    WHERE pair.room_id = input.room_id
                      AND pair.direct_policy_revision < \(bind: Int64.max)
                      AND (pair.lower_user_id = input.sender_id
                           OR pair.higher_user_id = input.sender_id)
                      AND ((pair.lower_user_id = input.sender_id AND NOT pair.lower_has_replied)
                           OR (pair.higher_user_id = input.sender_id AND NOT pair.higher_has_replied))
                    RETURNING pair.room_id
                )
                SELECT \(bind: expectedCount)::bigint AS expected_count,
                       (SELECT count(*) FROM advanced)::bigint AS applied_count
                """).first(decoding: DirectRoomLogBatchMutationCounts.self),
                  result.expectedCount == expectedCount,
                  result.appliedCount == expectedCount
            else {
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
        }
    }


    /// 用单条 PostgreSQL 语句持久化普通房间日志消息。
    ///
    /// 输入已按房间与到达序号排序。因此一个房间可能出现多次：
    /// 消息行会保留每个输入，
    /// 而房间/准入状态只根据该房间的最终输入更新一次。
    ///
    /// - Parameters:
    ///   - inputs: 本批普通房间日志消息输入。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 影响行数不符或写入失败时抛出。
    func persistPlainRoomLogMessages(
        inputs: [PlainRoomLogMessageInput],
        sql: any SQLDatabase
    ) async throws {
        guard !inputs.isEmpty,
              Set(inputs.map(\.messageID)).count == inputs.count,
              Set(inputs.map(\.eventID)).count == inputs.count,
              inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await assertDirectMemberships(roomIDs: inputs.map(\.roomID), sql: sql)
        try await PlainDirectRoomLogBatchWritePath.persist(inputs: inputs, sql: sql)
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
    private func persistFastPlainDirectRoomLogMessages(
        _ appends: [FastPlainDirectRoomLogAppend],
        sql: any SQLDatabase
    ) async throws -> [FastPlainDirectRoomLogAllocationRow] {
        guard !appends.isEmpty,
              Set(appends.map(\.roomID)).count == appends.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        let inputs = try appends.map { append in
            try FastPlainDirectRoomLogAppendInput(append: append, strangerWindow: strangerMessagePolicy.window)
        }
        return try await FastPlainDirectRoomLogWritePath.persist(
            inputs: inputs,
            maximumStrangerMessages: strangerMessagePolicy.maximumMessagesPerWindow,
            sql: sql
        )
    }


    func assertMentionsAuthorized(_ mentions: [V2MentionTarget], roomID: UUID, membershipRevision: Int64, senderID: UUID, sql: any SQLDatabase) async throws {
        guard !mentions.isEmpty else { return }
        guard mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else { throw V2MentionValidationError.invalidTargetSet }
        guard let sender = try await sql.raw("""
            SELECT role
            FROM im_v2.room_memberships
            WHERE room_id = \(bind: roomID) AND user_id = \(bind: senderID)
              AND joined_revision <= \(bind: membershipRevision)
              AND (left_revision IS NULL OR left_revision > \(bind: membershipRevision))
            FOR UPDATE
            """).first(decoding: MentionSenderMembershipRow.self),
              let role = V2RoomMembershipRole(rawValue: sender.role)
        else { throw V2RoomWriteStoreError.actorNotEligible }

        var mentionedUserIDs: [UUID] = []
        for target in mentions {
            guard case .user(let userID) = target else { continue }
            mentionedUserIDs.append(try uuid(userID))
        }
        let rows: [MentionMembershipRow]
        if mentionedUserIDs.isEmpty {
            rows = []
        } else {
            let targetJSON = try mentionTargetJSON(mentionedUserIDs)
            rows = try await sql.raw("""
                WITH targets AS (
                    SELECT value::uuid AS user_id
                    FROM jsonb_array_elements_text(\(bind: targetJSON)::jsonb) AS value
                )
                SELECT membership.user_id,
                       NOT EXISTS (
                         SELECT 1 FROM im_v2.user_blocks AS blocks
                         WHERE (blocks.blocker_user_id = \(bind: senderID) AND blocks.blocked_user_id = membership.user_id)
                            OR (blocks.blocker_user_id = membership.user_id AND blocks.blocked_user_id = \(bind: senderID))
                       ) AS mentionable
                FROM targets
                JOIN im_v2.room_memberships AS membership
                  ON membership.user_id = targets.user_id
                WHERE membership.room_id = \(bind: roomID)
                  AND membership.joined_revision <= \(bind: membershipRevision)
                  AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: membershipRevision))
                FOR UPDATE OF membership
                """).all(decoding: MentionMembershipRow.self)
        }
        let visibility = V2MentionVisibility(
            senderRole: role,
            visibleActiveUsers: Set(try rows.map { try UserID($0.userID.uuidString) }),
            mentionableUsers: Set(try rows.filter(\.mentionable).map { try UserID($0.userID.uuidString) })
        )
        try V2MentionAuthorization.authorize(mentions, visibility: visibility, limits: .init(maximumTargets: V2MessageCommandLimits.maxMentions))
    }

    func assertReplyTarget(_ replyTo: V2MessageReplyReference?, roomID: UUID, actorID: UUID, sql: any SQLDatabase) async throws {
        guard let replyTo else { return }
        guard let targetID = UUID(uuidString: replyTo.messageID.rawValue),
              (try await sql.raw("""
                  SELECT EXISTS (
                      SELECT 1 FROM im_v2.messages AS message
                      JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                      WHERE message.message_id = \(bind: targetID)
                        AND message.room_id = \(bind: roomID)
                        AND message.withdrawn_at IS NULL
                        AND (\(v2ForwardSourceVisibility(actorID: actorID)))
                  ) AS authorized
                  """).first(decoding: AuthorizationRow.self)?.authorized ?? false)
        else { throw V2RoomWriteStoreError.replyTargetNotFound }
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

/// 单聊房间日志投递的受众固定为两人，且不会创建扇出计划或未完成工作预留。
///
/// 其命令预算已由分片额度池持久预扣；
/// 在选用旧版每房间策略时，也由房间额度池预扣。
/// 因此这次归并只推进批量规范消息插入所需的房间序号与分片快照。
///
/// 授权刻意留在此辅助函数之外，
/// 并在归并之前由 `PostgresV2RoomWriteStore.accept` 依据已锁定的房间、成员、
/// 单聊配对、策略版本与陌生人配额状态持续校验。
///
/// - Parameters:
///   - command: 发送消息命令。
///   - roomState: 房间命令状态。
///   - admission: 分片准入状态。
///   - now: 服务端统一授时时刻。
/// - Returns: 归并结果。
/// - Throws: 状态非法或序号溢出时抛出。
private func directRoomLogPrechargedCommandBatchReduction(
    command: V2SendMessageCommand,
    nextRoomSequence: UInt64,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    now: Date
) throws -> DirectRoomLogPrechargedCommandReductionResult {
    guard let lease = shardState.lease else { return .unavailable(.missingShardLease) }
    guard lease.isValid(at: now) else { return .unavailable(.expiredShardLease) }
    guard lease.commandWindow.canReserve(1) else {
        return .rateLimited(retryAfterSeconds: profile.retryAfterSeconds)
    }

    let nextLease = try ShardAdmissionLease(
        id: lease.id,
        generation: lease.generation,
        validUntil: lease.validUntil,
        commandWindow: lease.commandWindow.reserving(1))
    let nextShard = try ShardAdmissionState(
        lease: nextLease)
    let accepted = V2AcceptedMessageDraft(
        messageID: identifiers.messageID,
        roomID: command.roomID,
        roomSequence: nextRoomSequence,
        senderUserID: command.senderUserID,
        clientMessageID: command.clientMessageID,
        text: command.text,
        media: command.media,
        mentions: command.mentions,
        entities: command.entities,
        replyTo: command.replyTo,
        createdAt: now
    )
    return .accepted(.init(
        acceptedMessage: accepted,
        eventID: identifiers.eventID,
        nextShardState: nextShard
    ))
}

/// 已预扣费的热路径由房间信用池持有准入计数，事务只需保留消息与分片结果。
private enum DirectRoomLogPrechargedCommandReductionResult {
    case accepted(DirectRoomLogPrechargedCommandWriteSet)
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2CommandAdmissionUnavailableReason)
}

private struct DirectRoomLogPrechargedCommandWriteSet {
    let acceptedMessage: V2AcceptedMessageDraft
    let eventID: EventID
    let nextShardState: ShardAdmissionState
}

private func requireShardLeaseID(_ state: ShardAdmissionState) throws -> ShardAdmissionLeaseID {
    guard let lease = state.lease else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return lease.id
}

private func requireShardLeaseGeneration(_ state: ShardAdmissionState) throws -> UInt64 {
    guard let lease = state.lease else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return lease.generation
}


private func mentionTargetJSON(_ userIDs: [UUID]) throws -> String {
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

private enum LateShardAdmissionRejection: Error, Sendable {
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2CommandAdmissionUnavailableReason)
}

private struct ShardAdmissionMutationRow: Decodable {
    let applied: Int
}

struct ShardAdmissionReservation: Sendable {
    let leaseID: UUID
    let generation: Int64
    let commandDelta: Int
}

private struct CurrentShardLeaseRow: Decodable {
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



private struct PreparedPlainHybridGroupAppend {
    let originalIndex: Int
    let cacheKey: V2DirectSendPolicyCache.Key
    let accepted: V2AcceptedMessage
    let input: PlainHybridGroupAppendInput

    init(
        originalIndex: Int,
        request: V2RoomWriteRequest,
        room: RoomRow,
        writeSet: V2MessageAcceptanceTransaction,
        accepted: V2AcceptedMessage,
        reservation: ShardAdmissionReservation
    ) throws {
        let roomID = try uuid(request.command.roomID)
        let senderID = try uuid(request.command.senderUserID)
        let roomAdmission = writeSet.nextRoomState.admission
        self.originalIndex = originalIndex
        cacheKey = .init(roomID: roomID, senderID: senderID)
        self.accepted = accepted
        input = .init(
            ordinal: originalIndex,
            roomID: roomID,
            messageID: try uuid(writeSet.acceptedMessage.messageID),
            eventID: try uuid(writeSet.eventID),
            senderID: senderID,
            clientMessageID: try uuid(request.command.clientMessageID),
            roomSequence: try signed(writeSet.acceptedMessage.roomSequence),
            timelineSequence: try signed(writeSet.acceptedMessage.timelineSequence),
            membershipRevision: room.membershipRevision,
            commandWindowUsed: roomAdmission.commandWindow.used,

            shardLeaseID: reservation.leaseID,
            shardLeaseGeneration: reservation.generation,
            text: request.command.text,
            entities: request.command.entities,
            fingerprint: request.command.fingerprint,
            createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(request.now)
        )
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

private struct OrderedRoomWriteCommit {
    let originalIndex: Int
    let cacheKey: V2DirectSendPolicyCache.Key
    let commit: RoomWriteCommit
}

private enum DirectRoomLogBatchPreparation {
    case append(PreparedDirectRoomLogAppend)
    case outcome(RoomWriteCommit)
}

/// 普通单聊房间日志快速路径使用的最小已接受事件材料。
///
/// 对预扣费房间，持久房间额度由独立的信用池维护；其余请求仍写入房间准入行。
private struct PlainDirectRoomLogWriteSet {
    let acceptedMessage: V2AcceptedMessageDraft
    let eventID: EventID
    let nextShardState: ShardAdmissionState
    let roomCommandWindowUsed: Int
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
private struct FastPlainDirectRoomLogCandidate {
    let originalIndex: Int
    let request: V2RoomWriteRequest
    let roomID: UUID
    let senderID: UUID
    let cacheKey: V2DirectSendPolicyCache.Key
    let snapshot: V2DirectRoomLogFastAppendCache.Entry
    let requiresStrangerQuota: Bool
    let usesRoomAdmissionCredits: Bool
}

private struct FastPlainDirectRoomLogAppend {
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

    fileprivate init(append: FastPlainDirectRoomLogAppend, strangerWindow: TimeInterval) throws {
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



private struct DirectRoomLogQuotaMutationInput: Encodable {
    let senderID: UUID
    let recipientID: UUID
    let nowPostgresMicroseconds: Int64
    let windowStartPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case senderID = "sender_id"
        case recipientID = "recipient_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
        case windowStartPostgresMicroseconds = "window_start_postgres_microseconds"
    }
}

private struct DirectRoomLogReplyMarkerMutationInput: Encodable {
    let roomID: UUID
    let senderID: UUID

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case senderID = "sender_id"
    }
}

private struct DirectRoomLogBatchMutationCounts: Decodable {
    let expectedCount: Int64
    let appliedCount: Int64

    enum CodingKeys: String, CodingKey {
        case expectedCount = "expected_count"
        case appliedCount = "applied_count"
    }
}

private struct AuthorizationRow: Decodable { let authorized: Bool }
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
private struct DirectCapabilityMutationRow: Decodable {
    let insertedCount: Int64
    let pairCount: Int64
    enum CodingKeys: String, CodingKey {
        case insertedCount = "inserted_count"
        case pairCount = "pair_count"
    }
}
private struct RoomWriteBatchRouteRow: Decodable {
    let roomID: UUID
    let roomKind: String
    let capacityClass: String

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomKind = "room_kind"
        case capacityClass = "capacity_class"
    }
}
private struct DirectMessageWindowRow: Decodable { let messageCount: Int; enum CodingKeys: String, CodingKey { case messageCount = "message_count" } }
private struct DirectReplyMarkerMutationRow: Decodable { let roomID: UUID; enum CodingKeys: String, CodingKey { case roomID = "room_id" } }
private struct MentionSenderMembershipRow: Decodable { let role: String }
private struct MentionMembershipRow: Decodable { let userID: UUID; let mentionable: Bool; enum CodingKeys: String, CodingKey { case userID = "user_id", mentionable } }

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

private struct SelectedRoomOwnerRow: Decodable {
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
private func roomWritePersistedAcceptanceOutcome(_ outcome: V2SendMessageOutcome) throws -> V2SendMessageOutcome {
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

private func roomWriteStrangerWindowStart(now: Date, interval: TimeInterval) throws -> Date {
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

private struct DurableAuthorizationRouteRow: Decodable {
    let roomID: UUID; let senderID: UUID; let recipientID: UUID?
    let kind: String; let shardID: String; let epoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", senderID = "sender_id", recipientID = "recipient_id"
        case kind = "room_kind", shardID = "room_shard_id", epoch = "owner_epoch"
    }
}
