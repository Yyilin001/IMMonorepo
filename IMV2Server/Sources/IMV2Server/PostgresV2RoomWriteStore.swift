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
    private var authorizationGrants: [String: V2DirectAuthorizationGrant]?
    private var authorizationRecordedAt: Date?
    private var authorizationResolutionDatabase: (any Database)?
    private var controlScopeRoomKinds: [UUID: String]?
    // Immutable for the lifetime of one scoped value copy. Shared caches and
    // credit actors keep their identities; no mutable ambient route is used.
    private var ownerRoutes: [UUID: V2RoomShardRoute]?
    private var activationScope: V2RoomActivationWriteScope?
    private var forwardOwnerSourceRoomID: UUID?
    private var controlPolicyScope: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]?
    private let strangerMessagePolicy: V2StrangerMessagePolicy
    private let contentReviewMode: V2ContentReviewMode
    private let directSendPolicyCache: V2DirectSendPolicyCache
    private let directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache
    private let roomWriteBatchRouteCache: V2RoomWriteBatchRouteCache
    private let hybridGroupShardCreditSnapshotCache:
        V2HybridGroupShardCreditSnapshotCache
    private let shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool?
    private let roomAdmissionCommandCreditPool: V2RoomAdmissionCommandCreditPool?
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

    /// Bind exact, already admitted activation authority. Every SQL path still
    /// checks it inside its transaction; this value copy grants no authority by
    /// itself and retains the shared cache and credit-pool identities.
    public func usingActivationScope(_ scope: V2RoomActivationWriteScope) -> Self {
        var copy = self
        copy.activationScope = scope
        return copy
    }

    /// A reservation may change facts outside this executor's ordinary turn.
    /// Clear hints before releasing its barrier; SQL remains authoritative.
    func invalidateActorHints(token: V2RoomActivationToken) async {
        guard let room = token.roomID.uuidValue else { return }
        await directSendPolicyCache.invalidate(roomID: room)
        await directRoomLogFastAppendCache.invalidate(roomID: room)
        await hybridGroupShardCreditSnapshotCache.invalidate([room])
    }

    /// Hosting calls this only after the executor's SQL and batches settle.
    /// Unspent credit belongs to this exact epoch and cannot reach a successor.
    func closeActorState(token: V2RoomActivationToken) async {
        await invalidateActorHints(token: token)
        await roomAdmissionCommandCreditPool?.retire(activation: token)
    }

    /// Bind the authoritative control pool. It must be independent of the owner
    /// pool even when both connect to the same physical database. Runtime must
    /// also pass an independent resolution pool: policy writers must not wait
    /// for a reservation connection that is waiting for their exclusive lock.
    /// A shared fallback supports explicitly composed local stores only.
    public func usingControlDatabase(_ database: any Database, authorizationResolutionDatabase: (any Database)? = nil) -> Self {
        var copy = self
        copy.controlDatabase = database
        copy.authorizationResolutionDatabase = authorizationResolutionDatabase ?? database
        return copy
    }

    /// Bind grants already committed by the control store. Every owner write
    /// path below checks them under its operation locks and records terminal
    /// proof in the SAME transaction as the message or durable business denial.
    /// Automatic ordinary/batch/forward entry points reserve and bind these grants.
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
            useRoomDeadline: activationScope != nil) { transaction in
            // The room-deadline transaction sets the same LOCAL limits before
            // this body starts. The activation fence below still reapplies
            // them before locking; this middle call added no protection.
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

    /// Ordinary scalar acceptance and conditional group batches use this
    /// transaction-bound fence; all other writers retain the general API.
    private func withRoomWriteTransactionWithFenceContext<Result: Sendable>(
        _ operation: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext?) async throws -> Result
    ) async throws -> Result {
        try await v2WithPostgresTransactionRetryWithRoomContext(database: database,
            classifyCommitFailure: activationScope != nil,
            useRoomDeadline: activationScope != nil) { transaction, context in
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

    private func validateAuthorizationCommand(_ command: V2SendMessageCommand) throws {
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
        // Reservation has committed before entering any owner transaction.
        let result = try await operation(scoped)
        // Finalize caches and consumed admission credits before a fallible ACK.
        // A transport failure here retains the obligation; retries/recovery read
        // the immutable owner proof and never return consumed credits.
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
            // This operation may already have committed. Preserve the durable
            // obligation and use the retryable protocol mapping, never classify
            // an ACK/database failure as a new command identity conflict.
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

    private func senderIsActive(_ local: Bool?, roomID: UUID, senderID: UUID) throws -> Bool {
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

    /// Accept one already reserved source/target pair together with its ledger.
    /// The callbacks cannot acquire another room or another DB connection. They
    /// run after message-operation and canonical room/token locks, in the exact
    /// transaction that commits acceptance. Control authorization is prepared
    /// before this transaction and acknowledged only after its commit.
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
            // All pair ledger and message effects rolled back together.
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
    private func requireSelectedOwners(_ roomIDs: [UUID], sql: any SQLDatabase) async throws {
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
        // Without a selected route, missing rooms keep the ordinary domain error
        // from the acceptance path.
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
        if let fastCommit = try await acceptFastPlainDirectRoomLogIfEligible(
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
            // Receive has committed a durable workflow fact. A later failure
            // cannot prove rollback of this entire turn; retain the operation
            // identity and recover through the inbox on the next activation.
            if activationScope != nil { throw V2RoomTransactionOutcomeUnknown() }
            throw error
        }
    }

    /// Actor entry binds every phase, including immutable receipt replay, to
    /// the exact target incarnation. It does not grant source-room authority.
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
            // This short owner-only preflight ends before control reservation.
            // The acceptance transaction below rechecks the inbox, media mapping,
            // exact command fingerprint and owner before any message write.
            let preflight: (V2SendMessageCommand?, V2ForwardImportOutcome?) = try await withRoomWriteTransaction { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
                let row = try await v2LockForwardInbox(exportID: export.intent.exportID, sql: sql)
                try await activationScope?.require([export.intent.targetRoomID], sql: sql)
                guard row.digest == export.digest else { throw V2ForwardInboxError.idempotencyConflict }
                if row.state == "completed" || row.state == "rejected" { return (nil, try row.outcome) }
                guard row.payload == export.payload else { throw V2ForwardInboxError.idempotencyConflict }
                guard let authority = try await v2ForwardInboxAuthorization(row, sql: sql) else {
                    guard row.state == "pending" else { throw V2ForwardInboxError.corruptPersistenceState }
                    return (nil, .pending(.media))
                }
                // Limits do not contribute to command identity. Apply current
                // limits in the acceptance transaction, preserving its durable
                // INVALID_ARGUMENT rejection and accepted-receipt recovery.
                let identityLimits = try V2MessageCommandLimits(maxUTF8Bytes: max(export.intent.text.utf8.count, 1))
                return (try authority.command(limits: identityLimits), nil)
            }
            if let outcome = preflight.1 {
                switch outcome {
                case .accepted, .rejected:
                    // ACK failure after inbox completion is recovered without
                    // decoding payload/media again or reserving a new generation.
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
                guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
                let row = try await v2LockForwardInbox(exportID: export.intent.exportID, sql: sql)
                guard row.digest == export.digest else { throw V2ForwardInboxError.idempotencyConflict }
                if row.state == "completed" || row.state == "rejected" {
                    try await activationScope?.require([export.intent.targetRoomID], sql: sql)
                    return (try row.outcome, nil, nil)
                }
                guard row.payload == export.payload else { throw V2ForwardInboxError.idempotencyConflict }
                guard let authority = try await v2ForwardInboxAuthorization(row, sql: sql) else {
                    guard row.state == "pending" else { throw V2ForwardInboxError.corruptPersistenceState }
                    try await activationScope?.require([export.intent.targetRoomID], sql: sql)
                    return (.pending(.media), nil, nil)
                }
                // Preserve inbox -> message operation -> room lock ordering.
                // Fence before command validation can persist a rejection;
                // receipt and pending reads above are separately fenced before return.
                try await acquireMessageOperationLock(roomID: export.intent.targetRoomID,
                    senderID: export.intent.actorUserID, clientMessageID: export.intent.targetClientMessageID, sql: sql)
                try await v2AssertForwardInboxOwner(authority, sql: sql)
                try await activationScope?.require([export.intent.targetRoomID], sql: sql)
                guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardInboxError.corruptPersistenceState }
                do {
                    // Recovery of an already committed receipt must not be
                    // invalidated by a later deployment's smaller text limit.
                    let replayLimits = row.state == "accepted"
                        ? try V2MessageCommandLimits(maxUTF8Bytes: max(export.intent.text.utf8.count, 1)) : limits
                    let command = try authority.command(limits: replayLimits)
                    try validateAuthorizationCommand(command)
                    let commit = try await acceptInTransaction(
                        command: command, capacityProfile: capacityProfile, identifiers: identifiers, now: now,
                        roomID: export.intent.targetRoomID, senderID: export.intent.actorUserID,
                        cachedDirectPolicy: nil, importedForward: authority, transaction: transaction
                    )
                    switch commit.outcome {
                    case .accepted, .idempotent:
                        guard let receipt = commit.outcome.acceptanceReceipt else { throw V2ForwardInboxError.corruptPersistenceState }
                        try await v2RecordForwardInboxAcceptance(row, receipt: receipt, now: now, sql: sql)
                        return (.pending(.finalization), command, commit)
                    case .denied:
                        return (try await v2RejectForwardInbox(row, code: "DIRECT_MESSAGE_RESTRICTED", now: now, sql: sql), nil, nil)
                    case .idempotencyConflict:
                        return (try await v2RejectForwardInbox(row, code: "IDEMPOTENCY_CONFLICT", now: now, sql: sql), nil, nil)
                    case .rateLimited, .unavailable:
                        return (.pending(.admission), nil, nil)
                    }
                } catch V2RoomWriteStoreError.actorNotEligible {
                    return (try await v2RejectForwardInbox(row, code: "FORBIDDEN", now: now, sql: sql), nil, nil)
                } catch V2RoomWriteStoreError.actorMuted {
                    return (try await v2RejectForwardInbox(row, code: "ACTOR_MUTED", now: now, sql: sql), nil, nil)
                } catch V2RoomWriteStoreError.roomFrozen {
                    return (try await v2RejectForwardInbox(row, code: "ROOM_FROZEN", now: now, sql: sql), nil, nil)
                } catch V2SendMessageValidationError.invalidTextLength {
                    return (try await v2RejectForwardInbox(row, code: "INVALID_ARGUMENT", now: now, sql: sql), nil, nil)
                }
            }
        } catch is LateShardAdmissionRejection {
            // The message, completion, admission counters, and inbox update
            // all rolled back. The earlier receive remains safely pending.
            return .pending(.admission)
        }
        guard let command = prepared.command, let commit = prepared.commit else { return prepared.outcome }
        _ = try await finalizeCommittedAcceptance(
            command: command,
            cacheKey: .init(roomID: export.intent.targetRoomID, senderID: export.intent.actorUserID), commit: commit
        )
        // A crash or completion-transaction failure before this transition leaves the
        // accepted receipt durable. Retry recovers its normal post-commit work
        // from message_send_completions before exposing target success.
        return try await withRoomWriteTransaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
            let row = try await v2LockForwardInbox(exportID: export.intent.exportID, sql: sql)
            try await activationScope?.require([export.intent.targetRoomID], sql: sql)
            if row.state == "completed" { return try row.outcome }
            try await v2AssertForwardInboxOwner(.init(export: try row.export, mediaIDs: []), sql: sql)
            guard row.state == "accepted", let receipt = commit.outcome.acceptanceReceipt,
                  row.messageID == receipt.messageID.uuidValue,
                  row.roomSequence == Int64(exactly: receipt.roomSequence)
            else { throw V2ForwardInboxError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.message_forward_inbox SET state = 'completed', completed_at = \(bind: now)
                WHERE export_id = \(bind: row.exportID) AND state = 'accepted'
                """).run()
            return .accepted(messageID: receipt.messageID, roomSequence: receipt.roomSequence)
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

        // Avoid splitting a mostly-cold arrival batch into two transactions.
        // The standard path warms its successful entries, so a later batch can
        // graduate to the one-statement accelerated path naturally.
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
        // Cold direct sends use the complete scalar path so every command
        // retains its per-room admission fence.
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

        // Charge command capacity before opening the message transaction.
        // The actor durably reserves a bounded batch from PostgreSQL and then
        // issues one token per message. The transaction below still rechecks
        // the room assignment, lease generation and complete authorization
        // graph under lock, so this snapshot is only a capacity hint.
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
                // PostgreSQL can evaluate the complete ordinary-group
                // contract and append the canonical rows in one conditional
                // statement.  This is not a cache-authorized write: every
                // membership, mute, account, role permission, room profile,
                // lease and admission predicate is checked from locked
                // durable rows. A stale or exceptional row produces zero
                // writes and the batcher retries the immutable commands via
                // the established complete path.
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
                let contexts = try await loadPlainHybridGroupBatchContexts(orderedRequests, sql: sql)
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

                try await persistPlainHybridGroupMessages(prepared, sql: sql)
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

        // This statement advances a cursor once per room.  Reject a
        // same-room micro-batch *before* acquiring any process-local room
        // credits: speculative acquisition could otherwise replace a
        // reservation entry while another input from that same room still
        // owns an in-flight token.  The established ordered batch preserves
        // that case's FIFO semantics.
        guard Set(knownIDs.map(\.roomID)).count == knownIDs.count else {
            return nil
        }

        // Resolve every cache and shape predicate before reserving any
        // process-local admission credit. A mixed hit/miss batch falls back
        // as a set; acquiring while this loop is still discovering the set
        // leaks the prefix's tokens when a later input misses.
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

        // Resolve each process-local admission layer with one actor entry. The
        // established room-before-shard order is retained, while the common
        // warm batch no longer creates two serial-executor jobs per message.
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
                // Keep idempotency locking separate. PostgreSQL fixes the
                // statement snapshot before a CTE runs, so this prior lock is
                // what lets the conditional statement see a just-committed
                // retry result instead of treating it as a fresh append.
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
                            // The mapped control facts expire with the outer transaction.
                            // Keep only the original owner snapshot in shared caches.
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
    private func fastPlainDirectPolicyIsCacheCandidate(
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
                let contexts = try await loadPlainDirectRoomLogBatchContexts([ordered], sql: sql)
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
        // Shard and optional room credits were precharged before opening this
        // transaction. No nested pool acquisition or second reservation runs
        // while these room locks are held.
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

    private static func isPlainDirectRoomLogBatchShape(
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
        // Activation-bound credits must be prefetched before this transaction.
        // The live warm path does this in fastPlainDirectRoomLogCommitsIfEligible;
        // the standard path supplies usesRoomAdmissionCredits = false.
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

    private func acceptInTransaction(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date,
        roomID: UUID,
        senderID: UUID,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        importedForward: ForwardInboxAuthorization? = nil,
        fenceContext: V2ConfiguredRoomFenceContext? = nil,
        transaction: any Database
    ) async throws -> RoomWriteCommit {
            do {
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let clientMessageID = try uuid(command.clientMessageID)
            try await acquireMessageOperationLock(
                roomID: roomID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                sql: sql
            )
            let forwardSourceRoomID: UUID?
            if importedForward == nil, let expectedSource = forwardOwnerSourceRoomID {
                guard command.forwardedFrom != nil, let ownerRoutes else { throw V2RoomOwnerFenceError.ownerChanged }
                try await v2RequireForwardOwners(ownerRoutes, sql: sql)
                try await activationScope?.require([expectedSource, roomID], sql: sql)
                forwardSourceRoomID = expectedSource
            } else if importedForward == nil, let forwarded = command.forwardedFrom {
                forwardSourceRoomID = try await v2LockForwardRooms(
                    sourceMessageID: uuid(forwarded.messageID), targetRoomID: roomID, sql: sql
                )
            } else {
                forwardSourceRoomID = nil
            }
            if forwardOwnerSourceRoomID == nil || authorizationGrants != nil {
                if let fenceContext, let activationScope,
                   command.forwardedFrom == nil, importedForward == nil,
                   forwardOwnerSourceRoomID == nil, authorizationGrants == nil {
                    try await fenceContext.requireSelectedOwnersAndActivations(
                        roomIDs: [roomID], expectedRoutes: ownerRoutes,
                        expectedKinds: controlScopeRoomKinds, scope: activationScope)
                } else {
                    try await requireSelectedOwners([roomID], sql: sql)
                }
            }
            let loadedContext = try await loadMessageAcceptanceContext(
                roomID: roomID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                now: now,
                cachedDirectPolicy: cachedDirectPolicy,
                sql: sql
            )
            let room = loadedContext.room
            guard controlScopeRoomKinds == nil || controlScopeRoomKinds?[roomID] == room.kind else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // Every accepted public message uses the room log. Historical
            // deployment selectors must never restore per-user fanout writes.
            let usesDirectRoomLog = room.kind == "direct"

            // An accepted inbox is still live work until its terminal marker.
            // Fence it before message replay can resume post-commit effects.
            if let importedForward { try await v2AssertForwardInboxOwner(importedForward, sql: sql) }

            // A completed command must replay its canonical result even if a
            // later membership change removes the sender. Otherwise a lost
            // acceptance response becomes an observable false rejection and
            // clients cannot safely retain their immutable operation ID.
            switch try loadedContext.existingOperation() {
            case .accepted(let receipt, let fingerprint):
                if fingerprint == command.fingerprint {
                    guard v2PostgresTimestampCanEncode(receipt.createdAt) else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                }
                return .init(
                    outcome: fingerprint == command.fingerprint ? .idempotent(receipt) : .idempotencyConflict
                )
            case .denied(let priorDenial, let fingerprint):
                if fingerprint == command.fingerprint {
                    guard v2PostgresTimestampCanEncode(priorDenial.createdAt) else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                }
                return .init(
                    outcome: fingerprint == command.fingerprint ? .denied(priorDenial) : .idempotencyConflict
                )
            case nil:
                break
            }
            guard room.capacityProfileID == capacityProfile.id else {
                throw V2RoomWriteStoreError.capacityProfileMismatch
            }
            guard room.frozenAt == nil else {
                throw V2RoomWriteStoreError.roomFrozen
            }
            let admissionSnapshot = try loadedContext.admissionSnapshot()
            let admission = admissionSnapshot.room
            let shard = admissionSnapshot.shard
            guard admission.shardLeaseID == shard.leaseID,
                  admission.shardLeaseGeneration == shard.generation
            else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await v2AuthorizeContentWrite(
                roomID: roomID, isGroup: room.kind == "group", frozenAt: room.frozenAt,
                actorIsActive: try senderIsActive(admissionSnapshot.senderIsActive, roomID: roomID, senderID: senderID),
                actorRole: admissionSnapshot.actorRole,
                isMuted: admissionSnapshot.muted != false, sql: sql
            )
            let directContext: DirectMessageAcceptanceContext?
            if room.kind == "direct" {
                let context = try directMessageContext(from: loadedContext.directPolicySnapshot(), roomID: roomID, senderID: senderID)
                directContext = context
                if let restriction = context.restriction {
                    let denied = try await persistDirectMessageDenied(
                        fingerprint: command.fingerprint,
                        roomID: command.roomID,
                        roomUUID: roomID,
                        senderID: senderID,
                        clientMessageID: clientMessageID,
                        sourceEventID: try uuid(identifiers.eventID),
                        nextTimelineSequence: try roomWriteNextSequence(room.timelineSequence),
                        createdAt: now,
                        reason: restriction,
                        currentCanSend: context.senderCanSend,
                        sql: sql
                    )
                    return .init(outcome: .denied(denied))
                }
            } else {
                directContext = nil
            }
            try await assertMentionsAuthorized(command.mentions, roomID: roomID, membershipRevision: room.membershipRevision, senderID: senderID, sql: sql)
            let mediaAuthority: MessageMediaAcceptanceAuthority
            if let importedForward {
                let exact = try importedForward.command(limits: .init(maxUTF8Bytes: max(importedForward.export.intent.text.utf8.count, 1)))
                guard command == exact else { throw V2ForwardInboxError.idempotencyConflict }
                // Imported files are separate target-owned objects. An inbox
                // mapping does not grant access to arbitrary source media IDs.
                mediaAuthority = .ownedBy(senderID)
            } else if let forwarded = command.forwardedFrom {
                guard let sourceMessageID = UUID(uuidString: forwarded.messageID.rawValue),
                      let sourceSenderID = UUID(uuidString: forwarded.senderUserID.rawValue),
                      let source = try await sql.raw("""
                          SELECT message.room_id, message.sender_user_id, message.text_body,
                                 message.withdrawn_at, message.content_revision, message.rich_entities::text AS entities_json
                          FROM im_v2.messages AS message
                          INNER JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                          WHERE message.message_id = \(bind: sourceMessageID)
                            AND (\(v2ForwardSourceVisibility(actorID: senderID)))
                          FOR UPDATE OF message
                          """).first(decoding: ForwardSourceRow.self),
                      source.roomID == forwardSourceRoomID,
                      source.contentRevision == forwarded.sourceRevision.signedValue,
                      source.senderUserID == sourceSenderID, source.withdrawnAt == nil,
                      source.text == command.text,
                      try JSONDecoder().decode([V2MessageEntity].self, from: Data(source.entitiesJSON.utf8)) == command.entities
                else { throw V2RoomWriteStoreError.actorNotEligible }
                // A forward may only reuse an attachment from the exact
                // source message; attribution is not a general media grant.
                let sourceReferences = try await sql.raw("""
                    SELECT media_id, ordinal, revoked_at FROM im_v2.message_media_references
                    WHERE message_id = \(bind: sourceMessageID)
                    ORDER BY media_id FOR SHARE
                    """).all(decoding: ForwardMediaRow.self)
                let sourceMedia = sourceReferences.sorted { $0.ordinal < $1.ordinal }.map(\.mediaID)
                guard sourceReferences.allSatisfy({ $0.revokedAt == nil }),
                      sourceMedia == (try command.media.map { try uuid($0.mediaID) })
                else { throw V2RoomWriteStoreError.actorNotEligible }
                mediaAuthority = .forwardedFrom(sourceMessageID)
            } else { mediaAuthority = .ownedBy(senderID) }
            let mediaPresentations = try await assertAvailableMedia(command.media, authority: mediaAuthority, now: now, sql: sql)
            if let importedForward {
                guard mediaPresentations.count == importedForward.export.intent.media.count,
                      zip(mediaPresentations, importedForward.export.intent.media).allSatisfy({ actual, expected in
                          actual.contentType == expected.contentType && actual.byteCount == expected.byteCount
                      })
                else { throw V2MediaStoreError.mediaUnavailable }
            }
            try await assertReplyTarget(command.replyTo, roomID: roomID, actorID: senderID, sql: sql)
            let roomState = try room.commandState(roomID: command.roomID, admission: admission)
            let shardState = try shard.admissionState()
            // The complete path owns a foreground PostgreSQL transaction and
            // may already hold room, membership and policy locks. Never call
            // the process credit actor here: a refill borrows from the same
            // bounded pool and can deadlock when every foreground connection
            // is waiting for that nested acquisition. Warm plain sends reserve
            // credits before their transaction in the conditional fast path;
            // this cold/rich path uses the exact conditional SQL reservation
            // below as its final statement instead.
            let shardStateForReduction = shardState
            let result: V2SendMessageAcceptanceResult
            // 房间日志是权威副本：不预留任何逐用户投递成本，被 @ 的成员只收到通知。
            result = try roomLogReduction(
                command: command,
                roomState: roomState,
                shardState: shardStateForReduction,
                profile: capacityProfile.limits,
                identifiers: identifiers,
                now: now
            )
            guard case .accepted(let writeSet) = result else {
                return .init(
                    outcome: result.outcome(
                        mediaPresentations: mediaPresentations,
                        groupCapacityClass: room.kind == "group" ? room.capacityClass : nil
                    )
                )
            }
            // Do this only after the generic admission reducer accepts. A
            // capacity rejection returns normally from this transaction, so
            // consuming the stranger window earlier would be a silent quota
            // loss despite no accepted message.
            if let directContext, directContext.requiresStrangerQuota {
                try await consumeDirectMessageQuota(
                    senderID: senderID,
                    recipientID: directContext.recipientID,
                    policy: strangerMessagePolicy,
                    now: now,
                    sql: sql
                )
            }
            let loadedDirectPolicyCacheEntry = loadedContext.directPolicyCacheEntry()
            var updatedDirectPolicyCacheEntry = loadedDirectPolicyCacheEntry
            // The reply marker is monotonic. Once a sender has an accepted
            // message we no longer issue a no-op UPDATE for every later send.
            // The actual value comes from the transaction snapshot, never
            // from the process-local cache.
            var replyMarkerAdvanced = false
            if let directContext, !directContext.senderHasReplied {
                replyMarkerAdvanced = try await markDirectSenderHasReplied(
                    roomID: roomID,
                    senderID: senderID,
                    sql: sql
                )
                if replyMarkerAdvanced {
                    updatedDirectPolicyCacheEntry = updatedDirectPolicyCacheEntry?.markingSenderHasReplied()
                }
            }

            let timelineWriteSet = try withTimelineSequence(writeSet, timelineSequence: roomWriteNextSequence(room.timelineSequence))
            let acceptedMessage = timelineWriteSet.acceptedMessage.materialized(
                mediaPresentations: mediaPresentations,
                groupCapacityClass: room.kind == "group" ? room.capacityClass : nil,

                sourceEventID: timelineWriteSet.eventID,
                acceptedMembershipRevision: try unsigned(room.membershipRevision),
                directRecipientUserID: directContext.map { .init(uuid: $0.recipientID) },
                projectionCreatedAtUnixMilliseconds: try roomWriteProjectionMilliseconds(timelineWriteSet.acceptedMessage.createdAt)
            )
            let acceptedState = try V2MessageProjectionState(
                accepted: acceptedMessage,
                forwardedFromMessageID: command.forwardedFrom?.messageID,
                forwardedFromUserID: command.forwardedFrom?.senderUserID
            )
            let messageStateEventID = try uuid(timelineWriteSet.eventID)
            let storedMessageState = try V2StoredMessageProjectionState(
                state: acceptedState,
                originEventID: messageStateEventID,
                stateEventID: messageStateEventID,
                createdAt: acceptedMessage.createdAt
            )
            let shardReservation = try shardAdmissionReservation(
                from: shardStateForReduction,
                to: timelineWriteSet.nextShardState
            )
            try await persist(
                timelineWriteSet,
                command: command,
                mediaPresentations: mediaPresentations,
                messageProjectionState: storedMessageState,
                room: room,
                sql: sql
            )
            if let directContext,
               (!directContext.senderProfileVisibleToRecipient || directContext.senderCanSend != true || directContext.supportAccountID != nil) {
                let recipientID = directContext.recipientID
                let projectionChanges = try await appendDirectPostAcceptanceProjections(
                    roomID: roomID,
                    senderID: senderID,
                    recipientID: recipientID,
                    senderProfileVisibleToRecipient: directContext.senderProfileVisibleToRecipient,
                    senderCanSend: directContext.senderCanSend,
                    sourceEventID: messageStateEventID,
                    createdAt: timelineWriteSet.acceptedMessage.createdAt,
                    stateVersion: timelineWriteSet.acceptedMessage.timelineSequence,
                    sql: sql
                )
                updatedDirectPolicyCacheEntry = updatedDirectPolicyCacheEntry?
                    .applyingPostAcceptanceProjection(
                        senderCapabilityInserted: projectionChanges.senderCapabilityInserted,
                        recipientProfileInserted: projectionChanges.recipientProfileInserted
                    )
                if let supportAccountID = directContext.supportAccountID {
                    try await openSupportSessionIfNeeded(
                        roomID: roomID,
                        senderID: senderID,
                        supportAccountID: supportAccountID,
                        createdAt: timelineWriteSet.acceptedMessage.createdAt,
                        sql: sql
                    )
                }
            }
            // Keep the contended shard counter update as the final, narrow
            // statement. Folding this lock into the large data-modifying CTE
            // made the complete write graph wait behind one of nine shared
            // shard rows and multiplied foreground connection occupancy.
            // A rejection still throws inside this transaction, so all prior
            // message/fan-out writes roll back atomically.
            try await reserveShardAdmission(
                shardReservation,
                room: room,
                retryAfterSeconds: capacityProfile.limits.retryAfterSeconds,
                now: now,
                sql: sql
            )
            let fastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry?
            if usesDirectRoomLog,
               Self.isPlainDirectRoomLogBatchShape(.init(
                    command: command,
                    capacityProfile: capacityProfile,
                    identifiers: identifiers,
                    now: now
               )),
               let cacheEntry = updatedDirectPolicyCacheEntry,
               fastPlainDirectPolicyIsCacheCandidate(cacheEntry) {
                fastAppendCacheUpdate = .init(
                    policy: cacheEntry,
                    roomShardID: room.roomShardID,
                    capacityProfileID: room.capacityProfileID,
                    membershipRevision: room.membershipRevision,
                    shardState: try shard.admissionState()
                )
            } else {
                fastAppendCacheUpdate = nil
            }
            let reciprocalReplyCacheUpdate: DirectReplyCacheUpdate?
            if replyMarkerAdvanced,
               let directContext,
               let loadedDirectPolicyCacheEntry {
                reciprocalReplyCacheUpdate = .init(
                    key: .init(
                        roomID: roomID,
                        senderID: directContext.recipientID
                    ),
                    expectedDirectPairRevision: loadedDirectPolicyCacheEntry.directPairRevision
                )
            } else {
                reciprocalReplyCacheUpdate = nil
            }
            return .init(
                outcome: .accepted(acceptedMessage),
                directPolicyCacheUpdate: updatedDirectPolicyCacheEntry,
                directRoomLogFastAppendCacheUpdate: fastAppendCacheUpdate,
                reciprocalDirectReplyCacheUpdate: reciprocalReplyCacheUpdate,
                shardAdmissionCommandCredit: nil,
                roomAdmissionHeatObservation: usesDirectRoomLog
                    && roomAdmissionCommandCreditPool != nil
                    && directContext?.supportAccountID == nil
                    && command.media.isEmpty
                    && command.mentions.isEmpty
                    && command.replyTo == nil
                    && command.forwardedFrom == nil
                    ? roomID : nil
            )
            } catch {
                throw error
            }
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
        // Admission heat is process-local runtime state, so it must use the
        // runtime clock just like the former per-commit finalizer. Request
        // timestamps may be deterministic/replayed and are not a valid cache
        // freshness clock.
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

        // These mutations are tiny actor-isolated dictionary/counter updates.
        // One batched hop per actor is cheaper and more predictable than
        // creating four child tasks for every PostgreSQL micro-batch.
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
    private func shardAdmissionReservation(
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

    private func reserveShardAdmission(
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
    private func acquireMessageOperationLock(
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
        // Production PostgreSQL receives typed arrays through a named
        // statement. This removes JSON serialization/parsing and lets every
        // physical foreground connection reuse the invariant recursive lock
        // plan without changing the transaction or ordered-lock contract.
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

    /// 单聊房间日志预检的批量变体。
    ///
    /// 进程本地策略缓存刻意*不是*权威：
    /// 每次命中都只有在本次查询锁定并精确匹配持久配对与两条用户策略修订围栏之后才被接受。
    /// 未命中或不匹配时，会先从事 PostgreSQL 读取完整策略，命令才可能被接受。
    ///
    /// - Parameters:
    ///   - ordered: 已排序的房间写入请求。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 各请求对应的预检结果行。
    /// - Throws: 预检不匹配或查询失败时抛出。
    private func loadPlainDirectRoomLogBatchContexts(
        _ ordered: [OrderedRoomWriteRequest],
        sql: any SQLDatabase
    ) async throws -> [PlainDirectRoomLogBatchPreflightRow] {
        let input = try ordered.map { item in
            PlainDirectRoomLogBatchPreflightInput(
                ordinal: item.preflightOrdinal,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: try uuid(item.request.command.clientMessageID),
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(item.request.now),
                cachedDirectPolicy: item.cachedDirectPolicy,
                usesRoomAdmissionCredits: item.usesRoomAdmissionCredits
            )
        }
        let inputJSON = try roomWriteJSON(input)
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.sender_id,
                       input.client_message_id, input.now_postgres_microseconds,
                       input.cached_recipient_id,
                       input.cached_direct_pair_revision,
                       input.cached_sender_policy_revision,
                       input.cached_recipient_policy_revision,
                       input.cached_recipient_is_active,
                       input.cached_blocked, input.cached_is_friend,
                       input.cached_allows_strangers,
                       input.uses_room_admission_credits
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    now_postgres_microseconds bigint,
                    cached_recipient_id uuid,
                    cached_direct_pair_revision bigint,
                    cached_sender_policy_revision bigint,
                    cached_recipient_policy_revision bigint,
                    cached_recipient_is_active boolean,
                    cached_blocked boolean,
                    cached_is_friend boolean,
                    cached_allows_strangers boolean,
                    uses_room_admission_credits boolean
                )
            ), locked_room AS MATERIALIZED (
                SELECT input.ordinal, input.sender_id, input.client_message_id,
                       input.now_postgres_microseconds, input.cached_recipient_id,
                       input.cached_direct_pair_revision,
                       input.cached_sender_policy_revision,
                       input.cached_recipient_policy_revision,
                       input.cached_recipient_is_active,
                       input.cached_blocked, input.cached_is_friend,
                       input.cached_allows_strangers,
                       input.uses_room_admission_credits, room.room_kind,
                       room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.capacity_class,
                       room.frozen_at, room.room_id
                FROM input
                JOIN im_v2.rooms AS room ON room.room_id = input.room_id
                ORDER BY room.room_id
                -- Room identity is immutable. Keep writers serialized while
                -- allowing independent KEY SHARE credit reservations.
                FOR NO KEY UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                SELECT room.ordinal
                FROM locked_room AS room
                JOIN im_v2.message_send_completions AS message
                  ON message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                 AND message.client_message_id = room.client_message_id
                UNION
                SELECT room.ordinal
                FROM locked_room AS room
                JOIN im_v2.direct_message_denials AS denial
                  ON denial.sender_user_id = room.sender_id
                  AND denial.room_id = room.room_id
                 AND denial.client_message_id = room.client_message_id
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (
                    SELECT 1 FROM prior_operation AS prior
                    WHERE prior.ordinal = room.ordinal
                )
            ), locked_room_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.eligible_member_count AS room_eligible_member_count,
                       admission.command_window_limit AS room_command_window_limit,
                       admission.command_window_used AS room_command_window_used,
                       admission.shard_lease_id AS room_shard_lease_id,
                       admission.shard_lease_generation AS room_shard_lease_generation
                FROM fresh_room AS room
                JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
                -- Precharged room credits already account for the room
                -- command window; all other sends lock its durable row.
                WHERE NOT room.uses_room_admission_credits
                FOR UPDATE OF admission
            ), locked_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.room_eligible_member_count,
                       admission.room_command_window_limit,
                       admission.room_command_window_used,
                       admission.room_shard_lease_id,
                       admission.room_shard_lease_generation,
                       shard.lease_id AS shard_lease_id,
                       shard.generation AS shard_generation,
                       shard.valid_until AS shard_valid_until,
                       shard.command_window_limit AS shard_command_window_limit,
                       shard.command_window_used AS shard_command_window_used
                FROM fresh_room AS room
                LEFT JOIN locked_room_admission AS admission ON admission.ordinal = room.ordinal
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
            ), locked_actor AS MATERIALIZED (
                SELECT room.ordinal, membership.role AS actor_role,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = room.sender_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = room.sender_id
                             AND mute.mute_until > ((TIMESTAMP '2000-01-01 00:00:00'
                             + (room.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (room.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC')
                       ) AS muted
                FROM fresh_room AS room
                JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = room.sender_id
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                FOR UPDATE OF membership
            ), direct_pair AS MATERIALIZED (
                SELECT room.ordinal, pair.lower_user_id, pair.higher_user_id,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.higher_user_id ELSE pair.lower_user_id END AS recipient_user_id,
                       pair.direct_policy_revision,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.lower_profile_visible_to_higher
                            ELSE pair.higher_profile_visible_to_lower
                       END AS sender_profile_visible_to_recipient,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.lower_can_send ELSE pair.higher_can_send
                       END AS sender_can_send,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.lower_has_replied ELSE pair.higher_has_replied END AS sender_has_replied,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.higher_has_replied ELSE pair.lower_has_replied END AS recipient_has_replied
                FROM fresh_room AS room
                JOIN locked_actor AS actor ON actor.ordinal = room.ordinal
                JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
                WHERE room.room_kind = 'direct'
                  AND (pair.lower_user_id = room.sender_id
                       OR pair.higher_user_id = room.sender_id)
                FOR UPDATE OF pair
            ), direct_policy_versions AS MATERIALIZED (
                SELECT pair.*,
                       sender_version.revision AS sender_policy_revision,
                       recipient_version.revision AS recipient_policy_revision
                FROM direct_pair AS pair
                JOIN fresh_room AS room ON room.ordinal = pair.ordinal
                JOIN im_v2.user_direct_send_policy_versions AS sender_version
                  ON sender_version.user_id = room.sender_id
                JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                  ON recipient_version.user_id = pair.recipient_user_id
                FOR KEY SHARE OF sender_version, recipient_version
            ), special AS MATERIALIZED (
                SELECT pair.ordinal, account.account_user_id, account.account_kind,
                       account.status, account.allows_customer_messages,
                       account.allows_service_messages
                FROM direct_policy_versions AS pair
                JOIN fresh_room AS room ON room.ordinal = pair.ordinal
                JOIN im_v2.special_accounts AS account
                  ON account.account_user_id = room.sender_id
                  OR account.account_user_id = pair.recipient_user_id
                ORDER BY pair.ordinal, account.account_user_id
                FOR KEY SHARE OF account
            ), direct_policy AS MATERIALIZED (
                SELECT pair.ordinal, pair.recipient_user_id,
                       pair.direct_policy_revision, pair.sender_policy_revision,
                       pair.recipient_policy_revision,
                       pair.sender_profile_visible_to_recipient,
                       pair.sender_can_send, pair.sender_has_replied,
                       pair.recipient_has_replied,
                       CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                      AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                      AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                      AND pair.recipient_user_id = room.cached_recipient_id
                            THEN room.cached_recipient_is_active
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = pair.recipient_user_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) END AS recipient_is_active,
                       CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                      AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                      AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                      AND pair.recipient_user_id = room.cached_recipient_id
                            THEN room.cached_blocked
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_blocks AS block
                           WHERE (block.blocker_user_id = pair.lower_user_id
                                  AND block.blocked_user_id = pair.higher_user_id)
                              OR (block.blocker_user_id = pair.higher_user_id
                                  AND block.blocked_user_id = pair.lower_user_id)
                       ) END AS blocked,
                       CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                      AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                      AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                      AND pair.recipient_user_id = room.cached_recipient_id
                            THEN room.cached_is_friend
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_relationships AS relationship
                           WHERE relationship.lower_user_id = pair.lower_user_id
                             AND relationship.higher_user_id = pair.higher_user_id
                             AND relationship.state = 'accepted'
                       ) END AS is_friend,
                       CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                      AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                      AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                      AND pair.recipient_user_id = room.cached_recipient_id
                            THEN room.cached_allows_strangers
                            ELSE COALESCE((
                           SELECT preference.allows_stranger_messages
                           FROM im_v2.user_stranger_message_preferences AS preference
                           WHERE preference.user_id = pair.recipient_user_id
                       ), TRUE) END AS allows_strangers,
                       (SELECT account_kind FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = room.sender_id) AS sender_account_kind,
                       (SELECT status FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = room.sender_id) AS sender_account_status,
                       (SELECT allows_service_messages FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = room.sender_id) AS sender_allows_service_messages,
                       (SELECT account_kind FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = pair.recipient_user_id) AS recipient_account_kind,
                       (SELECT status FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = pair.recipient_user_id) AS recipient_account_status,
                       (SELECT allows_customer_messages FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = pair.recipient_user_id) AS recipient_allows_customer_messages
                FROM direct_policy_versions AS pair
                JOIN fresh_room AS room ON room.ordinal = pair.ordinal
            )
            SELECT room.ordinal, room.room_kind, room.room_shard_id,
                   room.room_sequence, room.timeline_sequence,
                   room.membership_revision, room.capacity_profile_id,
                   room.capacity_class, room.frozen_at,
                   admission.room_eligible_member_count,
                   admission.room_command_window_limit,
                   admission.room_command_window_used,
                   admission.room_shard_lease_id,
                   admission.room_shard_lease_generation,
                   admission.shard_lease_id, admission.shard_generation,
                   admission.shard_valid_until,
                   admission.shard_command_window_limit,
                   admission.shard_command_window_used,
                   actor.actor_role, actor.sender_is_active, actor.muted,
                   policy.recipient_user_id,
                   policy.sender_profile_visible_to_recipient,
                   policy.direct_policy_revision,
                   policy.sender_policy_revision, policy.recipient_policy_revision,
                   policy.sender_can_send, policy.recipient_is_active,
                   policy.blocked, policy.is_friend, policy.sender_has_replied,
                   policy.recipient_has_replied, policy.allows_strangers,
                   policy.sender_account_kind, policy.sender_account_status,
                   policy.sender_allows_service_messages,
                   policy.recipient_account_kind, policy.recipient_account_status,
                   policy.recipient_allows_customer_messages
            FROM fresh_room AS room
            LEFT JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
            LEFT JOIN locked_actor AS actor ON actor.ordinal = room.ordinal
            LEFT JOIN direct_policy AS policy ON policy.ordinal = room.ordinal
            ORDER BY room.ordinal
            """).all().map { try PlainDirectRoomLogBatchPreflightRow(row: $0) }
        guard rows.count == ordered.count,
              zip(rows, ordered).allSatisfy({ $0.0.ordinal == $0.1.preflightOrdinal })
        else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        return rows
    }

    /// 只加载在更长消息事务开始之前、用于预留持久命令额度所需的分片租约。
    ///
    /// 这次读取刻意不是授权决定：
    /// `loadPlainHybridGroupBatchContexts` 会在持有既定房间本地锁的情况下，
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

    /// 普通混合群组发送的集合式权威预检。
    ///
    /// 房间/准入/成员的加锁顺序与标量路径完全一致。
    /// 权限判定基于同一批持久策略行求值，而房间锁则为并发的策略变更建立围栏。
    ///
    /// - Parameters:
    ///   - ordered: 已排序的房间写入请求。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 各请求对应的预检结果行。
    /// - Throws: 预检不匹配或查询失败时抛出。
    private func loadPlainHybridGroupBatchContexts(
        _ ordered: [OrderedRoomWriteRequest],
        sql: any SQLDatabase
    ) async throws -> [PlainHybridGroupBatchPreflightRow] {
        let input = try ordered.map { item in
            PlainHybridGroupBatchPreflightInput(
                ordinal: item.preflightOrdinal,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: try uuid(item.request.command.clientMessageID),
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(item.request.now)
            )
        }
        // Production uses a named statement with typed column arrays. The
        // authorization graph and lock order below are unchanged; this only
        // removes per-batch JSON encoding/parsing and lets each physical
        // foreground connection reuse PostgreSQL's prepared plan.
        if let postgres = sql as? any PostgresDatabase {
            let statement = try PlainHybridGroupBatchPreflightStatement(inputs: input)
            let rows = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let result = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var decoded: [PlainHybridGroupBatchPreflightRow] = []
                    decoded.reserveCapacity(input.count)
                    for try await row in result {
                        decoded.append(row)
                    }
                    return decoded
                }
            }.get()
            guard rows.count == ordered.count,
                  zip(rows, ordered).allSatisfy({
                      $0.0.ordinal == $0.1.preflightOrdinal
                  })
            else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
            return rows
        }
        let inputJSON = try roomWriteJSON(input)
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.sender_id,
                       input.client_message_id, input.now_postgres_microseconds
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    now_postgres_microseconds bigint
                )
            ), locked_room AS MATERIALIZED (
                SELECT input.ordinal, input.sender_id, input.client_message_id,
                       input.now_postgres_microseconds, room.room_kind,
                       room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.capacity_class,
                       room.frozen_at, room.room_id
                FROM input
                JOIN im_v2.rooms AS room ON room.room_id = input.room_id
                ORDER BY room.room_id
                FOR UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                SELECT room.ordinal
                FROM locked_room AS room
                JOIN im_v2.message_send_completions AS message
                  ON message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                 AND message.client_message_id = room.client_message_id
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (
                    SELECT 1 FROM prior_operation AS prior
                    WHERE prior.ordinal = room.ordinal
                )
            ), locked_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.eligible_member_count AS room_eligible_member_count,
                       admission.command_window_limit AS room_command_window_limit,
                       admission.command_window_used AS room_command_window_used,
                       admission.shard_lease_id AS room_shard_lease_id,
                       admission.shard_lease_generation AS room_shard_lease_generation,
                       shard.lease_id AS shard_lease_id,
                       shard.generation AS shard_generation,
                       shard.valid_until AS shard_valid_until,
                       shard.command_window_limit AS shard_command_window_limit,
                       shard.command_window_used AS shard_command_window_used
                FROM fresh_room AS room
                JOIN im_v2.room_admission AS admission
                  ON admission.room_id = room.room_id
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
                ORDER BY room.room_id
                FOR UPDATE OF admission
            ), locked_actor AS MATERIALIZED (
                SELECT room.ordinal, membership.role AS actor_role,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = room.sender_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = room.sender_id
                             AND mute.mute_until > ((TIMESTAMP '2000-01-01 00:00:00'
                             + (room.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (room.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC')
                       ) AS muted,
                       (
                           membership.role = 'owner'
                           OR EXISTS (
                               SELECT 1 FROM im_v2.group_role_permissions AS permission
                               WHERE permission.room_id = room.room_id
                                 AND permission.role = membership.role
                                 AND permission.permission = 'send_messages'
                           )
                           OR NOT EXISTS (
                               SELECT 1 FROM (SELECT room_id, role FROM im_v2.group_role_policies UNION ALL SELECT room_id, role FROM im_v2.group_role_permissions) AS operation
                               WHERE operation.room_id = room.room_id
                                 AND operation.role = membership.role
                           )
                       ) AS allows_send_messages
                FROM fresh_room AS room
                JOIN locked_admission AS admission USING (ordinal)
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = room.sender_id
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                ORDER BY room.room_id, membership.user_id
                FOR UPDATE OF membership
            )
            SELECT room.ordinal, room.room_kind, room.room_shard_id,
                   room.room_sequence, room.timeline_sequence,
                   room.membership_revision, room.capacity_profile_id,
                   room.capacity_class, room.frozen_at,
                   EXISTS (
                       SELECT 1 FROM prior_operation AS prior
                       WHERE prior.ordinal = room.ordinal
                   ) AS has_prior_operation,
                   admission.room_eligible_member_count,
                   admission.room_command_window_limit,
                   admission.room_command_window_used,
                   admission.room_shard_lease_id,
                   admission.room_shard_lease_generation,
                   admission.shard_lease_id, admission.shard_generation,
                   admission.shard_valid_until,
                   admission.shard_command_window_limit,
                   admission.shard_command_window_used,
                   actor.actor_role, actor.sender_is_active, actor.muted,
                   actor.allows_send_messages
            FROM locked_room AS room
            LEFT JOIN locked_admission AS admission USING (ordinal)
            LEFT JOIN locked_actor AS actor USING (ordinal)
            ORDER BY room.ordinal
            """).all().map { try PlainHybridGroupBatchPreflightRow(row: $0) }
        guard rows.count == ordered.count,
              zip(rows, ordered).allSatisfy({ $0.0.ordinal == $0.1.preflightOrdinal })
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return rows
    }

    /// 一次事务范围内的读取，同时加载房间、幂等结果、房间准入、发送者成员关系与单聊策略。
    ///
    /// 操作围栏已经建立了新快照；CTE 加锁图保持
    /// 房间 -> 房间准入 -> 发送者成员 -> 单聊配对的顺序。
    /// 共享分片行仍只作为最后一步的窄范围预留。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - senderID: 发送者标识。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 消息接受上下文。
    /// - Throws: 查询失败时抛出。
    private func loadMessageAcceptanceContext(
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        now: Date,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        sql: any SQLDatabase
    ) async throws -> MessageAcceptanceContextRow {
        // A cached sender reply marker is only a performance hint. The
        // durable direct-pair and policy-version rows remain locked until the
        // message transaction commits, so a block or preference change either
        // precedes this decision (revision mismatch -> database evaluation)
        // or follows this accepted message. `senderHasReplied` is monotonic;
        // a cache hit lets steady-state sends use compatible shared locks
        // instead of the exclusive locks needed by a first reply-marker write.
        let directPairLockClause = cachedDirectPolicy?.senderHasReplied == true
            ? "FOR SHARE OF pair"
            : "FOR UPDATE OF pair"
        let directPolicyVersionLockClause = cachedDirectPolicy?.senderHasReplied == true
            ? "FOR SHARE OF sender_version, recipient_version"
            : "FOR KEY SHARE OF sender_version, recipient_version"
        let rows = try await sql.raw("""
            WITH locked_room AS MATERIALIZED (
                SELECT room.room_kind, room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.capacity_class,
                       room.frozen_at,
                       room.room_id
                FROM im_v2.rooms AS room
                WHERE room.room_id = \(bind: roomID)
                FOR UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                SELECT 'accepted'::text AS prior_outcome_kind,
                       message.message_id AS prior_message_id,
                       message.room_id AS prior_room_id,
                       message.room_sequence AS prior_room_sequence,
                       message.timeline_sequence AS prior_timeline_sequence,
                       message.sender_user_id AS prior_sender_user_id,
                       message.client_message_id AS prior_client_message_id,
                       message.fingerprint_version AS prior_fingerprint_version,
                       message.request_fingerprint AS prior_request_fingerprint,
                       message.created_at AS prior_created_at,
                       message.event_id AS prior_source_event_id,
                       message.accepted_membership_revision AS prior_accepted_membership_revision,
                       message.direct_recipient_user_id AS prior_direct_recipient_user_id,
                       NULL::text AS prior_denial_reason,
                       message.group_capacity_class AS prior_group_capacity_class
                FROM locked_room
                JOIN im_v2.message_send_completions AS message ON message.room_id = locked_room.room_id
                WHERE message.sender_user_id = \(bind: senderID)
                  AND message.client_message_id = \(bind: clientMessageID)
                UNION ALL
                SELECT 'denied'::text,
                       NULL::uuid,
                       denial.room_id,
                       NULL::bigint,
                       denial.timeline_sequence,
                       denial.sender_user_id,
                       denial.client_message_id,
                       denial.fingerprint_version,
                       denial.request_fingerprint,
                       denial.created_at,
                       denial.source_event_id,
                       NULL::bigint,
                       NULL::uuid,
                       denial.reason,
                       NULL::text
                FROM locked_room
                JOIN im_v2.direct_message_denials AS denial ON denial.room_id = locked_room.room_id
                WHERE denial.sender_user_id = \(bind: senderID)
                  AND denial.client_message_id = \(bind: clientMessageID)
            ), prior_operation_count AS MATERIALIZED (
                SELECT COUNT(*)::integer AS prior_operation_count FROM prior_operation
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (SELECT 1 FROM prior_operation)
            ), locked_admission AS MATERIALIZED (
                SELECT admission.eligible_member_count AS room_eligible_member_count,
                       admission.command_window_limit AS room_command_window_limit,
                       admission.command_window_used AS room_command_window_used,
                       admission.shard_lease_id AS room_shard_lease_id,
                       admission.shard_lease_generation AS room_shard_lease_generation,
                       shard.lease_id AS shard_lease_id,
                       shard.generation AS shard_generation,
                       shard.valid_until AS shard_valid_until,
                       shard.command_window_limit AS shard_command_window_limit,
                       shard.command_window_used AS shard_command_window_used
                FROM fresh_room AS room
                JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
                FOR UPDATE OF admission
            ), locked_actor AS MATERIALIZED (
                SELECT membership.role AS actor_role,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = \(bind: senderID)
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = \(bind: senderID)
                             AND mute.mute_until > \(bind: now)
                       ) AS muted
                FROM fresh_room AS room
                CROSS JOIN locked_admission
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = \(bind: senderID)
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                FOR UPDATE OF membership
            ), direct_pair AS MATERIALIZED (
                SELECT pair.room_id, pair.lower_user_id, pair.higher_user_id,
                       pair.lower_profile_visible_to_higher,
                       pair.higher_profile_visible_to_lower,
                       pair.lower_can_send, pair.higher_can_send,
                       pair.lower_has_replied, pair.higher_has_replied,
                       pair.direct_policy_revision,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.higher_user_id ELSE pair.lower_user_id END AS recipient_user_id
                FROM fresh_room AS room
                CROSS JOIN locked_actor
                JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
                WHERE room.room_kind = 'direct'
                  AND (pair.lower_user_id = \(bind: senderID)
                       OR pair.higher_user_id = \(bind: senderID))
                \(unsafeRaw: directPairLockClause)
            ), direct_policy_versions AS MATERIALIZED (
                SELECT pair.*, sender_version.revision AS sender_policy_revision,
                       recipient_version.revision AS recipient_policy_revision
                FROM direct_pair AS pair
                JOIN im_v2.user_direct_send_policy_versions AS sender_version
                  ON sender_version.user_id = \(bind: senderID)
                JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                  ON recipient_version.user_id = pair.recipient_user_id
                \(unsafeRaw: directPolicyVersionLockClause)
            ), special AS MATERIALIZED (
                SELECT account.account_user_id, account.account_kind, account.status,
                       account.allows_customer_messages, account.allows_service_messages
                FROM im_v2.special_accounts AS account
                JOIN direct_policy_versions AS pair
                  ON account.account_user_id = \(bind: senderID)
                  OR account.account_user_id = pair.recipient_user_id
                ORDER BY account.account_user_id
                FOR KEY SHARE OF account
            ), direct_policy AS MATERIALIZED (
                SELECT pair.recipient_user_id, pair.direct_policy_revision,
                       pair.sender_policy_revision, pair.recipient_policy_revision,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.lower_profile_visible_to_higher
                            ELSE pair.higher_profile_visible_to_lower
                       END AS sender_profile_visible_to_recipient,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.lower_can_send
                            ELSE pair.higher_can_send
                       END AS sender_can_send,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.lower_has_replied
                            ELSE pair.higher_has_replied
                       END AS sender_has_replied,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.recipientIsActive)
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = pair.recipient_user_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) END AS recipient_is_active,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.blocked)
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_blocks AS block
                           WHERE (block.blocker_user_id = pair.lower_user_id AND block.blocked_user_id = pair.higher_user_id)
                              OR (block.blocker_user_id = pair.higher_user_id AND block.blocked_user_id = pair.lower_user_id)
                       ) END AS blocked,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.isFriend)
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_relationships AS relationship
                           WHERE relationship.lower_user_id = pair.lower_user_id
                             AND relationship.higher_user_id = pair.higher_user_id
                             AND relationship.state = 'accepted'
                       ) END AS is_friend,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.higher_has_replied
                            ELSE pair.lower_has_replied
                       END AS recipient_has_replied,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.allowsStrangers)
                            ELSE COALESCE((
                           SELECT preference.allows_stranger_messages
                           FROM im_v2.user_stranger_message_preferences AS preference
                           WHERE preference.user_id = pair.recipient_user_id
                       ), TRUE) END AS allows_strangers,
                       (SELECT account_kind FROM special WHERE account_user_id = \(bind: senderID)) AS sender_account_kind,
                       (SELECT status FROM special WHERE account_user_id = \(bind: senderID)) AS sender_account_status,
                       (SELECT allows_service_messages FROM special WHERE account_user_id = \(bind: senderID)) AS sender_allows_service_messages,
                       (SELECT account_kind FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_account_kind,
                       (SELECT status FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_account_status,
                       (SELECT allows_customer_messages FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_allows_customer_messages
                FROM direct_policy_versions AS pair
            )
            SELECT room.room_kind, room.room_shard_id, room.room_sequence,
                   room.timeline_sequence, room.membership_revision,
                   room.capacity_profile_id, room.capacity_class, room.frozen_at,
                   count.prior_operation_count,
                   prior.prior_outcome_kind, prior.prior_message_id,
                   prior.prior_room_id, prior.prior_room_sequence,
                   prior.prior_timeline_sequence, prior.prior_sender_user_id,
                   prior.prior_client_message_id, prior.prior_fingerprint_version,
                   prior.prior_request_fingerprint,
                   prior.prior_created_at, prior.prior_source_event_id,
                   prior.prior_accepted_membership_revision,
                   prior.prior_direct_recipient_user_id,
                   prior.prior_denial_reason, prior.prior_group_capacity_class,
                   admission.*, actor.actor_role, actor.sender_is_active, actor.muted,
                   policy.recipient_user_id, policy.sender_profile_visible_to_recipient,
                   policy.direct_policy_revision, policy.sender_policy_revision,
                   policy.recipient_policy_revision,
                   policy.sender_can_send, policy.recipient_is_active, policy.blocked,
                   policy.is_friend, policy.sender_has_replied,
                   policy.recipient_has_replied, policy.allows_strangers,
                   policy.sender_account_kind, policy.sender_account_status,
                   policy.sender_allows_service_messages, policy.recipient_account_kind,
                   policy.recipient_account_status, policy.recipient_allows_customer_messages
            FROM locked_room AS room
            CROSS JOIN prior_operation_count AS count
            LEFT JOIN prior_operation AS prior ON TRUE
            LEFT JOIN locked_admission AS admission ON TRUE
            LEFT JOIN locked_actor AS actor ON TRUE
            LEFT JOIN direct_policy AS policy ON TRUE
            """).all(decoding: MessageAcceptanceContextRow.self)
        guard rows.count == 1, let row = rows.first else {
            throw rows.isEmpty ? V2RoomWriteStoreError.roomNotFound : V2RoomWriteStoreError.corruptPersistenceState
        }
        guard row.priorOperationCount <= 1 else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return row
    }

    /// 上方的 SQL 加载器负责一致的数据库快照与锁；
    /// 这次纯映射刻意保持既有的单聊策略判定表不变。
    ///
    /// - Parameter policy: 单聊策略快照行。
    /// - Returns: 单聊消息接受上下文。
    /// - Throws: 快照字段非法时抛出。
    private func directMessageContext(
        from localPolicy: DirectMessagePolicySnapshotRow, roomID: UUID, senderID: UUID
    ) throws -> DirectMessageAcceptanceContext {
        let authority = try controlPolicy(roomID: roomID, senderID: senderID, recipientID: localPolicy.recipientUserID)
        let policy = authority.map { localPolicy.applyingControlPolicy($0) } ?? localPolicy
        let recipientID = policy.recipientUserID
        let restriction: V2DirectMessageDenied.Reason?
        if policy.senderAccountKind != nil {
            restriction = policy.senderAccountStatus == "active" && policy.senderAllowsServiceMessages == true ? nil : .generic
            // Special subjects have no public gateway credential. A call that
            // reaches this branch originated at the trusted service boundary.
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
    private func consumeDirectMessageQuota(senderID: UUID, recipientID: UUID, policy: V2StrangerMessagePolicy, now: Date, sql: any SQLDatabase) async throws {
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
    private func markDirectSenderHasReplied(
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
        // The locked preflight requires this first-reply transition. A
        // missing update must not leave the accepted message with a stale
        // reply marker or policy revision.
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
    private func persistDirectMessageDenied(
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
        // Preserve the native Date bind below, but expose exactly the time
        // decoded by a future replay. Rebinding a decoded Date can lose another
        // microsecond, so response normalization must not change persistence.
        let persistedCreatedAt = try roomWritePersistedDate(createdAt)
        let createdAtMilliseconds = try v2GatewayMilliseconds(persistedCreatedAt)
        let timelineSequence = try signed(nextTimelineSequence)
        let activityType = directMessageTimelineActivityType(for: reason)
        try await sql.raw("UPDATE im_v2.rooms SET timeline_sequence = \(bind: timelineSequence) WHERE room_id = \(bind: roomUUID)").run()
        // The denial row references its private timeline activity. Insert the
        // referenced fact first; both rows still commit atomically inside the
        // surrounding message transaction.
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
    private func openSupportSessionIfNeeded(roomID: UUID, senderID: UUID, supportAccountID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
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

    private func withTimelineSequence(_ writeSet: V2MessageAcceptanceTransaction, timelineSequence: UInt64) throws -> V2MessageAcceptanceTransaction {
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

    /// 追加单聊接受后的投影。
    ///
    /// 只有在其首条消息于同一个事务中通过拉黑、陌生人偏好与配额检查之后，
    /// 才会把一个尚未开启的单聊配对展示给接收者。
    /// 资料投影排在该接收者同步流中异步消息扇出之前，
    /// 因此被投递的首条消息总有一个稳定的会话身份。
    ///
    /// 配对本地的生产者标记由 `directMessageContext` 加锁，
    /// 因此它们对「投影是否发生变化」始终给出精确且与压缩无关的答案。
    /// 已建立的会话无需再走一次 PostgreSQL 往返即可返回；
    /// 发生状态迁移时会分配其序号，并与消息事务原子地推进这些标记。
    ///
    /// 有序单聊微批已经锁定了每个配对与策略行。
    /// 因此在单条 SQL 语句中分配全部首消息投影，
    /// 而不是为每个独立房间重复执行单消息 CTE。
    /// 一个发送者可能在同一批次中出现在多个房间里，
    /// 因此这里刻意把该用户的同步序号区间只预留一次，并按既有的有序批次顺序分配其条目。
    ///
    /// - Parameter appends: 已准备的单聊房间日志追加。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    private func appendDirectPostAcceptanceProjections(
        for appends: [PreparedDirectRoomLogAppend],
        sql: any SQLDatabase
    ) async throws -> [DirectPostAcceptanceProjectionChanges] {
        guard !appends.isEmpty else { return [] }
        // The authoritative preflight has already locked every direct-pair
        // row and read the current visibility/capability facts. Once both
        // pair-local producer markers are established, another plain message
        // cannot produce a profile or capability outbox event. Avoid sending
        // the otherwise-empty set CTE to PostgreSQL for that steady state:
        // under load it was one complete SQL statement per append batch even
        // though `needed`, `projection_events`, and `pair_update` were empty.
        //
        // This is deliberately a batch-wide short circuit. If even one room
        // still needs a first-message projection, the existing CTE runs for
        // the complete batch so outbox insertion and pair marker updates
        // remain one atomic transaction. The user owner allocates sequences.
        guard appends.contains(where: {
            !$0.directContext.senderProfileVisibleToRecipient
                || $0.directContext.senderCanSend != true
        }) else {
            return Array(
                repeating: .init(
                    senderCapabilityInserted: false,
                    recipientProfileInserted: false
                ),
                count: appends.count
            )
        }
        let inputs = try appends.enumerated().map { ordinal, append in
            DirectPostAcceptanceProjectionInput(
                ordinal: ordinal,
                roomID: append.roomID,
                senderID: append.senderID,
                recipientID: append.directContext.recipientID,
                senderProfileVisibleToRecipient: append.directContext.senderProfileVisibleToRecipient,
                senderCanSend: append.directContext.senderCanSend,
                sourceEventID: append.input.eventID,
                createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(append.now),
                createdAtMilliseconds: try v2GatewayMilliseconds(roomWritePersistedDate(append.now)),
                stateVersion: append.input.timelineSequence
            )
        }
        let inputJSON = try roomWriteJSON(inputs)
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.sender_id,
                       input.recipient_id,
                       input.sender_profile_visible_to_recipient,
                       input.sender_can_send, input.source_event_id,
                       input.created_at_postgres_microseconds, input.created_at_ms, input.state_version,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    recipient_id uuid,
                    sender_profile_visible_to_recipient boolean,
                    sender_can_send boolean,
                    source_event_id uuid,
                    created_at_postgres_microseconds bigint,
                    created_at_ms bigint,
                    state_version bigint
                )
            ), needed AS MATERIALIZED (
                SELECT *
                FROM input
                WHERE NOT sender_profile_visible_to_recipient
                   OR sender_can_send IS DISTINCT FROM TRUE
            ), profile AS MATERIALIZED (
                SELECT needed.ordinal, profile.public_handle,
                       profile.display_name, profile.account_kind,
                       profile.revision, profile.updated_at
                FROM needed
                JOIN im_v2.public_user_profiles AS profile
                  ON profile.user_id = needed.sender_id
                 AND profile.state = 'active'
                 AND profile.revision > 0
            ), projection_events AS MATERIALIZED (
                SELECT needed.ordinal, needed.room_id, needed.sender_id,
                       needed.recipient_id, needed.source_event_id,
                       needed.created_at, needed.sender_id AS user_id,
                       'direct_sending_capability'::text AS projection_kind,
                       0 AS event_order,
                       jsonb_build_object(
                           'room_id', upper(needed.room_id::text),
                           'can_send', TRUE,
                           'state_version', needed.state_version,
                           'updated_at_ms',
                               needed.created_at_ms
                       ) AS payload
                FROM needed
                WHERE needed.sender_can_send IS DISTINCT FROM TRUE

                UNION ALL

                SELECT needed.ordinal, needed.room_id, needed.sender_id,
                       needed.recipient_id, needed.source_event_id,
                       needed.created_at, needed.recipient_id,
                       'direct_room_profile', 1,
                       jsonb_build_object(
                           'room_id', upper(needed.room_id::text),
                           'target_user_id', upper(needed.sender_id::text),
                           'room_created_at_ms', (SELECT floor(extract(epoch FROM created_at) * 1000)::bigint FROM im_v2.rooms WHERE room_id = needed.room_id),
                           'public_handle', profile.public_handle,
                           'display_name', profile.display_name,
                           'account_kind', profile.account_kind,
                           'revision', profile.revision,
                           'updated_at_ms',
                               \(directProfileUpdatedAtMillisecondsSQL)
                       )
                FROM needed
                JOIN profile USING (ordinal)
                WHERE NOT needed.sender_profile_visible_to_recipient
            ), log_insert AS (
                INSERT INTO im_v2.user_state_event_outbox
                    (user_id, source_event_id, projection_kind, payload,
                     created_at, next_attempt_at, source_room_id)
                SELECT event.user_id, event.source_event_id, event.projection_kind,
                       event.payload, event.created_at, event.created_at, (event.payload->>'room_id')::uuid
                FROM projection_events AS event
                ORDER BY event.user_id, event.ordinal, event.event_order
                RETURNING user_id, source_event_id, projection_kind
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_profile_visible_to_higher = CASE
                        WHEN pair.lower_user_id = needed.sender_id THEN TRUE
                        ELSE pair.lower_profile_visible_to_higher
                    END,
                    higher_profile_visible_to_lower = CASE
                        WHEN pair.higher_user_id = needed.sender_id THEN TRUE
                        ELSE pair.higher_profile_visible_to_lower
                    END,
                    lower_can_send = CASE
                        WHEN pair.lower_user_id = needed.sender_id THEN TRUE
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = needed.sender_id THEN TRUE
                        ELSE pair.higher_can_send
                    END
                FROM needed
                WHERE pair.room_id = needed.room_id
                  AND (SELECT count(*) FROM profile) = (SELECT count(*) FROM needed)
                  AND (SELECT count(*) FROM log_insert) = (SELECT count(*) FROM projection_events)
                RETURNING needed.ordinal
            )
            SELECT input.ordinal,
                   EXISTS (
                       SELECT 1 FROM projection_events AS event
                       WHERE event.ordinal = input.ordinal
                         AND event.projection_kind = 'direct_sending_capability'
                   ) AS sender_capability_inserted,
                   EXISTS (
                       SELECT 1 FROM projection_events AS event
                       WHERE event.ordinal = input.ordinal
                         AND event.projection_kind = 'direct_room_profile'
                   ) AS recipient_profile_inserted,
                   CASE WHEN EXISTS (
                       SELECT 1 FROM needed
                       WHERE needed.ordinal = input.ordinal
                   ) THEN EXISTS (
                       SELECT 1 FROM profile
                       WHERE profile.ordinal = input.ordinal
                   ) ELSE TRUE END AS profile_exists,
                   CASE WHEN EXISTS (
                       SELECT 1 FROM needed
                       WHERE needed.ordinal = input.ordinal
                   ) THEN EXISTS (
                       SELECT 1 FROM pair_update
                       WHERE pair_update.ordinal = input.ordinal
                   ) ELSE TRUE END AS pair_updated,
                   (SELECT count(*)::bigint FROM projection_events) AS expected_event_count,
                   (SELECT count(*)::bigint FROM log_insert) AS inserted_event_count
            FROM input
            ORDER BY input.ordinal
            """).all(decoding: DirectPostAcceptanceProjectionBatchRow.self)
        guard rows.count == appends.count,
              rows.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }),
              rows.allSatisfy(\.profileExists),
              rows.allSatisfy(\.pairUpdated),
              let first = rows.first,
              rows.allSatisfy({
                  $0.expectedEventCount == first.expectedEventCount
                      && $0.insertedEventCount == first.insertedEventCount
              }),
              first.expectedEventCount == first.insertedEventCount
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return rows.map {
            .init(
                senderCapabilityInserted: $0.senderCapabilityInserted,
                recipientProfileInserted: $0.recipientProfileInserted
            )
        }
    }

    private func appendDirectPostAcceptanceProjections(
        roomID: UUID,
        senderID: UUID,
        recipientID: UUID,
        senderProfileVisibleToRecipient: Bool,
        senderCanSend: Bool?,
        sourceEventID: UUID,
        createdAt: Date,
        stateVersion: UInt64,
        sql: any SQLDatabase
    ) async throws -> DirectPostAcceptanceProjectionChanges {
        guard !senderProfileVisibleToRecipient || senderCanSend != true else {
            return .init(senderCapabilityInserted: false, recipientProfileInserted: false)
        }
        guard let mutation = try await sql.raw("""
            WITH profile AS MATERIALIZED (
                SELECT public_handle, display_name, account_kind, revision, updated_at
                FROM im_v2.public_user_profiles
                WHERE user_id = \(bind: senderID)
                  AND state = 'active'
                  AND revision > 0
            ), needed AS MATERIALIZED (
                SELECT \(bind: senderID)::uuid AS user_id,
                       'direct_sending_capability'::text AS projection_kind,
                       jsonb_build_object(
                           'room_id', \(bind: roomID.uuidString),
                           'can_send', TRUE,
                           'state_version', \(bind: try signed(stateVersion)),
                           'updated_at_ms', \(bind: try v2GatewayMilliseconds(roomWritePersistedDate(createdAt)))
                       ) AS payload
                WHERE \(bind: senderCanSend != true)
                UNION ALL
                SELECT \(bind: recipientID), 'direct_room_profile',
                       jsonb_build_object(
                           'room_id', \(bind: roomID.uuidString),
                           'target_user_id', \(bind: senderID.uuidString),
                           'room_created_at_ms', (SELECT floor(extract(epoch FROM created_at) * 1000)::bigint FROM im_v2.rooms WHERE room_id = \(bind: roomID)),
                           'public_handle', profile.public_handle,
                           'display_name', profile.display_name,
                           'account_kind', profile.account_kind,
                           'revision', profile.revision,
                           'updated_at_ms', \(directProfileUpdatedAtMillisecondsSQL)
                       )
                FROM profile
                WHERE \(bind: !senderProfileVisibleToRecipient)
            ), log_insert AS (
                INSERT INTO im_v2.user_state_event_outbox
                    (user_id, source_event_id, projection_kind, payload,
                     created_at, next_attempt_at, source_room_id)
                SELECT needed.user_id, \(bind: sourceEventID),
                       needed.projection_kind, needed.payload,
                       \(bind: createdAt), \(bind: createdAt), \(bind: roomID)
                FROM needed
                ORDER BY needed.user_id
                RETURNING user_id, projection_kind
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_profile_visible_to_higher = CASE
                        WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.lower_profile_visible_to_higher
                    END,
                    higher_profile_visible_to_lower = CASE
                        WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.higher_profile_visible_to_lower
                    END,
                    lower_can_send = CASE
                        WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.higher_can_send
                    END
                WHERE pair.room_id = \(bind: roomID)
                  AND (SELECT count(*) FROM log_insert) = (SELECT count(*) FROM needed)
                RETURNING pair.room_id
            )
            SELECT EXISTS (SELECT 1 FROM profile) AS profile_exists,
                   (SELECT count(*) FROM needed) AS needed_count,
                   (SELECT count(*) FROM log_insert WHERE projection_kind = 'direct_room_profile') AS profile_inserted_count,
                   (SELECT count(*) FROM log_insert) AS inserted_count,
                   (SELECT count(*) FROM pair_update) AS pair_count
            """).first(decoding: DirectRoomProfileMutationRow.self),
              mutation.profileExists,
              mutation.insertedCount == mutation.neededCount,
              mutation.pairCount == 1,
              (0...2).contains(mutation.neededCount),
              (0...1).contains(mutation.profileInsertedCount),
              mutation.profileInsertedCount <= mutation.insertedCount,
              (0...1).contains(mutation.insertedCount - mutation.profileInsertedCount)
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return .init(
            senderCapabilityInserted: mutation.insertedCount - mutation.profileInsertedCount == 1,
            recipientProfileInserted: mutation.profileInsertedCount == 1
        )
    }

    /// Room locks are already held by each admission path. Check the fixed
    /// direct pair independently of any per-user delivery work.
    private func assertDirectMemberships(roomIDs: [UUID], sql: any SQLDatabase) async throws {
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

    private func persist(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        mediaPresentations: [V2MediaPresentation],
        messageProjectionState: V2StoredMessageProjectionState,
        room: RoomRow,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let roomID = try uuid(message.roomID)
        if room.kind == "direct" { try await assertDirectMemberships(roomIDs: [roomID], sql: sql) }
        let messageID = try uuid(message.messageID)
        let eventID = try uuid(writeSet.eventID)
        let senderID = try uuid(message.senderUserID)
        let clientMessageID = try uuid(message.clientMessageID)
        let roomSequence = try signed(message.roomSequence)
        let timelineSequence = try signed(message.timelineSequence)
        let roomAdmission = writeSet.nextRoomState.admission
        guard let shardLease = writeSet.nextShardState.lease else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let shardLeaseID = try uuid(shardLease.id)
        let shardLeaseGeneration = try signed(shardLease.generation)

        guard let mediaJSON = String(data: try JSONEncoder().encode(message.media.map { $0.mediaID.rawValue }), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let entitiesJSON = String(data: try JSONEncoder().encode(message.entities), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let replyToMessageID = message.replyTo?.messageID.rawValue ?? ""
        let forwardedFromMessageID = try command.forwardedFrom.map { try uuid($0.messageID) }
        let forwardedFromUserID = try command.forwardedFrom.map { try uuid($0.senderUserID) }
        let mediaPresentationWire: [[String: Any]] = mediaPresentations.map { presentation in
            [
                "media_id": presentation.mediaID.rawValue,
                "kind": presentation.kind.rawValue,
                "content_type": presentation.contentType,
                "byte_count": presentation.byteCount,
            ]
        }
        guard let mediaPresentationsJSON = String(data: try JSONSerialization.data(withJSONObject: mediaPresentationWire), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let mentionedUserIDs = message.mentions.compactMap { target -> String? in
            guard case .user(let userID) = target else { return nil }
            return userID.rawValue
        }
        guard let mentionedUsersJSON = String(data: try JSONEncoder().encode(mentionedUserIDs), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let references = try message.media.enumerated().map { ordinal, reference in
            OrderedMediaReferenceInput(ordinal: ordinal, mediaID: try uuid(reference.mediaID))
        }
        let referencesJSON = try roomWriteJSON(references)
        let mentions = try message.mentions.enumerated().map { ordinal, target in
            switch target {
            case .user(let userID):
                return OrderedMentionInput(
                    ordinal: ordinal,
                    mentionKind: "user",
                    mentionedUserID: try uuid(userID)
                )
            case .everyone:
                return OrderedMentionInput(
                    ordinal: ordinal,
                    mentionKind: "everyone",
                    mentionedUserID: nil
                )
            }
        }
        let mentionsJSON = try roomWriteJSON(mentions)

        let usesDirectRoomLog = room.kind == "direct"
        if usesDirectRoomLog {
            try await persistRoomLogMessage(
                writeSet,
                command: command,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                shardLeaseID: shardLeaseID,
                shardLeaseGeneration: shardLeaseGeneration,
                entitiesJSON: entitiesJSON,
                mediaJSON: mediaJSON,
                mediaPresentationsJSON: mediaPresentationsJSON,
                mentionedUsersJSON: mentionedUsersJSON,
                referencesJSON: referencesJSON,
                mentionsJSON: mentionsJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                persistsRoomAdmission: true,
                sql: sql
            )
            return
        }

        try await sql.raw("""
            UPDATE im_v2.rooms SET room_sequence = \(bind: roomSequence), timeline_sequence = \(bind: timelineSequence)
            WHERE room_id = \(bind: roomID)
            """).run()
        let mentionTargets = hybridMentionTargetIDs(message.mentions, excluding: senderID)
        try await sql.raw("""
            UPDATE im_v2.room_admission
            SET command_window_used = \(bind: roomAdmission.commandWindow.used),
                shard_lease_id = \(bind: shardLeaseID),
                shard_lease_generation = \(bind: shardLeaseGeneration)
            WHERE room_id = \(bind: roomID)
            """).run()
        try await sql.raw("""
            WITH message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence, sender_user_id, client_message_id, text_body, rich_entities, reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id, created_at)
            VALUES
                (\(bind: messageID), \(bind: roomID), \(bind: roomSequence), \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID), \(bind: message.text), \(bind: entitiesJSON)::jsonb, NULLIF(\(bind: replyToMessageID), '')::uuid, \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID), \(bind: message.createdAt))
            RETURNING *
            )
            \(v2SendCompletionCTE(fingerprint: command.fingerprint, eventID: eventID, acceptedMembershipRevision: room.membershipRevision, groupCapacityClass: room.kind == "group" ? room.capacityClass : nil))
            SELECT count(*) FROM completion_insert
            """).run()
        if contentReviewMode.enqueuesJobs {
            // This outbox row commits with the message. A process crash between
            // acceptance and worker wake therefore cannot create an unreviewed
            // blind spot; leases recover the work without touching the hot send
            // path again.
            try await sql.raw("""
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                VALUES (\(bind: messageID), \(bind: roomID), 1, 'pending', \(bind: message.createdAt))
                """).run()
        }
        if !message.media.isEmpty {
            try await sql.raw("""
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT \(bind: messageID), reference.media_id, reference.ordinal, \(bind: message.createdAt)
                FROM jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                """).run()
        }
        if !message.mentions.isEmpty {
            try await sql.raw("""
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT \(bind: messageID), mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                """).run()
        }
        try await sql.raw("""
            INSERT INTO im_v2.room_events
                (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
            VALUES
                (\(bind: eventID), \(bind: roomID), \(bind: roomSequence), 'message.accepted', \(bind: senderID),
                 jsonb_build_object(
                    'event_type', 'message.accepted',
                    'message_id', \(bind: messageID.uuidString),
                    'room_id', \(bind: roomID.uuidString),
                    'room_sequence', \(bind: roomSequence),
                    'timeline_sequence', \(bind: timelineSequence),
                    'sender_user_id', \(bind: senderID.uuidString),
                    'text', \(bind: message.text),
                    'media_ids', \(bind: mediaJSON)::jsonb,
                    'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                    'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                    'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                    'entities', \(bind: entitiesJSON)::jsonb,
                    'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                    'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                    'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                    'message_revision', 1,
                    'server_created_at_ms', \(bind: try roomWriteProjectionMilliseconds(message.createdAt)
                 )),
                 \(bind: room.membershipRevision), \(bind: message.createdAt))
            """).run()
        // Mentions wake clients; content is recovered from this room event.
        try await v2EnqueueMentionPushWakes(
            sourceEventID: eventID,
            mentionedUserIDs: mentionTargets,
            now: message.createdAt,
            sql: sql
        )
        try await PostgresV2MessageProjectionStateRepository().persist(
            messageProjectionState,
            storage: .roomEvent,
            sql: sql
        )
    }

    /// 持久化规范的单聊房间事件，而不为其两名成员各制造一份多余的持久副本。
    ///
    /// 该事件及其受修订围栏保护的成员校验就是恢复契约；
    /// 前台唤醒刻意留在此事务之外，它只是一种延迟优化。
    ///
    /// - Parameters:
    ///   - writeSet: 消息接受事务写入集合。
    ///   - command: 发送消息命令。
    ///   - room: 目标房间行。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 影响行数不符或写入失败时抛出。
    private func persistRoomLogMessage(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        shardLeaseID: UUID,
        shardLeaseGeneration: Int64,
        entitiesJSON: String,
        mediaJSON: String,
        mediaPresentationsJSON: String,
        mentionedUsersJSON: String,
        referencesJSON: String,
        mentionsJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        persistsRoomAdmission: Bool,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let admission = writeSet.nextRoomState.admission
        // The load test's dominant shape is a plain direct message. Keep the
        // rich path below intact for review/media/mentions, but do not make a
        // plain message pay for three empty data-modifying CTEs or rewrite
        // room-admission fields that cannot change in direct room-log mode.
        if !contentReviewMode.enqueuesJobs,
           message.media.isEmpty,
           message.mentions.isEmpty {
            try await persistPlainRoomLogMessage(
                message: message,
                fingerprint: command.fingerprint,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                commandWindowUsed: admission.commandWindow.used,
                entitiesJSON: entitiesJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                persistsRoomAdmission: persistsRoomAdmission,
                sql: sql
            )
            return
        }
        guard let mutation = try await sql.raw("""
            WITH room_update AS (
                UPDATE im_v2.rooms
                SET room_sequence = \(bind: roomSequence),
                    timeline_sequence = \(bind: timelineSequence)
                WHERE room_id = \(bind: roomID)
                RETURNING room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = \(bind: admission.commandWindow.used),
                    shard_lease_id = \(bind: shardLeaseID),
                    shard_lease_generation = \(bind: shardLeaseGeneration)
                FROM room_update
                WHERE admission.room_id = room_update.room_id
                  AND \(bind: persistsRoomAdmission)
                RETURNING admission.room_id
            ), admission_passthrough AS (
                SELECT room_id FROM room_update
                WHERE NOT \(bind: persistsRoomAdmission)
            ), admission_gate AS (
                SELECT room_id FROM admission_update
                UNION ALL
                SELECT room_id FROM admission_passthrough
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at)
                SELECT \(bind: messageID), admission_gate.room_id, \(bind: roomSequence),
                       \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID),
                       \(bind: message.text), \(bind: entitiesJSON)::jsonb,
                       NULLIF(\(bind: replyToMessageID), '')::uuid,
                       \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID),
                       \(bind: message.createdAt)
                FROM admission_gate
                RETURNING *
            ), review_insert AS (
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                SELECT message_id, room_id, 1, 'pending', \(bind: message.createdAt)
                FROM message_insert
                WHERE \(bind: contentReviewMode.enqueuesJobs)
                RETURNING message_id
            ), media_insert AS (
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT message_insert.message_id, reference.media_id, reference.ordinal,
                       \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                RETURNING message_id
            ), mention_insert AS (
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT message_insert.message_id, mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                RETURNING message_id
            ), event_insert AS (
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                     committed_membership_revision, created_at)
                SELECT \(bind: eventID), message_insert.room_id, \(bind: roomSequence),
                       'message.accepted', \(bind: senderID),
                       jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', \(bind: messageID.uuidString),
                           'room_id', \(bind: roomID.uuidString),
                           'room_sequence', \(bind: roomSequence),
                           'timeline_sequence', \(bind: timelineSequence),
                           'sender_user_id', \(bind: senderID.uuidString),
                           'text', \(bind: message.text),
                           'media_ids', \(bind: mediaJSON)::jsonb,
                           'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                           'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                           'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                           'entities', \(bind: entitiesJSON)::jsonb,
                           'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                           'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                           'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                           'message_revision', 1,
                           'server_created_at_ms', \(bind: try roomWriteProjectionMilliseconds(message.createdAt))
                       ),
                       \(bind: room.membershipRevision), \(bind: message.createdAt)
                FROM message_insert
                RETURNING event_id
            )
            \(v2SendCompletionCTE(fingerprint: command.fingerprint, eventID: eventID, acceptedMembershipRevision: room.membershipRevision, groupCapacityClass: room.kind == "group" ? room.capacityClass : nil))
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_gate) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   (SELECT count(*) FROM review_insert) AS review_count,
                   (SELECT count(*) FROM media_insert) AS media_count,
                   (SELECT count(*) FROM mention_insert) AS mention_count,
                   (SELECT count(*) FROM event_insert) AS event_count
            """).first(decoding: RoomLogMessageMutationRow.self),
              mutation.roomCount == 1,
              mutation.admissionCount == 1,
              mutation.messageCount == 1,
              mutation.reviewCount == (contentReviewMode.enqueuesJobs ? 1 : 0),
              mutation.mediaCount == Int64(message.media.count),
              mutation.mentionCount == Int64(message.mentions.count),
              mutation.eventCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// 把旧版的单命令路径适配到有序微批所使用的同一套集合式追加 SQL。
    ///
    /// 未来的批次只有在锁定并预校验过每个不同房间之后，才会传入多于一个输入。
    ///
    /// - Parameters:
    ///   - message: 已接受消息草稿。
    ///   - fingerprint: 请求指纹。
    ///   - room: 目标房间行。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 写入失败时抛出。
    private func persistPlainRoomLogMessage(
        message: V2AcceptedMessageDraft,
        fingerprint: V2SendMessageFingerprint,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        commandWindowUsed: Int,
        entitiesJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        persistsRoomAdmission: Bool,
        sql: any SQLDatabase
    ) async throws {
        let replyToMessageUUID: UUID?
        if replyToMessageID.isEmpty {
            replyToMessageUUID = nil
        } else {
            guard let parsed = UUID(uuidString: replyToMessageID) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            replyToMessageUUID = parsed
        }
        try await persistPlainRoomLogMessages(
            inputs: [.init(
                ordinal: 0,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                persistsRoomAdmission: persistsRoomAdmission,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                commandWindowUsed: commandWindowUsed,
                text: message.text,
                entities: message.entities,
                replyToMessageID: replyToMessageUUID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                membershipRevision: room.membershipRevision,
                fingerprint: fingerprint,
                createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(message.createdAt)
            )],
            sql: sql
        )
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
            // A direct pair is unique by design, and this batch already has
            // one command per room. Keep the assertion explicit because the
            // upsert below must not consume two quota units for one logical
            // pair if that invariant ever changes.
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

    /// 用单条语句持久化紧凑的混合群组已接受事件。
    ///
    /// 消息行同时是规范正文与不可变的已接受事件身份。
    /// 房间日志读取方已将这种表示与旧版 `room_events` 合并，
    /// 且语句触发器会发出同样的合并式持久唤醒。
    /// 零目标的终态扇出计划不携带可执行工作；
    /// 修订为一的投影状态可以无损推导，只有后续编辑/撤回需要时才会物化。
    /// 重复房间会保留每一条消息，而只有其最终输入会推进可变游标与房间准入。
    ///
    /// - Parameters:
    ///   - prepared: 已准备的混合群组追加。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 影响行数不符或写入失败时抛出。
    private func persistPlainHybridGroupMessages(
        _ prepared: [PreparedPlainHybridGroupAppend],
        sql: any SQLDatabase
    ) async throws {
        guard !prepared.isEmpty else { return }
        let inputs = prepared.map(\.input)
        guard Set(inputs.map(\.messageID)).count == inputs.count,
              Set(inputs.map(\.eventID)).count == inputs.count
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let expected = Int64(inputs.count)
        let expectedRooms = Int64(Set(inputs.map(\.roomID)).count)
        // The production PostgreSQL path binds typed arrays to a named
        // statement. The former JSON recordset encoded the complete batch in
        // Swift, parsed it again in PostgreSQL and replanned this invariant
        // write graph for every transaction. Typed arrays retain the same
        // one-statement atomicity and cardinality fences while avoiding that
        // duplicate serialization work. Keep the JSON branch for SQL test
        // doubles that do not expose PostgresNIO connections.
        if let postgres = sql as? any PostgresDatabase {
            let statement = try PlainHybridGroupAppendStatement(inputs: inputs)
            let mutation = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let rows = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var result: PlainHybridGroupMutationRow?
                    for try await row in rows {
                        guard result == nil else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        result = row
                    }
                    return result
                }
            }.get()
            guard let mutation,
                  mutation.roomCount == expectedRooms,
                  mutation.admissionCount == expectedRooms,
                  mutation.messageCount == expected
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return
        }
        let inputJSON = try roomWriteJSON(inputs)
        guard let mutation = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.message_id,
                       (input.fingerprint->>'version')::smallint AS fingerprint_version,
                       decode(input.fingerprint->>'digest', 'base64') AS request_fingerprint,
                       input.event_id, input.sender_id,
                       input.client_message_id, input.room_sequence,
                       input.timeline_sequence, input.membership_revision,
                       input.command_window_used,
                       input.shard_lease_id, input.shard_lease_generation,
                       input.text_body, input.rich_entities,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    message_id uuid,
                    event_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    room_sequence bigint,
                    timeline_sequence bigint,
                    membership_revision bigint,
                    command_window_used bigint,
                    shard_lease_id uuid,
                    shard_lease_generation bigint,
                    text_body text,
                    rich_entities jsonb,
                    fingerprint jsonb,
                    created_at_postgres_microseconds bigint
                )
            ), final_room_input AS MATERIALIZED (
                SELECT DISTINCT ON (room_id) *
                FROM input
                ORDER BY room_id, ordinal DESC
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = input.room_sequence,
                    timeline_sequence = input.timeline_sequence
                FROM final_room_input AS input
                WHERE room.room_id = input.room_id
                RETURNING room.room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = input.command_window_used,
                    shard_lease_id = input.shard_lease_id,
                    shard_lease_generation = input.shard_lease_generation
                FROM final_room_input AS input
                JOIN room_update ON room_update.room_id = input.room_id
                WHERE admission.room_id = input.room_id
                RETURNING admission.room_id
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence,
                     sender_user_id, client_message_id, text_body,
                     rich_entities, created_at, accepted_event_id,
                     accepted_event_storage, accepted_membership_revision)
                SELECT input.message_id, input.room_id, input.room_sequence,
                       input.timeline_sequence, input.sender_id,
                       input.client_message_id, input.text_body,
                       input.rich_entities, input.created_at, CASE WHEN input.room_sequence = input.timeline_sequence THEN input.event_id END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN input.membership_revision END
                FROM input
                JOIN admission_update ON admission_update.room_id = input.room_id
                RETURNING *
            )
            \(unsafeRaw: v2HybridGroupSendCompletionCTE)
            SELECT (SELECT count(*) FROM room_update)::bigint AS room_count,
                   (SELECT count(*) FROM admission_update)::bigint AS admission_count,
                   (SELECT count(*) FROM message_insert)::bigint AS message_count
            """).first(decoding: PlainHybridGroupMutationRow.self),
              mutation.roomCount == expectedRooms,
              mutation.admissionCount == expectedRooms,
              mutation.messageCount == expected
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
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
    private func persistPlainRoomLogMessages(
        inputs: [PlainRoomLogMessageInput],
        sql: any SQLDatabase
    ) async throws {
        guard !inputs.isEmpty,
              Set(inputs.map(\.messageID)).count == inputs.count,
              Set(inputs.map(\.eventID)).count == inputs.count,
              inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await assertDirectMemberships(roomIDs: inputs.map(\.roomID), sql: sql)
        let inputsJSON = try roomWriteJSON(inputs)
        let expectedCount = Int64(inputs.count)
        let expectedRoomCount = Int64(Set(inputs.map(\.roomID)).count)
        guard let mutation = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.message_id,
                       (input.fingerprint->>'version')::smallint AS fingerprint_version,
                       decode(input.fingerprint->>'digest', 'base64') AS request_fingerprint,
                       input.event_id, input.sender_id, input.client_message_id,
                       input.room_sequence, input.timeline_sequence,
                       input.command_window_used, input.persists_room_admission,
                       input.text_body,
                       input.rich_entities, input.reply_to_message_id,
                       input.forwarded_from_message_id,
                       input.forwarded_from_user_id,
                       input.membership_revision,
                       input.created_at_postgres_microseconds,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM jsonb_to_recordset(\(bind: inputsJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    message_id uuid,
                    event_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    room_sequence bigint,
                    timeline_sequence bigint,
                    command_window_used bigint,
                    persists_room_admission boolean,
                    text_body text,
                    rich_entities jsonb,
                    reply_to_message_id uuid,
                    forwarded_from_message_id uuid,
                    forwarded_from_user_id uuid,
                    membership_revision bigint,
                    fingerprint jsonb,
                    created_at_postgres_microseconds bigint
                )
            ), final_room_input AS MATERIALIZED (
                SELECT DISTINCT ON (room_id) *
                FROM input
                ORDER BY room_id, ordinal DESC
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = input.room_sequence,
                    timeline_sequence = input.timeline_sequence
                FROM final_room_input AS input
                WHERE room.room_id = input.room_id
                RETURNING room.room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = input.command_window_used
                FROM final_room_input AS input
                JOIN room_update ON room_update.room_id = input.room_id
                WHERE admission.room_id = input.room_id
                  AND input.persists_room_admission
                RETURNING admission.room_id
            ), admission_passthrough AS (
                SELECT room_update.room_id FROM room_update
                JOIN final_room_input AS input ON input.room_id = room_update.room_id
                WHERE NOT input.persists_room_admission
            ), admission_gate AS (
                SELECT room_id FROM admission_update
                UNION ALL
                SELECT room_id FROM admission_passthrough
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at,
                     accepted_event_id, accepted_event_storage,
                     accepted_membership_revision)
                SELECT input.message_id, input.room_id, input.room_sequence,
                       input.timeline_sequence, input.sender_id,
                       input.client_message_id, input.text_body,
                       input.rich_entities, input.reply_to_message_id,
                       input.forwarded_from_message_id,
                       input.forwarded_from_user_id, input.created_at,
                       CASE WHEN input.room_sequence = input.timeline_sequence THEN input.event_id END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN input.membership_revision END
                FROM input
                JOIN admission_gate ON admission_gate.room_id = input.room_id
                RETURNING *
            )
            \(unsafeRaw: v2DirectRoomLogSendCompletionCTE)
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_gate) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   0::bigint AS review_count,
                   0::bigint AS media_count,
                   0::bigint AS mention_count,
                   -- A plain direct accepted event is now materialized by
                   -- the message row itself.  Keep this cardinality fence so
                   -- callers still reject a partial set append.
                   (SELECT count(*) FROM message_insert) AS event_count
            """).first(decoding: RoomLogMessageMutationRow.self),
              mutation.roomCount == expectedRoomCount,
              mutation.admissionCount == expectedRoomCount,
              mutation.messageCount == expectedCount,
              mutation.reviewCount == 0,
              mutation.mediaCount == 0,
              mutation.mentionCount == 0,
              mutation.eventCount == expectedCount
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
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
        guard let postgres = sql as? any PostgresDatabase,
              ordered.count == acquisitions.count,
              !ordered.isEmpty
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        let inputs = try zip(ordered, acquisitions).map { item, acquisition in
            guard case .granted(_, let effectiveShardState) = acquisition,
                  let lease = effectiveShardState.lease,
                  let leaseID = UUID(uuidString: lease.id.rawValue),
                  let generation = Int64(exactly: lease.generation),
                  let snapshot = snapshotsByRoomID[item.roomID],
                  snapshot.capacityProfileID == item.request.capacityProfile.id
            else { throw V2AtomicRoomWriteBatchError(reason: .admissionState) }
            return try PlainHybridGroupConditionalAppendInput(
                item: item,
                snapshot: snapshot,
                expectedShardLeaseID: leaseID,
                expectedShardGeneration: generation
            )
        }
        let statement = try PlainHybridGroupConditionalAppendStatement(inputs: inputs)
        let allocations = try await postgres.withConnection { connection in
            connection.eventLoop.makeFutureWithTask {
                let rows = try await connection.execute(
                    statement,
                    logger: connection.logger
                )
                var decoded: [PlainHybridGroupConditionalAllocationRow] = []
                decoded.reserveCapacity(inputs.count)
                for try await row in rows {
                    decoded.append(row)
                }
                return decoded
            }
        }.get()
        guard allocations.count == ordered.count,
              zip(allocations, ordered).allSatisfy({ allocation, item in
                  allocation.ordinal == item.preflightOrdinal
                      && allocation.messageID
                        == (try? uuid(item.request.identifiers.messageID))
              })
        else {
            // The fast statement intentionally returns no per-user denial
            // detail. On its exceptional zero-write path, run the established
            // authoritative preflight while the operation/room locks are
            // still held so the batcher can isolate exactly the stale or
            // denied requests before scalar fallback. The steady accepted
            // path still remains one statement.
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
        let contexts = try await loadPlainHybridGroupBatchContexts(ordered, sql: sql)
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
        let expectedCount = Int64(inputs.count)
        // SQLKit's raw-query path uses an unnamed extended-protocol
        // statement. PostgreSQL therefore planned this large, invariant CTE
        // once per micro-batch; at 6k msg/s measured planning time was 2.57ms
        // against 5.81ms execution time. A named PostgresNIO statement keeps
        // the exact transaction and bind contract while allowing every pool
        // connection to reuse its plan. Retain the SQLKit branch for database
        // test doubles, but production PostgreSQL must take this branch.
        if let postgres = sql as? any PostgresDatabase {
            let statement = FastPlainDirectRoomLogAppendStatement(
                inputs: inputs,
                maximumStrangerMessages: strangerMessagePolicy.maximumMessagesPerWindow
            )
            let result = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let rows = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var decoded: [FastPlainDirectRoomLogAllocationRow] = []
                    decoded.reserveCapacity(inputs.count)
                    for try await row in rows {
                        decoded.append(row)
                    }
                    return decoded
                }
            }.get()
            guard result.count == Int(expectedCount),
                  result.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
            else {
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
            return result
        }
        let result = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT (input.ordinality - 1)::integer AS ordinal,
                       input.room_id, input.sender_id,
                       input.recipient_id, input.message_id, input.event_id,
                       input.client_message_id, input.fingerprint_version,
                       decode(input.request_fingerprint_base64, 'base64') AS request_fingerprint,
                       input.expected_membership_revision,
                       input.expected_direct_pair_revision,
                       input.expected_sender_policy_revision,
                       input.expected_recipient_policy_revision,
                       input.room_shard_id, input.capacity_profile_id,
                       input.expected_shard_lease_id,
                       input.expected_shard_generation,
                       input.requires_stranger_quota,
                       input.uses_room_admission_credits,
                       input.text_body, input.rich_entities_json::jsonb AS rich_entities,
                       input.created_at_postgres_microseconds, input.window_start,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM unnest(
                    \(bind: inputs.map(\.roomID))::uuid[],
                    \(bind: inputs.map(\.senderID))::uuid[],
                    \(bind: inputs.map(\.recipientID))::uuid[],
                    \(bind: inputs.map(\.messageID))::uuid[],
                    \(bind: inputs.map(\.eventID))::uuid[],
                    \(bind: inputs.map(\.clientMessageID))::uuid[],
                    \(bind: inputs.map(\.expectedMembershipRevision))::bigint[],
                    \(bind: inputs.map(\.expectedDirectPairRevision))::bigint[],
                    \(bind: inputs.map(\.expectedSenderPolicyRevision))::bigint[],
                    \(bind: inputs.map(\.expectedRecipientPolicyRevision))::bigint[],
                    \(bind: inputs.map(\.roomShardID))::text[],
                    \(bind: inputs.map(\.capacityProfileID))::text[],
                    \(bind: inputs.map(\.expectedShardLeaseID))::uuid[],
                    \(bind: inputs.map(\.expectedShardGeneration))::bigint[],
                    \(bind: inputs.map(\.requiresStrangerQuota))::boolean[],
                    \(bind: inputs.map(\.usesRoomAdmissionCredits))::boolean[],
                    \(bind: inputs.map(\.text))::text[],
                    \(bind: inputs.map(\.entitiesJSON))::text[],
                    \(bind: inputs.map(\.createdAtPostgresMicroseconds))::bigint[],
                    \(bind: inputs.map(\.windowStart))::timestamptz[],
                    \(bind: inputs.map { Int16($0.fingerprint.version) })::smallint[],
                    \(bind: inputs.map { $0.fingerprint.digest.base64EncodedString() })::text[]
                ) WITH ORDINALITY AS input(
                    room_id, sender_id, recipient_id, message_id, event_id,
                    client_message_id, expected_membership_revision,
                    expected_direct_pair_revision, expected_sender_policy_revision,
                    expected_recipient_policy_revision, room_shard_id,
                    capacity_profile_id, expected_shard_lease_id,
                    expected_shard_generation, requires_stranger_quota,
                    uses_room_admission_credits, text_body, rich_entities_json,
                    created_at_postgres_microseconds, window_start, fingerprint_version, request_fingerprint_base64, ordinality
                )
            ), locked_room AS MATERIALIZED (
                SELECT input.*, room.room_sequence, room.timeline_sequence,
                       room.membership_revision, room.room_kind,
                       room.room_shard_id AS actual_room_shard_id,
                       room.capacity_profile_id AS actual_capacity_profile_id,
                       room.frozen_at
                FROM input
                JOIN im_v2.rooms AS room ON room.room_id = input.room_id
                ORDER BY room.room_id
                FOR UPDATE OF room
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM im_v2.message_send_completions AS message
                    WHERE message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                      AND message.client_message_id = room.client_message_id
                )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM im_v2.direct_message_denials AS denial
                    WHERE denial.sender_user_id = room.sender_id
                  AND denial.room_id = room.room_id
                      AND denial.client_message_id = room.client_message_id
                )
            ), locked_membership AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = room.sender_id
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                WHERE membership.role IN ('owner', 'admin', 'member')
                  AND NOT EXISTS (
                      SELECT 1
                      FROM im_v2.room_member_mutes AS mute
                      WHERE mute.room_id = room.room_id
                        AND mute.user_id = room.sender_id
                        AND mute.mute_until > room.created_at
                  )
                FOR UPDATE OF membership
            ), locked_pair AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_membership AS membership ON membership.ordinal = room.ordinal
                JOIN im_v2.direct_room_pairs AS pair
                  ON pair.room_id = room.room_id
                 AND ((pair.lower_user_id = room.sender_id
                       AND pair.higher_user_id = room.recipient_id)
                      OR (pair.higher_user_id = room.sender_id
                          AND pair.lower_user_id = room.recipient_id))
                 AND pair.direct_policy_revision = room.expected_direct_pair_revision
                WHERE COALESCE((
                    SELECT count(*) = 2
                        AND bool_and(member.user_id IN (pair.lower_user_id, pair.higher_user_id))
                    FROM (
                        SELECT user_id FROM im_v2.room_memberships
                        WHERE room_id = room.room_id
                          AND joined_revision <= room.membership_revision
                          AND (left_revision IS NULL OR left_revision > room.membership_revision)
                        LIMIT 3
                    ) AS member
                ), FALSE)
                FOR UPDATE OF pair
            ), locked_policy_versions AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_pair AS pair ON pair.ordinal = room.ordinal
                JOIN im_v2.user_direct_send_policy_versions AS sender_version
                  ON sender_version.user_id = room.sender_id
                 AND sender_version.revision = room.expected_sender_policy_revision
                JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                  ON recipient_version.user_id = room.recipient_id
                 AND recipient_version.revision = room.expected_recipient_policy_revision
                -- Policy mutations update these revision rows.  `FOR SHARE`
                -- (not `FOR KEY SHARE`) makes this statement serialize with
                -- those non-key updates, so an accepted append is ordered
                -- wholly before or wholly after a permission change.
                FOR SHARE OF sender_version, recipient_version
            ), locked_active_profiles AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_policy_versions AS policy ON policy.ordinal = room.ordinal
                JOIN im_v2.public_user_profiles AS sender_profile
                  ON sender_profile.user_id = room.sender_id
                 AND sender_profile.state = 'active'
                JOIN im_v2.public_user_profiles AS recipient_profile
                  ON recipient_profile.user_id = room.recipient_id
                 AND recipient_profile.state = 'active'
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM im_v2.account_disables AS disabled
                    WHERE disabled.user_id = room.sender_id
                )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM im_v2.account_disables AS disabled
                    WHERE disabled.user_id = room.recipient_id
                )
                FOR SHARE OF sender_profile, recipient_profile
            ), locked_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.command_window_used,
                       admission.command_window_limit,
                       admission.shard_lease_id,
                       admission.shard_lease_generation
                FROM fresh_room AS room
                JOIN locked_active_profiles AS profile ON profile.ordinal = room.ordinal
                JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
                WHERE room.uses_room_admission_credits
                   OR admission.command_window_used < admission.command_window_limit
                FOR UPDATE OF admission
            ), validated_shard AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
                 AND shard.lease_id = room.expected_shard_lease_id
                 AND shard.generation = room.expected_shard_generation
                 AND shard.valid_until > room.created_at
                WHERE admission.shard_lease_id = room.expected_shard_lease_id
                  AND admission.shard_lease_generation = room.expected_shard_generation
                -- Do not retain a KEY SHARE lock here. The final aggregate
                -- reservation revalidates this lease and capacity with an
                -- UPDATE in the same transaction. Retaining shared locks and
                -- upgrading them there lets concurrent batches deadlock even
                -- when that UPDATE acquires different shard rows in a stable
                -- order. Any intervening lease change makes the reservation
                -- fail and rolls back every provisional write below.
            ), eligible AS MATERIALIZED (
                SELECT room.*
                FROM fresh_room AS room
                JOIN validated_shard AS shard ON shard.ordinal = room.ordinal
                WHERE room.room_kind = 'direct'
                  AND room.frozen_at IS NULL
                  AND room.membership_revision = room.expected_membership_revision
                  AND room.actual_room_shard_id = room.room_shard_id
                  AND room.actual_capacity_profile_id = room.capacity_profile_id
            ), stranger_quota AS (
                INSERT INTO im_v2.stranger_message_windows
                    (sender_user_id, recipient_user_id, window_started_at, message_count)
                SELECT eligible.sender_id, eligible.recipient_id,
                       eligible.created_at, 1
                FROM eligible
                WHERE eligible.requires_stranger_quota
                ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
                SET window_started_at = CASE
                        WHEN im_v2.stranger_message_windows.window_started_at
                             <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                        THEN EXCLUDED.window_started_at
                        ELSE im_v2.stranger_message_windows.window_started_at
                    END,
                    message_count = CASE
                        WHEN im_v2.stranger_message_windows.window_started_at
                             <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                        THEN 1
                        ELSE im_v2.stranger_message_windows.message_count + 1
                    END
                WHERE im_v2.stranger_message_windows.window_started_at
                          <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                   OR im_v2.stranger_message_windows.message_count
                          < \(bind: strangerMessagePolicy.maximumMessagesPerWindow)
                RETURNING sender_user_id, recipient_user_id
            ), quota_gate AS MATERIALIZED (
                SELECT eligible.*
                FROM eligible
                WHERE NOT eligible.requires_stranger_quota
                UNION ALL
                SELECT eligible.*
                FROM eligible
                JOIN stranger_quota AS quota
                  ON quota.sender_user_id = eligible.sender_id
                 AND quota.recipient_user_id = eligible.recipient_id
                WHERE eligible.requires_stranger_quota
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = room.room_sequence + 1,
                    timeline_sequence = room.timeline_sequence + 1
                FROM quota_gate
                WHERE room.room_id = quota_gate.room_id
                  AND room.room_sequence < \(bind: Int64.max)
                  AND room.timeline_sequence < \(bind: Int64.max)
                RETURNING room.room_id, room.room_sequence,
                          room.timeline_sequence
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = admission.command_window_used + 1
                FROM eligible
                JOIN room_update ON room_update.room_id = eligible.room_id
                WHERE admission.room_id = eligible.room_id
                  AND NOT eligible.uses_room_admission_credits
                RETURNING admission.room_id
            ), admission_gate AS (
                SELECT room_update.room_id
                FROM room_update
                JOIN eligible ON eligible.room_id = room_update.room_id
                WHERE eligible.uses_room_admission_credits
                UNION ALL
                SELECT room_id FROM admission_update
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence,
                     sender_user_id, client_message_id, text_body,
                     rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id,
                     created_at, accepted_event_id, accepted_event_storage,
                     accepted_membership_revision)
                SELECT eligible.message_id, eligible.room_id,
                       room_update.room_sequence,
                       room_update.timeline_sequence,
                       eligible.sender_id, eligible.client_message_id,
                       eligible.text_body, eligible.rich_entities, NULL,
                       NULL, NULL, eligible.created_at, CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.event_id END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.expected_membership_revision END
                FROM eligible
                JOIN room_update ON room_update.room_id = eligible.room_id
                JOIN admission_gate ON admission_gate.room_id = eligible.room_id
                RETURNING *
            )
            \(unsafeRaw: v2FastDirectRoomLogSendCompletionCTE)
            SELECT input.ordinal, room_update.room_sequence,
                   room_update.timeline_sequence
            FROM input
            JOIN room_update ON room_update.room_id = input.room_id
            JOIN admission_gate ON admission_gate.room_id = input.room_id
            JOIN message_insert ON message_insert.message_id = input.message_id
            ORDER BY input.ordinal
            """).all(decoding: FastPlainDirectRoomLogAllocationRow.self)
        guard result.count == Int(expectedCount),
              result.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else {
            throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
        }
        return result
    }

    private func assertAvailableMedia(_ media: [V2MediaReference], authority: MessageMediaAcceptanceAuthority, now: Date, sql: any SQLDatabase) async throws -> [V2MediaPresentation] {
        guard !media.isEmpty else { return [] }
        guard Set(media).count == media.count else { throw V2MediaStoreError.invalidReferenceSet }
        let requested = try media.enumerated().map { ordinal, reference in
            OrderedMediaReferenceInput(ordinal: ordinal, mediaID: try uuid(reference.mediaID))
        }
        let authorization: SQLQueryString = switch authority {
        case .ownedBy(let ownerID):
            "media.owner_user_id = \(bind: ownerID)"
        case .forwardedFrom(let sourceMessageID):
            // The caller has locked and authorized this exact source/version
            // and its complete reference set. A later-hop sender need not own
            // the original asset; the active source reference is the grant.
            """
            EXISTS (
                SELECT 1 FROM im_v2.message_media_references AS source_reference
                WHERE source_reference.message_id = \(bind: sourceMessageID)
                  AND source_reference.media_id = media.media_id
                  AND source_reference.revoked_at IS NULL
            )
            """
        }
        let requestedJSON = try roomWriteJSON(requested)
        let rows = try await sql.raw("""
            WITH requested AS (
                SELECT ordinal, media_id
                FROM jsonb_to_recordset(\(bind: requestedJSON)::jsonb)
                     AS input(ordinal integer, media_id uuid)
            )
            SELECT requested.ordinal, media.media_id, media.content_type, media.byte_count
            FROM requested
            JOIN im_v2.media_objects AS media
              ON media.media_id = requested.media_id
             AND (\(authorization))
             AND media.state = 'available'
             AND media.expires_at > \(bind: now)
            -- Lock shared media in a canonical order so two concurrent sends
            -- cannot deadlock merely because their attachment order differs.
            ORDER BY media.media_id
            FOR UPDATE OF media
            """).all(decoding: OrderedMessageMediaPresentationRow.self)
        let orderedRows = rows.sorted { $0.ordinal < $1.ordinal }
        guard orderedRows.count == requested.count,
              orderedRows.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2MediaStoreError.mediaUnavailable }
        return try orderedRows.map { try $0.presentation }
    }

    private func assertMentionsAuthorized(_ mentions: [V2MentionTarget], roomID: UUID, membershipRevision: Int64, senderID: UUID, sql: any SQLDatabase) async throws {
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

    private func assertReplyTarget(_ replyTo: V2MessageReplyReference?, roomID: UUID, actorID: UUID, sql: any SQLDatabase) async throws {
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

private extension V2SendMessageAcceptanceResult {
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
private func roomWriteNextSequence(_ current: Int64) throws -> UInt64 {
    guard current >= 0, current < Int64.max else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return UInt64(current + 1)
}

private struct RoomRow: Decodable {
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let capacityClass: V2GroupCapacityClass
    /// 权威副本形态。群聊以它为准；单聊由部署开关决定，忽略本列。
    let frozenAt: Date?
    enum CodingKeys: String, CodingKey { case kind = "room_kind", roomShardID = "room_shard_id", roomSequence = "room_sequence", timelineSequence = "timeline_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class", frozenAt = "frozen_at" }

    func commandState(roomID: RoomID, admission: AdmissionRow) throws -> V2RoomCommandState {
        try .init(
            roomID: roomID,
            nextRoomSequence: roomWriteNextSequence(roomSequence),
            admission: admission.roomAdmissionState()
        )
    }

    /// 推进序号。
    ///
    /// 同一次原子追加中的每个同房间成员都看到预检的持久游标。
    /// 批次所有者会为后续成员分配连续的游标，
    /// 然后由那一次集合式追加把房间行改到最终值。
    /// 宁可拒绝溢出，也不让一个可观测的房间序号回绕。
    ///
    /// - Parameter offset: 需要推进的偏移量。
    /// - Returns: 推进后的写入集合。
    /// - Throws: 偏移为负或序号溢出时抛出。
    func advancingSequences(by offset: Int64) throws -> Self {
        guard offset >= 0,
              roomSequence <= Int64.max - offset,
              timelineSequence <= Int64.max - offset
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence + offset,
            timelineSequence: timelineSequence + offset,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            capacityClass: capacityClass,

            frozenAt: frozenAt
        )
    }
}

private func roomLogReduction(
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

private func hybridMentionTargetIDs(_ mentions: [V2MentionTarget], excluding senderID: UUID) -> [UUID] {
    Array(Set(mentions.compactMap { target -> UUID? in
        guard case .user(let userID) = target, let value = UUID(uuidString: userID.rawValue), value != senderID else { return nil }
        return value
    })).sorted { $0.uuidString < $1.uuidString }
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

private struct OrderedMediaReferenceInput: Encodable {
    let ordinal: Int
    let mediaID: UUID

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mediaID = "media_id"
    }
}

private struct OrderedMentionInput: Encodable {
    let ordinal: Int
    let mentionKind: String
    let mentionedUserID: UUID?

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mentionKind = "mention_kind"
        case mentionedUserID = "mentioned_user_id"
    }
}

/// 发送预检 CTE 的单行结果。
///
/// `locked_room` 始终存在；
/// 其他分组都是可选的，因为在其持久结果已经存在之后，
/// 幂等重放不得再获取全新发送的锁或做出策略决定。
private struct MessageAcceptanceContextRow: Decodable {
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let capacityClass: V2GroupCapacityClass
    let frozenAt: Date?
    let priorOperationCount: Int
    let priorOutcomeKind: String?
    let priorMessageID: UUID?
    let priorRoomID: UUID?
    let priorRoomSequence: Int64?
    let priorTimelineSequence: Int64?
    let priorSenderUserID: UUID?
    let priorClientMessageID: UUID?
    let priorFingerprintVersion: Int16?
    let priorRequestFingerprint: Data?
    let priorCreatedAt: Date?
    let priorSourceEventID: UUID?
    let priorAcceptedMembershipRevision: Int64?
    let priorDirectRecipientUserID: UUID?
    let priorDenialReason: String?
    let priorGroupCapacityClass: V2GroupCapacityClass?
    let roomEligibleMemberCount: Int?
    let roomCommandWindowLimit: Int?
    let roomCommandWindowUsed: Int?
                            let roomShardLeaseID: UUID?
    let roomShardLeaseGeneration: Int64?
    let shardLeaseID: UUID?
    let shardGeneration: Int64?
    let shardValidUntil: Date?
    let shardCommandWindowLimit: Int?
    let shardCommandWindowUsed: Int?
                            let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let recipientUserID: UUID?
    let directPolicyRevision: Int64?
    let senderPolicyRevision: Int64?
    let recipientPolicyRevision: Int64?
    let senderProfileVisibleToRecipient: Bool?
    let senderCanSend: Bool?
    let recipientIsActive: Bool?
    let blocked: Bool?
    let isFriend: Bool?
    let senderHasReplied: Bool?
    let recipientHasReplied: Bool?
    let allowsStrangers: Bool?
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case kind = "room_kind"
        case roomShardID = "room_shard_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case capacityProfileID = "capacity_profile_id"
        case capacityClass = "capacity_class"
        case frozenAt = "frozen_at"
        case priorOperationCount = "prior_operation_count"
        case priorOutcomeKind = "prior_outcome_kind"
        case priorMessageID = "prior_message_id"
        case priorRoomID = "prior_room_id"
        case priorRoomSequence = "prior_room_sequence"
        case priorTimelineSequence = "prior_timeline_sequence"
        case priorSenderUserID = "prior_sender_user_id"
        case priorClientMessageID = "prior_client_message_id"
        case priorFingerprintVersion = "prior_fingerprint_version"
        case priorRequestFingerprint = "prior_request_fingerprint"
        case priorCreatedAt = "prior_created_at"
        case priorSourceEventID = "prior_source_event_id"
        case priorAcceptedMembershipRevision = "prior_accepted_membership_revision"
        case priorDirectRecipientUserID = "prior_direct_recipient_user_id"
        case priorDenialReason = "prior_denial_reason"
        case priorGroupCapacityClass = "prior_group_capacity_class"
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"

        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"

        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
        case recipientUserID = "recipient_user_id"
        case directPolicyRevision = "direct_policy_revision"
        case senderPolicyRevision = "sender_policy_revision"
        case recipientPolicyRevision = "recipient_policy_revision"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case recipientIsActive = "recipient_is_active"
        case blocked
        case isFriend = "is_friend"
        case senderHasReplied = "sender_has_replied"
        case recipientHasReplied = "recipient_has_replied"
        case allowsStrangers = "allows_strangers"
        case senderAccountKind = "sender_account_kind"
        case senderAccountStatus = "sender_account_status"
        case senderAllowsServiceMessages = "sender_allows_service_messages"
        case recipientAccountKind = "recipient_account_kind"
        case recipientAccountStatus = "recipient_account_status"
        case recipientAllowsCustomerMessages = "recipient_allows_customer_messages"
    }

    var room: RoomRow {
        .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            capacityClass: capacityClass,

            frozenAt: frozenAt
        )
    }

    func existingOperation() throws -> ExistingMessageOperation? {
        guard let priorOutcomeKind else {
            guard priorMessageID == nil, priorRoomID == nil,
                  priorRoomSequence == nil, priorTimelineSequence == nil,
                  priorSenderUserID == nil, priorClientMessageID == nil,
                  priorFingerprintVersion == nil, priorRequestFingerprint == nil,
                  priorCreatedAt == nil,
                  priorSourceEventID == nil, priorAcceptedMembershipRevision == nil,
                  priorDirectRecipientUserID == nil,
                  priorDenialReason == nil, priorGroupCapacityClass == nil
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return nil
        }
        guard let priorRoomID, let priorTimelineSequence, let priorSenderUserID,
              let priorClientMessageID, let priorCreatedAt
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try MessageOperationReplayRow(
            outcomeKind: priorOutcomeKind,
            messageID: priorMessageID,
            roomID: priorRoomID,
            roomSequence: priorRoomSequence,
            timelineSequence: priorTimelineSequence,
            senderUserID: priorSenderUserID,
            clientMessageID: priorClientMessageID,
            fingerprintVersion: priorFingerprintVersion,
            requestFingerprint: priorRequestFingerprint,
            createdAt: priorCreatedAt,
            sourceEventID: priorSourceEventID,
            acceptedMembershipRevision: priorAcceptedMembershipRevision,
            directRecipientUserID: priorDirectRecipientUserID,
            denialReason: priorDenialReason,
            groupCapacityClass: priorGroupCapacityClass
        ).operation()
    }

    func admissionSnapshot() throws -> AdmissionSnapshotRow {
        guard let roomEligibleMemberCount, let roomCommandWindowLimit,
              let roomCommandWindowUsed, let roomShardLeaseID,
              let roomShardLeaseGeneration, let shardLeaseID,
              let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return .init(
            roomEligibleMemberCount: roomEligibleMemberCount,
            roomCommandWindowLimit: roomCommandWindowLimit,
            roomCommandWindowUsed: roomCommandWindowUsed,

            roomShardLeaseID: roomShardLeaseID,
            roomShardLeaseGeneration: roomShardLeaseGeneration,
            shardLeaseID: shardLeaseID,
            shardGeneration: shardGeneration,
            shardValidUntil: shardValidUntil,
            shardCommandWindowLimit: shardCommandWindowLimit,
            shardCommandWindowUsed: shardCommandWindowUsed,

            actorRole: actorRole,
            senderIsActive: senderIsActive,
            muted: muted
        )
    }

    func directPolicySnapshot() throws -> DirectMessagePolicySnapshotRow {
        guard let recipientUserID, let senderProfileVisibleToRecipient,
              let recipientIsActive, let blocked, let isFriend,
              let senderHasReplied, let recipientHasReplied, let allowsStrangers
        else { throw V2RoomWriteStoreError.actorNotEligible }
        return .init(
            recipientUserID: recipientUserID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

    func directPolicyCacheEntry() -> V2DirectSendPolicyCache.Entry? {
        guard kind == "direct",
              let recipientUserID, let directPolicyRevision,
              let senderPolicyRevision, let recipientPolicyRevision,
              let senderProfileVisibleToRecipient, let senderIsActive,
              let recipientIsActive,
              let blocked, let isFriend, let senderHasReplied, let recipientHasReplied,
              let allowsStrangers
        else { return nil }
        return .init(
            recipientID: recipientUserID,
            directPairRevision: directPolicyRevision,
            senderPolicyRevision: senderPolicyRevision,
            recipientPolicyRevision: recipientPolicyRevision,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            senderIsActive: senderIsActive,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

}

private struct AdmissionSnapshotRow: Decodable {
    let roomEligibleMemberCount: Int
    let roomCommandWindowLimit: Int
    let roomCommandWindowUsed: Int
                            let roomShardLeaseID: UUID
    let roomShardLeaseGeneration: Int64
    let shardLeaseID: UUID
    let shardGeneration: Int64
    let shardValidUntil: Date
    let shardCommandWindowLimit: Int
    let shardCommandWindowUsed: Int
                            let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?

    var room: AdmissionRow {
        .init(
            eligibleMemberCount: roomEligibleMemberCount,
            commandWindowLimit: roomCommandWindowLimit,
            commandWindowUsed: roomCommandWindowUsed,

            shardLeaseID: roomShardLeaseID,
            shardLeaseGeneration: roomShardLeaseGeneration
        )
    }

    var shard: ShardRow {
        .init(
            leaseID: shardLeaseID,
            generation: shardGeneration,
            validUntil: shardValidUntil,
            commandWindowLimit: shardCommandWindowLimit,
            commandWindowUsed: shardCommandWindowUsed)
    }

    enum CodingKeys: String, CodingKey {
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"

        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"

        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
    }
}

private struct AdmissionRow: Decodable {
    let eligibleMemberCount: Int
    let commandWindowLimit: Int
    let commandWindowUsed: Int
                            let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    enum CodingKeys: String, CodingKey {
        case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation"
    }
    func roomAdmissionState() throws -> RoomAdmissionState {
        try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed))
    }
}

private struct ShardRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    let commandWindowLimit: Int
    let commandWindowUsed: Int
                            enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used"
    }
    func admissionState() throws -> ShardAdmissionState {
        try .init(lease: .init(id: ShardAdmissionLeaseID(uuid: leaseID), generation: try unsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)))
    }
}

private enum LateShardAdmissionRejection: Error, Sendable {
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2CommandAdmissionUnavailableReason)
}

private struct ShardAdmissionMutationRow: Decodable {
    let applied: Int
}

private struct ShardAdmissionReservation: Sendable {
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

private struct RoomLogMessageMutationRow: Decodable {
    let roomCount: Int64
    let admissionCount: Int64
    let messageCount: Int64
    let reviewCount: Int64
    let mediaCount: Int64
    let mentionCount: Int64
    let eventCount: Int64

    enum CodingKeys: String, CodingKey {
        case roomCount = "room_count"
        case admissionCount = "admission_count"
        case messageCount = "message_count"
        case reviewCount = "review_count"
        case mediaCount = "media_count"
        case mentionCount = "mention_count"
        case eventCount = "event_count"
    }
}

private struct PlainHybridGroupMutationRow: Decodable {
    let roomCount: Int64
    let admissionCount: Int64
    let messageCount: Int64

    enum CodingKeys: String, CodingKey {
        case roomCount = "room_count"
        case admissionCount = "admission_count"
        case messageCount = "message_count"
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

private struct PlainHybridGroupBatchPreflightInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let nowPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
    }
}

/// 权威混合群组预检的具名、类型化数组形式。
///
/// 该语句刻意返回与 SQLKit 回退实现相同的 36 个持久字段。
/// 任何缓存权限布尔值都不会被接受为权威：
/// PostgreSQL 仍会锁定房间、准入行与发送者成员关系，
/// 并在事务内求值启用/禁言/角色权限状态。
private struct PlainHybridGroupBatchPreflightStatement: PostgresPreparedStatement {
    static let name = "im_v2_plain_hybrid_group_batch_preflight_v3"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT (input.ordinality - 1)::integer AS ordinal,
                   input.room_id, input.sender_id,
                   input.client_message_id, input.now_postgres_microseconds
            FROM unnest(
                $1::uuid[], $2::uuid[], $3::uuid[], $4::bigint[]
            ) WITH ORDINALITY AS input(
                room_id, sender_id, client_message_id, now_postgres_microseconds,
                ordinality
            )
        ), locked_room AS MATERIALIZED (
            SELECT input.ordinal, input.sender_id, input.client_message_id,
                   input.now_postgres_microseconds, room.room_kind,
                   room.room_shard_id, room.room_sequence,
                   room.timeline_sequence, room.membership_revision,
                   room.capacity_profile_id, room.capacity_class,
                   room.frozen_at, room.room_id
            FROM input
            JOIN im_v2.rooms AS room ON room.room_id = input.room_id
            ORDER BY room.room_id
            FOR UPDATE OF room
        ), prior_operation AS MATERIALIZED (
            SELECT room.ordinal
            FROM locked_room AS room
            JOIN im_v2.message_send_completions AS message
              ON message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
             AND message.client_message_id = room.client_message_id
        ), fresh_room AS MATERIALIZED (
            SELECT room.*
            FROM locked_room AS room
            WHERE NOT EXISTS (
                SELECT 1 FROM prior_operation AS prior
                WHERE prior.ordinal = room.ordinal
            )
        ), locked_admission AS MATERIALIZED (
            SELECT room.ordinal,
                   admission.eligible_member_count AS room_eligible_member_count,
                   admission.command_window_limit AS room_command_window_limit,
                   admission.command_window_used AS room_command_window_used,
                   admission.shard_lease_id AS room_shard_lease_id,
                   admission.shard_lease_generation AS room_shard_lease_generation,
                   shard.lease_id AS shard_lease_id,
                   shard.generation AS shard_generation,
                   shard.valid_until AS shard_valid_until,
                   shard.command_window_limit AS shard_command_window_limit,
                   shard.command_window_used AS shard_command_window_used
            FROM fresh_room AS room
            JOIN im_v2.room_admission AS admission
              ON admission.room_id = room.room_id
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = room.room_shard_id
             AND shard.capacity_profile_id = room.capacity_profile_id
            ORDER BY room.room_id
            FOR UPDATE OF admission
        ), locked_actor AS MATERIALIZED (
            SELECT room.ordinal, membership.role AS actor_role,
                   EXISTS (
                       SELECT 1
                       FROM im_v2.public_user_profiles AS profile
                       WHERE profile.user_id = room.sender_id
                         AND profile.state = 'active'
                         AND NOT EXISTS (
                             SELECT 1 FROM im_v2.account_disables AS disabled
                             WHERE disabled.user_id = profile.user_id
                         )
                   ) AS sender_is_active,
                   EXISTS (
                       SELECT 1 FROM im_v2.room_member_mutes AS mute
                       WHERE mute.room_id = room.room_id
                         AND mute.user_id = room.sender_id
                         AND mute.mute_until > ((TIMESTAMP '2000-01-01 00:00:00'
                             + (room.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (room.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC')
                   ) AS muted,
                   (
                       membership.role = 'owner'
                       OR EXISTS (
                           SELECT 1 FROM im_v2.group_role_permissions AS permission
                           WHERE permission.room_id = room.room_id
                             AND permission.role = membership.role
                             AND permission.permission = 'send_messages'
                       )
                       OR NOT EXISTS (
                           SELECT 1 FROM (SELECT room_id, role FROM im_v2.group_role_policies UNION ALL SELECT room_id, role FROM im_v2.group_role_permissions) AS operation
                           WHERE operation.room_id = room.room_id
                             AND operation.role = membership.role
                       )
                   ) AS allows_send_messages
            FROM fresh_room AS room
            JOIN locked_admission AS admission USING (ordinal)
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = room.room_id
             AND membership.user_id = room.sender_id
             AND membership.joined_revision <= room.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > room.membership_revision)
            ORDER BY room.room_id, membership.user_id
            FOR UPDATE OF membership
        )
        SELECT room.ordinal, room.room_kind, room.room_shard_id,
               room.room_sequence, room.timeline_sequence,
               room.membership_revision, room.capacity_profile_id,
               room.capacity_class, room.frozen_at,
               EXISTS (
                   SELECT 1 FROM prior_operation AS prior
                   WHERE prior.ordinal = room.ordinal
               ) AS has_prior_operation,
               admission.room_eligible_member_count,
               admission.room_command_window_limit,
               admission.room_command_window_used,
               admission.room_shard_lease_id,
               admission.room_shard_lease_generation,
               admission.shard_lease_id, admission.shard_generation,
               admission.shard_valid_until,
               admission.shard_command_window_limit,
               admission.shard_command_window_used,
               actor.actor_role, actor.sender_is_active, actor.muted,
               actor.allows_send_messages
        FROM locked_room AS room
        LEFT JOIN locked_admission AS admission USING (ordinal)
        LEFT JOIN locked_actor AS actor USING (ordinal)
        ORDER BY room.ordinal
        """

    typealias Row = PlainHybridGroupBatchPreflightRow

    let inputs: [PlainHybridGroupBatchPreflightInput]

    init(inputs: [PlainHybridGroupBatchPreflightInput]) throws {
        guard inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        self.inputs = inputs
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.nowPostgresMicroseconds))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        try .init(postgresRow: row)
    }
}

/// 顺序解码。
///
/// 其复杂度为 O(列数)，既不需要分配键控 Codable 容器，
/// 也无需为每个返回行执行 36 次字符串查找。
private struct PlainHybridGroupPreparedRowCursor {
    private var iterator: PostgresRow.Iterator

    init(_ row: PostgresRow) {
        iterator = row.makeIterator()
    }

    mutating func decode<T: PostgresDecodable>(_ type: T.Type = T.self) throws -> T {
        guard let cell = iterator.next() else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try cell.decode(type)
    }

    mutating func assertExhausted() throws {
        guard iterator.next() == nil else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }
}

private struct PlainHybridGroupBatchPreflightRow: Decodable {
    let ordinal: Int
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let capacityClass: V2GroupCapacityClass
    let frozenAt: Date?
    let hasPriorOperation: Bool
    let roomEligibleMemberCount: Int?
    let roomCommandWindowLimit: Int?
    let roomCommandWindowUsed: Int?
                            let roomShardLeaseID: UUID?
    let roomShardLeaseGeneration: Int64?
    let shardLeaseID: UUID?
    let shardGeneration: Int64?
    let shardValidUntil: Date?
    let shardCommandWindowLimit: Int?
    let shardCommandWindowUsed: Int?
                            let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let allowsSendMessages: Bool?

    init(postgresRow: PostgresRow) throws {
        var row = PlainHybridGroupPreparedRowCursor(postgresRow)
        ordinal = try row.decode()
        kind = try row.decode()
        roomShardID = try row.decode()
        roomSequence = try row.decode()
        timelineSequence = try row.decode()
        membershipRevision = try row.decode()
        capacityProfileID = try row.decode()
        let capacityClassValue: String = try row.decode()
        guard let capacityClass = V2GroupCapacityClass(rawValue: capacityClassValue) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        self.capacityClass = capacityClass
        frozenAt = try row.decode()
        hasPriorOperation = try row.decode()
        roomEligibleMemberCount = try row.decode()
        roomCommandWindowLimit = try row.decode()
        roomCommandWindowUsed = try row.decode()

        roomShardLeaseID = try row.decode()
        roomShardLeaseGeneration = try row.decode()
        shardLeaseID = try row.decode()
        shardGeneration = try row.decode()
        shardValidUntil = try row.decode()
        shardCommandWindowLimit = try row.decode()
        shardCommandWindowUsed = try row.decode()

        actorRole = try row.decode()
        senderIsActive = try row.decode()
        muted = try row.decode()
        allowsSendMessages = try row.decode()
        try row.assertExhausted()
    }

    /// 这是混合群组准入中最热的行。直接按列解码，
    /// 而不是为每条消息都构造一个通用的键控 Codable 容器。
    /// PostgreSQL 的类型校验与所有授权字段都保持不变，只有 Swift 的解码机制不同。
    ///
    /// - Parameter row: 待解码的数据库行。
    /// - Throws: 类型校验失败或列缺失时抛出。
    init(row: any SQLRow) throws {
        ordinal = try row.decode(column: "ordinal")
        kind = try row.decode(column: "room_kind")
        roomShardID = try row.decode(column: "room_shard_id")
        roomSequence = try row.decode(column: "room_sequence")
        timelineSequence = try row.decode(column: "timeline_sequence")
        membershipRevision = try row.decode(column: "membership_revision")
        capacityProfileID = try row.decode(column: "capacity_profile_id")
        capacityClass = try row.decode(column: "capacity_class")
        frozenAt = try row.decode(column: "frozen_at", as: Date?.self)
        hasPriorOperation = try row.decode(column: "has_prior_operation")
        roomEligibleMemberCount = try row.decode(
            column: "room_eligible_member_count",
            as: Int?.self
        )
        roomCommandWindowLimit = try row.decode(column: "room_command_window_limit", as: Int?.self)
        roomCommandWindowUsed = try row.decode(column: "room_command_window_used", as: Int?.self)

        roomShardLeaseID = try row.decode(column: "room_shard_lease_id", as: UUID?.self)
        roomShardLeaseGeneration = try row.decode(
            column: "room_shard_lease_generation",
            as: Int64?.self
        )
        shardLeaseID = try row.decode(column: "shard_lease_id", as: UUID?.self)
        shardGeneration = try row.decode(column: "shard_generation", as: Int64?.self)
        shardValidUntil = try row.decode(column: "shard_valid_until", as: Date?.self)
        shardCommandWindowLimit = try row.decode(column: "shard_command_window_limit", as: Int?.self)
        shardCommandWindowUsed = try row.decode(column: "shard_command_window_used", as: Int?.self)

        actorRole = try row.decode(column: "actor_role", as: String?.self)
        senderIsActive = try row.decode(column: "sender_is_active", as: Bool?.self)
        muted = try row.decode(column: "muted", as: Bool?.self)
        allowsSendMessages = try row.decode(column: "allows_send_messages", as: Bool?.self)
    }

    enum CodingKeys: String, CodingKey {
        case ordinal
        case kind = "room_kind"
        case roomShardID = "room_shard_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case capacityProfileID = "capacity_profile_id"
        case capacityClass = "capacity_class"
        case frozenAt = "frozen_at"
        case hasPriorOperation = "has_prior_operation"
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"

        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"

        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
        case allowsSendMessages = "allows_send_messages"
    }

    var room: RoomRow {
        .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            capacityClass: capacityClass,

            frozenAt: frozenAt
        )
    }

    func admissionSnapshot() throws -> AdmissionSnapshotRow {
        guard let roomEligibleMemberCount, let roomCommandWindowLimit,
              let roomCommandWindowUsed, let roomShardLeaseID,
              let roomShardLeaseGeneration, let shardLeaseID,
              let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            roomEligibleMemberCount: roomEligibleMemberCount,
            roomCommandWindowLimit: roomCommandWindowLimit,
            roomCommandWindowUsed: roomCommandWindowUsed,

            roomShardLeaseID: roomShardLeaseID,
            roomShardLeaseGeneration: roomShardLeaseGeneration,
            shardLeaseID: shardLeaseID,
            shardGeneration: shardGeneration,
            shardValidUntil: shardValidUntil,
            shardCommandWindowLimit: shardCommandWindowLimit,
            shardCommandWindowUsed: shardCommandWindowUsed,

            actorRole: actorRole,
            senderIsActive: senderIsActive,
            muted: muted
        )
    }
}

private struct PlainHybridGroupAppendInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let messageID: UUID
    let eventID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let commandWindowUsed: Int
                let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    let text: String
    let entities: [V2MessageEntity]
    let fingerprint: V2SendMessageFingerprint
    let createdAtPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case messageID = "message_id"
        case eventID = "event_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case commandWindowUsed = "command_window_used"

        case shardLeaseID = "shard_lease_id"
        case shardLeaseGeneration = "shard_lease_generation"
        case text = "text_body"
        case entities = "rich_entities"
        case fingerprint
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
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
private struct PlainRoomLogMessageInput: Encodable {
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

/// 持久集合式单聊发送预检的输入。
///
/// 缓存字段只是「按修订不可变」的策略事实；
/// 只有全部匹配三条已锁定修订围栏与接收者之后，PostgreSQL 才会视其为可用。
private struct PlainDirectRoomLogBatchPreflightInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let nowPostgresMicroseconds: Int64
    let cachedRecipientID: UUID?
    let cachedDirectPairRevision: Int64?
    let cachedSenderPolicyRevision: Int64?
    let cachedRecipientPolicyRevision: Int64?
    let cachedRecipientIsActive: Bool?
    let cachedBlocked: Bool?
    let cachedIsFriend: Bool?
    let cachedAllowsStrangers: Bool?
    let usesRoomAdmissionCredits: Bool

    init(
        ordinal: Int,
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        nowPostgresMicroseconds: Int64,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        usesRoomAdmissionCredits: Bool
    ) {
        self.ordinal = ordinal
        self.roomID = roomID
        self.senderID = senderID
        self.clientMessageID = clientMessageID
        self.nowPostgresMicroseconds = nowPostgresMicroseconds
        cachedRecipientID = cachedDirectPolicy?.recipientID
        cachedDirectPairRevision = cachedDirectPolicy?.directPairRevision
        cachedSenderPolicyRevision = cachedDirectPolicy?.senderPolicyRevision
        cachedRecipientPolicyRevision = cachedDirectPolicy?.recipientPolicyRevision
        cachedRecipientIsActive = cachedDirectPolicy?.recipientIsActive
        cachedBlocked = cachedDirectPolicy?.blocked
        cachedIsFriend = cachedDirectPolicy?.isFriend
        cachedAllowsStrangers = cachedDirectPolicy?.allowsStrangers
        self.usesRoomAdmissionCredits = usesRoomAdmissionCredits
    }

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
        case cachedRecipientID = "cached_recipient_id"
        case cachedDirectPairRevision = "cached_direct_pair_revision"
        case cachedSenderPolicyRevision = "cached_sender_policy_revision"
        case cachedRecipientPolicyRevision = "cached_recipient_policy_revision"
        case cachedRecipientIsActive = "cached_recipient_is_active"
        case cachedBlocked = "cached_blocked"
        case cachedIsFriend = "cached_is_friend"
        case cachedAllowsStrangers = "cached_allows_strangers"
        case usesRoomAdmissionCredits = "uses_room_admission_credits"
    }
}

private struct PlainDirectRoomLogBatchPreflightRow {
    let ordinal: Int
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let capacityClass: V2GroupCapacityClass
    let frozenAt: Date?
    let roomEligibleMemberCount: Int?
    let roomCommandWindowLimit: Int?
    let roomCommandWindowUsed: Int?
                            let roomShardLeaseID: UUID?
    let roomShardLeaseGeneration: Int64?
    let shardLeaseID: UUID?
    let shardGeneration: Int64?
    let shardValidUntil: Date?
    let shardCommandWindowLimit: Int?
    let shardCommandWindowUsed: Int?
                            let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let recipientUserID: UUID?
    let senderProfileVisibleToRecipient: Bool?
    let directPolicyRevision: Int64?
    let senderPolicyRevision: Int64?
    let recipientPolicyRevision: Int64?
    let senderCanSend: Bool?
    let recipientIsActive: Bool?
    let blocked: Bool?
    let isFriend: Bool?
    let senderHasReplied: Bool?
    let recipientHasReplied: Bool?
    let allowsStrangers: Bool?
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    /// 这是单聊消息准入中最热、最宽的行。直接按列解码可避免为每条消息
    /// 构造通用键控 Codable 容器、分配 49 个编码键并反复查找它们，
    /// 同时保留完全相同的 PostgreSQL 类型校验。
    ///
    /// - Parameter row: 待解码的数据库行。
    /// - Throws: 类型校验失败或列缺失时抛出。
    init(row: any SQLRow) throws {
        ordinal = try row.decode(column: "ordinal")
        kind = try row.decode(column: "room_kind")
        roomShardID = try row.decode(column: "room_shard_id")
        roomSequence = try row.decode(column: "room_sequence")
        timelineSequence = try row.decode(column: "timeline_sequence")
        membershipRevision = try row.decode(column: "membership_revision")
        capacityProfileID = try row.decode(column: "capacity_profile_id")
        capacityClass = try row.decode(column: "capacity_class")
        frozenAt = try row.decode(column: "frozen_at", as: Date?.self)
        roomEligibleMemberCount = try row.decode(column: "room_eligible_member_count", as: Int?.self)
        roomCommandWindowLimit = try row.decode(column: "room_command_window_limit", as: Int?.self)
        roomCommandWindowUsed = try row.decode(column: "room_command_window_used", as: Int?.self)

        roomShardLeaseID = try row.decode(column: "room_shard_lease_id", as: UUID?.self)
        roomShardLeaseGeneration = try row.decode(column: "room_shard_lease_generation", as: Int64?.self)
        shardLeaseID = try row.decode(column: "shard_lease_id", as: UUID?.self)
        shardGeneration = try row.decode(column: "shard_generation", as: Int64?.self)
        shardValidUntil = try row.decode(column: "shard_valid_until", as: Date?.self)
        shardCommandWindowLimit = try row.decode(column: "shard_command_window_limit", as: Int?.self)
        shardCommandWindowUsed = try row.decode(column: "shard_command_window_used", as: Int?.self)

        actorRole = try row.decode(column: "actor_role", as: String?.self)
        senderIsActive = try row.decode(column: "sender_is_active", as: Bool?.self)
        muted = try row.decode(column: "muted", as: Bool?.self)
        recipientUserID = try row.decode(column: "recipient_user_id", as: UUID?.self)
        senderProfileVisibleToRecipient = try row.decode(column: "sender_profile_visible_to_recipient", as: Bool?.self)
        directPolicyRevision = try row.decode(column: "direct_policy_revision", as: Int64?.self)
        senderPolicyRevision = try row.decode(column: "sender_policy_revision", as: Int64?.self)
        recipientPolicyRevision = try row.decode(column: "recipient_policy_revision", as: Int64?.self)
        senderCanSend = try row.decode(column: "sender_can_send", as: Bool?.self)
        recipientIsActive = try row.decode(column: "recipient_is_active", as: Bool?.self)
        blocked = try row.decode(column: "blocked", as: Bool?.self)
        isFriend = try row.decode(column: "is_friend", as: Bool?.self)
        senderHasReplied = try row.decode(column: "sender_has_replied", as: Bool?.self)
        recipientHasReplied = try row.decode(column: "recipient_has_replied", as: Bool?.self)
        allowsStrangers = try row.decode(column: "allows_strangers", as: Bool?.self)
        senderAccountKind = try row.decode(column: "sender_account_kind", as: String?.self)
        senderAccountStatus = try row.decode(column: "sender_account_status", as: String?.self)
        senderAllowsServiceMessages = try row.decode(column: "sender_allows_service_messages", as: Bool?.self)
        recipientAccountKind = try row.decode(column: "recipient_account_kind", as: String?.self)
        recipientAccountStatus = try row.decode(column: "recipient_account_status", as: String?.self)
        recipientAllowsCustomerMessages = try row.decode(column: "recipient_allows_customer_messages", as: Bool?.self)
    }

    var room: RoomRow {
        .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            capacityClass: capacityClass,

            frozenAt: frozenAt
        )
    }

    func directPolicySnapshot() throws -> DirectMessagePolicySnapshotRow {
        guard let recipientUserID, let senderProfileVisibleToRecipient,
              let recipientIsActive, let blocked, let isFriend,
              let senderHasReplied, let recipientHasReplied,
              let allowsStrangers
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            recipientUserID: recipientUserID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

    func directPolicyCacheEntry() throws -> V2DirectSendPolicyCache.Entry {
        guard let directPolicyRevision, let senderPolicyRevision,
              let recipientPolicyRevision
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        let policy = try directPolicySnapshot()
        return .init(
            recipientID: policy.recipientUserID,
            directPairRevision: directPolicyRevision,
            senderPolicyRevision: senderPolicyRevision,
            recipientPolicyRevision: recipientPolicyRevision,
            senderProfileVisibleToRecipient: policy.senderProfileVisibleToRecipient,
            senderCanSend: policy.senderCanSend,
            senderIsActive: senderIsActive == true,
            recipientIsActive: policy.recipientIsActive,
            blocked: policy.blocked,
            isFriend: policy.isFriend,
            senderHasReplied: policy.senderHasReplied,
            recipientHasReplied: policy.recipientHasReplied,
            allowsStrangers: policy.allowsStrangers,
            senderAccountKind: policy.senderAccountKind,
            senderAccountStatus: policy.senderAccountStatus,
            senderAllowsServiceMessages: policy.senderAllowsServiceMessages,
            recipientAccountKind: policy.recipientAccountKind,
            recipientAccountStatus: policy.recipientAccountStatus,
            recipientAllowsCustomerMessages: policy.recipientAllowsCustomerMessages
        )
    }

    func admissionSnapshot() throws -> AdmissionSnapshotRow {
        guard let roomEligibleMemberCount, let roomCommandWindowLimit,
              let roomCommandWindowUsed, let roomShardLeaseID,
              let roomShardLeaseGeneration, let shardLeaseID,
              let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            roomEligibleMemberCount: roomEligibleMemberCount,
            roomCommandWindowLimit: roomCommandWindowLimit,
            roomCommandWindowUsed: roomCommandWindowUsed,

            roomShardLeaseID: roomShardLeaseID,
            roomShardLeaseGeneration: roomShardLeaseGeneration,
            shardLeaseID: shardLeaseID,
            shardGeneration: shardGeneration,
            shardValidUntil: shardValidUntil,
            shardCommandWindowLimit: shardCommandWindowLimit,
            shardCommandWindowUsed: shardCommandWindowUsed,

            actorRole: actorRole,
            senderIsActive: senderIsActive,
            muted: muted
        )
    }

    /// 已预扣费的房间信用路径不再次物化 `room_admission`；
    /// 下方的分片行是传给持久额度池的确切状态。
    ///
    /// - Returns: 分片行。
    /// - Throws: 分片字段缺失时抛出。
    func shard() throws -> ShardRow {
        guard let shardLeaseID, let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            leaseID: shardLeaseID,
            generation: shardGeneration,
            validUntil: shardValidUntil,
            commandWindowLimit: shardCommandWindowLimit,
            commandWindowUsed: shardCommandWindowUsed)
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

private struct PreparedDirectRoomLogAppend {
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

private struct FastPlainDirectRoomLogAppendInput: Sendable {
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

/// 混合群组规范追加的具名、连接级缓存形式。
///
/// 数组刻意采用列式：PostgresNIO 可以在扩展协议中直接编码它们，
/// 而 PostgreSQL 可以用一次 `unnest` 展开。
/// JSON 值的实体列在服务端转换之前一直保持 JSON 文本，
/// 因此任意实体都能保持与回退路径完全相同的表示。
private struct PlainHybridGroupAppendStatement: PostgresPreparedStatement {
    static let name = "im_v2_plain_hybrid_group_append_v5"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT input.ordinal, input.room_id, input.message_id,
                   input.event_id, input.sender_id,
                   input.client_message_id, input.fingerprint_version, input.request_fingerprint, input.room_sequence,
                   input.timeline_sequence, input.membership_revision,
                   input.command_window_used,
                   input.shard_lease_id, input.shard_lease_generation,
                   input.text_body,
                   input.rich_entities_json::jsonb AS rich_entities,
                   ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
            FROM unnest(
                $1::integer[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::uuid[], $6::uuid[], $7::bigint[], $8::bigint[],
                $9::bigint[], $10::bigint[], $11::uuid[], $12::bigint[], $13::text[],
                $14::text[], $15::bigint[], $16::smallint[], $17::bytea[]
            ) AS input(
                ordinal, room_id, message_id, event_id, sender_id,
                client_message_id, room_sequence, timeline_sequence,
                membership_revision, command_window_used, shard_lease_id,
                shard_lease_generation, text_body, rich_entities_json,
                created_at_postgres_microseconds, fingerprint_version, request_fingerprint
            )
        ), final_room_input AS MATERIALIZED (
            SELECT DISTINCT ON (room_id) *
            FROM input
            ORDER BY room_id, ordinal DESC
        ), room_update AS (
            UPDATE im_v2.rooms AS room
            SET room_sequence = input.room_sequence,
                timeline_sequence = input.timeline_sequence
            FROM final_room_input AS input
            WHERE room.room_id = input.room_id
            RETURNING room.room_id
        ), admission_update AS (
            UPDATE im_v2.room_admission AS admission
            SET command_window_used = input.command_window_used,
                shard_lease_id = input.shard_lease_id,
                shard_lease_generation = input.shard_lease_generation
            FROM final_room_input AS input
            JOIN room_update ON room_update.room_id = input.room_id
            WHERE admission.room_id = input.room_id
            RETURNING admission.room_id
        ), message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence,
                 sender_user_id, client_message_id, text_body,
                 rich_entities, created_at, accepted_event_id,
                 accepted_event_storage, accepted_membership_revision)
            SELECT input.message_id, input.room_id, input.room_sequence,
                   input.timeline_sequence, input.sender_id,
                   input.client_message_id, input.text_body,
                   input.rich_entities, input.created_at, CASE WHEN input.room_sequence = input.timeline_sequence THEN input.event_id END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN input.membership_revision END
            FROM input
            JOIN admission_update ON admission_update.room_id = input.room_id
            RETURNING *
        )
        \(v2HybridGroupSendCompletionCTE)
        SELECT (SELECT count(*) FROM room_update)::bigint AS room_count,
               (SELECT count(*) FROM admission_update)::bigint
                   AS admission_count,
               (SELECT count(*) FROM message_insert)::bigint AS message_count
        """

    typealias Row = PlainHybridGroupMutationRow

    let inputs: [PlainHybridGroupAppendInput]
    let richEntitiesJSON: [String]

    init(inputs: [PlainHybridGroupAppendInput]) throws {
        self.inputs = inputs
        richEntitiesJSON = try inputs.map { input in
            input.entities.isEmpty ? "[]" : try roomWriteJSON(input.entities)
        }
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 17)
        bindings.append(try inputs.map { input in
            guard let ordinal = Int32(exactly: input.ordinal) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return ordinal
        })
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.messageID))
        bindings.append(inputs.map(\.eventID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.roomSequence))
        bindings.append(inputs.map(\.timelineSequence))
        bindings.append(inputs.map(\.membershipRevision))
        bindings.append(try inputs.map { input in
            guard let value = Int64(exactly: input.commandWindowUsed) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return value
        })
        bindings.append(inputs.map(\.shardLeaseID))
        bindings.append(inputs.map(\.shardLeaseGeneration))
        bindings.append(inputs.map(\.text))
        bindings.append(richEntitiesJSON)
        bindings.append(inputs.map(\.createdAtPostgresMicroseconds))
        bindings.append(inputs.map { Int16($0.fingerprint.version) })
        bindings.append(inputs.map { ByteBuffer(bytes: $0.fingerprint.digest) })
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        let counts = try row.decode((Int64, Int64, Int64).self)
        return .init(
            roomCount: counts.0,
            admissionCount: counts.1,
            messageCount: counts.2
        )
    }
}

/// 不变式快速追加语句的具名、连接级缓存形式。
///
/// 每当 `sql` 变化时都要提升 `name`。
/// PostgresNIO 会在每条物理前台连接上准备一次，然后用新的数组绑定执行；
/// 该语句既不拥有连接，也不跨越外层 Fluent 事务边界。
private struct FastPlainDirectRoomLogAppendStatement: PostgresPreparedStatement {
    static let name = "im_v2_fast_plain_direct_room_log_append_v7"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT (input.ordinality - 1)::integer AS ordinal,
                   input.room_id, input.sender_id,
                   input.recipient_id, input.message_id, input.event_id,
                   input.client_message_id, input.fingerprint_version, input.request_fingerprint,
                   input.expected_membership_revision,
                   input.expected_direct_pair_revision,
                   input.expected_sender_policy_revision,
                   input.expected_recipient_policy_revision,
                   input.room_shard_id, input.capacity_profile_id,
                   input.expected_shard_lease_id,
                   input.expected_shard_generation,
                   input.requires_stranger_quota,
                   input.uses_room_admission_credits,
                   input.text_body, input.rich_entities_json::jsonb AS rich_entities,
                   input.created_at_postgres_microseconds, input.window_start,
                   ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
            FROM unnest(
                $1::uuid[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::uuid[], $6::uuid[], $7::bigint[], $8::bigint[],
                $9::bigint[], $10::bigint[], $11::text[], $12::text[],
                $13::uuid[], $14::bigint[], $15::boolean[], $16::boolean[],
                $17::text[], $18::text[], $19::bigint[], $20::timestamptz[], $22::smallint[], $23::bytea[]
            ) WITH ORDINALITY AS input(
                room_id, sender_id, recipient_id, message_id, event_id,
                client_message_id, expected_membership_revision,
                expected_direct_pair_revision, expected_sender_policy_revision,
                expected_recipient_policy_revision, room_shard_id,
                capacity_profile_id, expected_shard_lease_id,
                expected_shard_generation, requires_stranger_quota,
                uses_room_admission_credits, text_body, rich_entities_json,
                created_at_postgres_microseconds, window_start, fingerprint_version, request_fingerprint, ordinality
            )
        ), locked_room AS MATERIALIZED (
            SELECT input.*, room.room_sequence, room.timeline_sequence,
                   room.membership_revision, room.room_kind,
                   room.room_shard_id AS actual_room_shard_id,
                   room.capacity_profile_id AS actual_capacity_profile_id,
                   room.frozen_at
            FROM input
            JOIN im_v2.rooms AS room ON room.room_id = input.room_id
            ORDER BY room.room_id
            FOR UPDATE OF room
        ), fresh_room AS MATERIALIZED (
            SELECT room.*
            FROM locked_room AS room
            WHERE NOT EXISTS (
                SELECT 1
                FROM im_v2.message_send_completions AS message
                WHERE message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                  AND message.client_message_id = room.client_message_id
            )
              AND NOT EXISTS (
                SELECT 1
                FROM im_v2.direct_message_denials AS denial
                WHERE denial.sender_user_id = room.sender_id
                  AND denial.room_id = room.room_id
                  AND denial.client_message_id = room.client_message_id
            )
        ), locked_membership AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = room.room_id
             AND membership.user_id = room.sender_id
             AND membership.joined_revision <= room.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > room.membership_revision)
            WHERE membership.role IN ('owner', 'admin', 'member')
              AND NOT EXISTS (
                SELECT 1
                FROM im_v2.room_member_mutes AS mute
                WHERE mute.room_id = room.room_id
                  AND mute.user_id = room.sender_id
                  AND mute.mute_until > room.created_at
              )
            FOR UPDATE OF membership
        ), locked_pair AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_membership AS membership ON membership.ordinal = room.ordinal
            JOIN im_v2.direct_room_pairs AS pair
              ON pair.room_id = room.room_id
             AND ((pair.lower_user_id = room.sender_id
                   AND pair.higher_user_id = room.recipient_id)
                  OR (pair.higher_user_id = room.sender_id
                      AND pair.lower_user_id = room.recipient_id))
             AND pair.direct_policy_revision = room.expected_direct_pair_revision
            WHERE COALESCE((
                SELECT count(*) = 2
                    AND bool_and(member.user_id IN (pair.lower_user_id, pair.higher_user_id))
                FROM (
                    SELECT user_id FROM im_v2.room_memberships
                    WHERE room_id = room.room_id
                      AND joined_revision <= room.membership_revision
                      AND (left_revision IS NULL OR left_revision > room.membership_revision)
                    LIMIT 3
                ) AS member
            ), FALSE)
            FOR UPDATE OF pair
        ), locked_policy_versions AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_pair AS pair ON pair.ordinal = room.ordinal
            JOIN im_v2.user_direct_send_policy_versions AS sender_version
              ON sender_version.user_id = room.sender_id
             AND sender_version.revision = room.expected_sender_policy_revision
            JOIN im_v2.user_direct_send_policy_versions AS recipient_version
              ON recipient_version.user_id = room.recipient_id
             AND recipient_version.revision = room.expected_recipient_policy_revision
            FOR SHARE OF sender_version, recipient_version
        ), locked_active_profiles AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_policy_versions AS policy ON policy.ordinal = room.ordinal
            JOIN im_v2.public_user_profiles AS sender_profile
              ON sender_profile.user_id = room.sender_id
             AND sender_profile.state = 'active'
            JOIN im_v2.public_user_profiles AS recipient_profile
              ON recipient_profile.user_id = room.recipient_id
             AND recipient_profile.state = 'active'
            WHERE NOT EXISTS (
                SELECT 1 FROM im_v2.account_disables AS disabled
                WHERE disabled.user_id = room.sender_id
            )
              AND NOT EXISTS (
                SELECT 1 FROM im_v2.account_disables AS disabled
                WHERE disabled.user_id = room.recipient_id
            )
            FOR SHARE OF sender_profile, recipient_profile
        ), locked_admission AS MATERIALIZED (
            SELECT room.ordinal,
                   admission.command_window_used,
                   admission.command_window_limit,
                   admission.shard_lease_id,
                   admission.shard_lease_generation
            FROM fresh_room AS room
            JOIN locked_active_profiles AS profile ON profile.ordinal = room.ordinal
            JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
            WHERE room.uses_room_admission_credits
               OR admission.command_window_used < admission.command_window_limit
            FOR UPDATE OF admission
        ), validated_shard AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = room.room_shard_id
             AND shard.capacity_profile_id = room.capacity_profile_id
             AND shard.lease_id = room.expected_shard_lease_id
             AND shard.generation = room.expected_shard_generation
             AND shard.valid_until > room.created_at
            WHERE admission.shard_lease_id = room.expected_shard_lease_id
              AND admission.shard_lease_generation = room.expected_shard_generation
        ), eligible AS MATERIALIZED (
            SELECT room.*
            FROM fresh_room AS room
            JOIN validated_shard AS shard ON shard.ordinal = room.ordinal
            WHERE room.room_kind = 'direct'
              AND room.frozen_at IS NULL
              AND room.membership_revision = room.expected_membership_revision
              AND room.actual_room_shard_id = room.room_shard_id
              AND room.actual_capacity_profile_id = room.capacity_profile_id
        ), stranger_quota AS (
            INSERT INTO im_v2.stranger_message_windows
                (sender_user_id, recipient_user_id, window_started_at, message_count)
            SELECT eligible.sender_id, eligible.recipient_id,
                   eligible.created_at, 1
            FROM eligible
            WHERE eligible.requires_stranger_quota
            ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
            SET window_started_at = CASE
                    WHEN im_v2.stranger_message_windows.window_started_at
                         <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                    THEN EXCLUDED.window_started_at
                    ELSE im_v2.stranger_message_windows.window_started_at
                END,
                message_count = CASE
                    WHEN im_v2.stranger_message_windows.window_started_at
                         <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                    THEN 1
                    ELSE im_v2.stranger_message_windows.message_count + 1
                END
            WHERE im_v2.stranger_message_windows.window_started_at
                      <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
               OR im_v2.stranger_message_windows.message_count < $21
            RETURNING sender_user_id, recipient_user_id
        ), quota_gate AS MATERIALIZED (
            SELECT eligible.*
            FROM eligible
            WHERE NOT eligible.requires_stranger_quota
            UNION ALL
            SELECT eligible.*
            FROM eligible
            JOIN stranger_quota AS quota
              ON quota.sender_user_id = eligible.sender_id
             AND quota.recipient_user_id = eligible.recipient_id
            WHERE eligible.requires_stranger_quota
        ), room_update AS (
            UPDATE im_v2.rooms AS room
            SET room_sequence = room.room_sequence + 1,
                timeline_sequence = room.timeline_sequence + 1
            FROM quota_gate
            WHERE room.room_id = quota_gate.room_id
              AND room.room_sequence < 9223372036854775807
              AND room.timeline_sequence < 9223372036854775807
            RETURNING room.room_id, room.room_sequence,
                      room.timeline_sequence
        ), admission_update AS (
            UPDATE im_v2.room_admission AS admission
            SET command_window_used = admission.command_window_used + 1
            FROM eligible
            JOIN room_update ON room_update.room_id = eligible.room_id
            WHERE admission.room_id = eligible.room_id
              AND NOT eligible.uses_room_admission_credits
            RETURNING admission.room_id
        ), admission_gate AS (
            SELECT room_update.room_id
            FROM room_update
            JOIN eligible ON eligible.room_id = room_update.room_id
            WHERE eligible.uses_room_admission_credits
            UNION ALL
            SELECT room_id FROM admission_update
        ), message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence,
                 sender_user_id, client_message_id, text_body,
                 rich_entities, reply_to_message_id,
                 forwarded_from_message_id, forwarded_from_user_id,
                 created_at, accepted_event_id, accepted_event_storage,
                 accepted_membership_revision)
            SELECT eligible.message_id, eligible.room_id,
                   room_update.room_sequence,
                   room_update.timeline_sequence,
                   eligible.sender_id, eligible.client_message_id,
                   eligible.text_body, eligible.rich_entities, NULL,
                   NULL, NULL, eligible.created_at, CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.event_id END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.expected_membership_revision END
            FROM eligible
            JOIN room_update ON room_update.room_id = eligible.room_id
            JOIN admission_gate ON admission_gate.room_id = eligible.room_id
            RETURNING *
        )
        \(v2FastDirectRoomLogSendCompletionCTE)
        SELECT input.ordinal, room_update.room_sequence,
               room_update.timeline_sequence
        FROM input
        JOIN room_update ON room_update.room_id = input.room_id
        JOIN admission_gate ON admission_gate.room_id = input.room_id
        JOIN message_insert ON message_insert.message_id = input.message_id
        ORDER BY input.ordinal
        """

    typealias Row = FastPlainDirectRoomLogAllocationRow

    let inputs: [FastPlainDirectRoomLogAppendInput]
    let maximumStrangerMessages: Int64

    init(
        inputs: [FastPlainDirectRoomLogAppendInput],
        maximumStrangerMessages: Int
    ) {
        self.inputs = inputs
        self.maximumStrangerMessages = Int64(maximumStrangerMessages)
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 23)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.recipientID))
        bindings.append(inputs.map(\.messageID))
        bindings.append(inputs.map(\.eventID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.expectedMembershipRevision))
        bindings.append(inputs.map(\.expectedDirectPairRevision))
        bindings.append(inputs.map(\.expectedSenderPolicyRevision))
        bindings.append(inputs.map(\.expectedRecipientPolicyRevision))
        bindings.append(inputs.map(\.roomShardID))
        bindings.append(inputs.map(\.capacityProfileID))
        bindings.append(inputs.map(\.expectedShardLeaseID))
        bindings.append(inputs.map(\.expectedShardGeneration))
        bindings.append(inputs.map(\.requiresStrangerQuota))
        bindings.append(inputs.map(\.usesRoomAdmissionCredits))
        bindings.append(inputs.map(\.text))
        bindings.append(inputs.map(\.entitiesJSON))
        bindings.append(inputs.map(\.createdAtPostgresMicroseconds))
        bindings.append(inputs.map(\.windowStart))
        bindings.append(maximumStrangerMessages)
        bindings.append(inputs.map { Int16($0.fingerprint.version) })
        bindings.append(inputs.map { ByteBuffer(bytes: $0.fingerprint.digest) })
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        let (ordinal, roomSequence, timelineSequence) = try row.decode(
            (Int32, Int64, Int64).self
        )
        return .init(
            ordinal: Int(ordinal),
            roomSequence: roomSequence,
            timelineSequence: timelineSequence
        )
    }
}

private struct FastPlainDirectRoomLogAllocationRow: Decodable {
    let ordinal: Int
    let roomSequence: Int64
    let timelineSequence: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
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
private struct DirectRoomPairRow: Decodable {
    let lowerUserID: UUID
    let higherUserID: UUID
    enum CodingKeys: String, CodingKey { case lowerUserID = "lower_user_id", higherUserID = "higher_user_id" }
}
private struct DirectPolicyBooleanRow: Decodable { let value: Bool }
private struct DirectMessageAcceptanceContext {
    let recipientID: UUID
    let restriction: V2DirectMessageDenied.Reason?
    let requiresStrangerQuota: Bool
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let senderHasReplied: Bool
    let supportAccountID: UUID?
}
private struct DirectReplyCacheUpdate {
    let key: V2DirectSendPolicyCache.Key
    let expectedDirectPairRevision: Int64
}
private struct RoomWriteCommit {
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
private struct DirectPostAcceptanceProjectionChanges {
    let senderCapabilityInserted: Bool
    let recipientProfileInserted: Bool
}
// Match postgres-nio Date decoding and Foundation's reference-date arithmetic before
// truncating to wire milliseconds. Numeric-to-bigint rounds; truncating the native
// epoch alone can also disagree with decoded Date near PostgreSQL's upper bound.
private let directProfileUpdatedAtMillisecondsSQL: SQLQueryString = """
    trunc((
        ((extract(epoch FROM profile.updated_at) - 946684800) * 1000000)::double precision
        / 1000000 - 31622400 + 978307200
    ) * 1000)::bigint
    """

private struct DirectPostAcceptanceProjectionInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let recipientID: UUID
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let sourceEventID: UUID
    let createdAtPostgresMicroseconds: Int64
    let createdAtMilliseconds: Int64
    let stateVersion: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case recipientID = "recipient_id"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case sourceEventID = "source_event_id"
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
        case createdAtMilliseconds = "created_at_ms"
        case stateVersion = "state_version"
    }
}
private struct DirectPostAcceptanceProjectionBatchRow: Decodable {
    let ordinal: Int
    let senderCapabilityInserted: Bool
    let recipientProfileInserted: Bool
    let profileExists: Bool
    let pairUpdated: Bool
    let expectedEventCount: Int64
    let insertedEventCount: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case senderCapabilityInserted = "sender_capability_inserted"
        case recipientProfileInserted = "recipient_profile_inserted"
        case profileExists = "profile_exists"
        case pairUpdated = "pair_updated"
        case expectedEventCount = "expected_event_count"
        case insertedEventCount = "inserted_event_count"
    }
}

private struct DirectMessagePolicySnapshotRow: Decodable {
    let recipientUserID: UUID
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let recipientIsActive: Bool
    let blocked: Bool
    let isFriend: Bool
    let senderHasReplied: Bool
    let recipientHasReplied: Bool
    let allowsStrangers: Bool
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case recipientUserID = "recipient_user_id"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case recipientIsActive = "recipient_is_active"
        case blocked
        case isFriend = "is_friend"
        case senderHasReplied = "sender_has_replied"
        case recipientHasReplied = "recipient_has_replied"
        case allowsStrangers = "allows_strangers"
        case senderAccountKind = "sender_account_kind"
        case senderAccountStatus = "sender_account_status"
        case senderAllowsServiceMessages = "sender_allows_service_messages"
        case recipientAccountKind = "recipient_account_kind"
        case recipientAccountStatus = "recipient_account_status"
        case recipientAllowsCustomerMessages = "recipient_allows_customer_messages"
    }
}

private extension DirectMessagePolicySnapshotRow {
    func applyingControlPolicy(_ control: V2DirectSendControlPolicy) -> Self {
        .init(recipientUserID: recipientUserID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient, senderCanSend: senderCanSend,
            recipientIsActive: control.recipient.isActive, blocked: control.blocked, isFriend: control.isFriend,
            senderHasReplied: senderHasReplied, recipientHasReplied: recipientHasReplied,
            allowsStrangers: control.allowsStrangers,
            senderAccountKind: control.sender.specialKind, senderAccountStatus: control.sender.specialStatus,
            senderAllowsServiceMessages: control.sender.allowsServiceMessages,
            recipientAccountKind: control.recipient.specialKind, recipientAccountStatus: control.recipient.specialStatus,
            recipientAllowsCustomerMessages: control.recipient.allowsCustomerMessages)
    }
}

private extension V2DirectSendPolicyCache.Entry {
    /// 集合预检已在持有锁的情况下比较过持久配对与策略修订。
    ///
    /// 只有在那道围栏匹配之后，这些缓存派生字段才可被复用于未变更的判定表。
    ///
    /// - Returns: 单聊策略快照行。
    func policySnapshot() -> DirectMessagePolicySnapshotRow {
        .init(
            recipientUserID: recipientID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

    /// 这两个配对本地的标志会在与首条已接受消息相同的源事务中变为真。
    ///
    /// 因此只在提交之后发布精化值，就不会让一个未提交的资料/能力对后续授权尝试可见。
    /// 持久预检在依赖该提示之前，仍会校验配对与策略修订。
    ///
    /// - Parameters:
    ///   - senderCapabilityInserted: 是否插入了发送方能力投影。
    ///   - recipientProfileInserted: 是否插入了接收方资料投影。
    /// - Returns: 应用提交后投影后的缓存条目。
    func applyingPostAcceptanceProjection(
        senderCapabilityInserted: Bool,
        recipientProfileInserted: Bool
    ) -> Self {
        guard senderCapabilityInserted || recipientProfileInserted else { return self }
        return .init(
            recipientID: recipientID,
            directPairRevision: directPairRevision,
            senderPolicyRevision: senderPolicyRevision,
            recipientPolicyRevision: recipientPolicyRevision,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient || recipientProfileInserted,
            senderCanSend: senderCapabilityInserted ? true : senderCanSend,
            senderIsActive: senderIsActive,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }
}

private struct DirectRoomProfileMutationRow: Decodable {
    let profileExists: Bool
    let neededCount: Int64
    let profileInsertedCount: Int64
    let insertedCount: Int64
    let pairCount: Int64

    enum CodingKeys: String, CodingKey {
        case profileExists = "profile_exists"
        case neededCount = "needed_count"
        case profileInsertedCount = "profile_inserted_count"
        case insertedCount = "inserted_count"
        case pairCount = "pair_count"
    }
}
private struct DirectCapabilityMutationRow: Decodable {
    let insertedCount: Int64
    let pairCount: Int64
    enum CodingKeys: String, CodingKey {
        case insertedCount = "inserted_count"
        case pairCount = "pair_count"
    }
}
private struct DirectMessageSyncSequenceRow: Decodable {
    let nextSequence: Int64
    enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" }
}
private struct DirectMessageEventRow: Decodable {
    let eventID: UUID
    enum CodingKeys: String, CodingKey { case eventID = "event_id" }
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
private enum ExistingMessageOperation {
    case accepted(V2MessageAcceptanceReceipt, V2SendMessageFingerprint)
    case denied(V2DirectMessageDenied, V2SendMessageFingerprint)
}

private struct MessageOperationReplayRow {
    let outcomeKind: String
    let messageID: UUID?
    let roomID: UUID
    let roomSequence: Int64?
    let timelineSequence: Int64
    let senderUserID: UUID
    let clientMessageID: UUID
    let fingerprintVersion: Int16?
    let requestFingerprint: Data?
    let createdAt: Date
    let sourceEventID: UUID?
    let acceptedMembershipRevision: Int64?
    let directRecipientUserID: UUID?
    let denialReason: String?
    let groupCapacityClass: V2GroupCapacityClass?

    func operation() throws -> ExistingMessageOperation {
        guard let fingerprintVersion, let version = UInt16(exactly: fingerprintVersion),
              let requestFingerprint, let sourceEventID, timelineSequence > 0
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let fingerprint = try V2SendMessageFingerprint(version: version, digest: requestFingerprint)
        switch outcomeKind {
        case "accepted":
            guard let messageID, let roomSequence, roomSequence > 0,
                  let acceptedMembershipRevision, acceptedMembershipRevision >= 0,
                  denialReason == nil
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return .accepted(try .init(
                messageID: .init(uuid: messageID), roomID: .init(uuid: roomID),
                roomSequence: unsigned(roomSequence), timelineSequence: unsigned(timelineSequence),
                senderUserID: .init(uuid: senderUserID), clientMessageID: .init(uuid: clientMessageID),
                groupCapacityClass: groupCapacityClass,
                sourceEventID: .init(uuid: sourceEventID), acceptedMembershipRevision: unsigned(acceptedMembershipRevision),
                directRecipientUserID: directRecipientUserID.map { .init(uuid: $0) }, createdAt: createdAt
            ), fingerprint)
        case "denied":
            guard messageID == nil, roomSequence == nil,
                  acceptedMembershipRevision == nil, directRecipientUserID == nil,
                  groupCapacityClass == nil, let denialReason,
                  let reason = V2DirectMessageDenied.Reason(rawValue: denialReason)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return .denied(try .init(
                roomID: .init(uuid: roomID), sourceEventID: .init(uuid: sourceEventID),
                timelineSequence: unsigned(timelineSequence), createdAt: createdAt, reason: reason
            ), fingerprint)
        default: throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }
}
private struct DirectMessageWindowRow: Decodable { let messageCount: Int; enum CodingKeys: String, CodingKey { case messageCount = "message_count" } }
private struct DirectReplyMarkerMutationRow: Decodable { let roomID: UUID; enum CodingKeys: String, CodingKey { case roomID = "room_id" } }
private struct MessageMediaPresentationRow: Decodable {
    let mediaID: UUID
    let contentType: String
    let byteCount: Int64

    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case contentType = "content_type"
        case byteCount = "byte_count"
    }

    var presentation: V2MediaPresentation {
        get throws {
            try .init(
                mediaID: .init(uuid: mediaID),
                kind: V2MediaPresentation.kind(forContentType: contentType),
                contentType: contentType,
                byteCount: byteCount
            )
        }
    }
}
private struct OrderedMessageMediaPresentationRow: Decodable {
    let ordinal: Int
    let mediaID: UUID
    let contentType: String
    let byteCount: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mediaID = "media_id"
        case contentType = "content_type"
        case byteCount = "byte_count"
    }

    var presentation: V2MediaPresentation {
        get throws {
            try .init(
                mediaID: .init(uuid: mediaID),
                kind: V2MediaPresentation.kind(forContentType: contentType),
                contentType: contentType,
                byteCount: byteCount
            )
        }
    }
}
private struct MentionSenderMembershipRow: Decodable { let role: String }
private struct ForwardSourceRow: Decodable { let roomID: UUID; let senderUserID: UUID; let text: String; let withdrawnAt: Date?; let entitiesJSON: String; let contentRevision: Int64; enum CodingKeys: String, CodingKey { case contentRevision = "content_revision", roomID = "room_id", senderUserID = "sender_user_id", text = "text_body", withdrawnAt = "withdrawn_at", entitiesJSON = "entities_json" } }
private enum MessageMediaAcceptanceAuthority: Sendable {
    case ownedBy(UUID)
    case forwardedFrom(UUID)
}
private struct ForwardMediaRow: Decodable {
    let mediaID: UUID
    let ordinal: Int
    let revokedAt: Date?
    enum CodingKeys: String, CodingKey { case mediaID = "media_id", ordinal, revokedAt = "revoked_at" }
}
private struct MentionMembershipRow: Decodable { let userID: UUID; let mentionable: Bool; enum CodingKeys: String, CodingKey { case userID = "user_id", mentionable } }
private struct MentionRow: Decodable {
    let kind: String; let userID: UUID?
    enum CodingKeys: String, CodingKey { case kind = "mention_kind", userID = "mentioned_user_id" }
    var target: V2MentionTarget {
        get throws {
            switch kind {
            case "everyone": return .everyone
            case "user": guard let userID else { throw V2RoomWriteStoreError.corruptPersistenceState }; return .user(.init(uuid: userID))
            default: throw V2RoomWriteStoreError.corruptPersistenceState
            }
        }
    }
}

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

// Match postgres-nio's Date encoder for both JSON and prepared append inputs.
// Keep this integer through persistence; Unix-second floating conversion can
// round a different microsecond, changing stored receipts and boundary checks.
func roomWritePostgresMicroseconds(_ date: Date) throws -> Int64 {
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    guard let value = Int64(exactly: (date.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)),
          v2PostgresTimestampMicrosecondsCanEncode(value)
    else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

// Match floor(extract(epoch FROM created_at) * 1000) using the exact driver
// input. Divide before adding the epoch offset so the full PostgreSQL range
// fits without overflowing an intermediate Unix-microsecond integer.
private func roomWriteProjectionMilliseconds(_ date: Date) throws -> Int64 {
    let microseconds = try roomWritePostgresMicroseconds(date)
    let floorMilliseconds = microseconds / 1_000 - (microseconds % 1_000 < 0 ? 1 : 0)
    return floorMilliseconds + 946_684_800_000
}

// Fresh acknowledgements must expose the same Date as the persisted receipt.
// Only newly accepted messages need conversion: replay dates are already
// decoded from PostgreSQL and must not be encoded and rounded a second time.
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

// Mirror postgres-nio's Date decoding after its microsecond encoding without
// another SQL read. Use only for fresh response values, not already-read rows.
private func roomWritePersistedDate(_ date: Date) throws -> Date {
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
