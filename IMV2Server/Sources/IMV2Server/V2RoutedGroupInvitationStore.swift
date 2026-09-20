import Fluent
import Foundation
import IMV2Core

/// 按房间归属路由的房间邀请存储。
///
/// 即使整个部署只用单个数据库，所有房间操作也仍然走归属选择。被选中的 PostgreSQL 事务
/// 会校验房间代次；过期路由与未知归属不会回退到控制库或另一个归属。
public struct V2RoutedGroupInvitationStore: V2GroupInvitationStore, V2GroupInviteCreationResuming {
    private let router: any V2RoomShardRouting
    private let owners: any V2RoomShardStorageResolving
    private let directory: any V2GroupInviteDirectory
    private let identities: any V2GroupInvitationIdentityReading
    private let quota: PostgresV2GroupJoinQuotaStore

    /// 组合控制库、归属路由与归属存储解析器。
    ///
    /// - Parameters:
    ///   - controlDatabase: 提供邀请目录与身份读取的控制库。
    ///   - router: 房间归属路由来源。
    ///   - owners: 房间归属到存储位置的解析器。
    public init(controlDatabase: any Database, router: any V2RoomShardRouting, owners: any V2RoomShardStorageResolving) {
        self.router = router
        self.owners = owners
        self.directory = PostgresV2GroupInviteDirectory(database: controlDatabase)
        self.identities = PostgresV2GroupInvitationIdentityReader(database: controlDatabase)
        self.quota = .init(database: controlDatabase)
    }

    /// 创建邀请：先在所属归属预检，再经目录落意图并最终由归属提交。
    ///
    /// 预检会在分配持久化控制意图之前拒绝房间缺失与未授权的新建。若归属侧已存在同一操作的
    /// 历史记录，则复用其邀请标识与时间戳，避免本次重试生成互相矛盾的标识或时间；
    /// 已有目录意图保持不可变，归属提交仍会重新解析当前路由并复核代次与原始输入。
    ///
    /// - Parameter request: 邀请创建持久化请求。
    /// - Returns: 归属侧写入的持久化邀请。
    /// - Throws: 预检失败、目录冲突或归属结果与意图不一致时抛出。
    public func create(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2StoredGroupInvite {
        // Reject missing rooms and unauthorized new creations before allocating
        // a durable control intent. The owner repeats authorization on commit.
        let existing = try await owner(roomID: request.roomID).preflightCreation(request)
        // A legacy owner can hold the creation before control has a directory
        // entry. Preflight verified its business input; preserve that binding
        // instead of allocating a contradictory ID/time from this retry.
        // Existing directory intents stay immutable, and owner commit still
        // resolves the current route and rechecks its epoch and original input.
        let candidate: V2GroupInviteCreatePersistenceRequest
        if let existing {
            candidate = .init(inviteID: existing.inviteID, roomID: request.roomID,
                actorUserID: request.actorUserID, operationID: request.operationID,
                tokenDigest: request.tokenDigest, requestedLifetimeSeconds: request.requestedLifetimeSeconds,
                expiresAt: existing.expiresAt, maximumApprovedUses: request.maximumApprovedUses,
                maximumActiveInvitesPerRoom: request.maximumActiveInvitesPerRoom,
                createdAt: existing.createdAt, evaluatedAt: request.evaluatedAt)
                .preservingTimestamps(existing.persistedTimestamps)
        } else {
            candidate = request
        }
        return try await V2GroupInviteCreationCoordinator(directory: directory).create(candidate) { fixed in
            try await owner(roomID: fixed.roomID).create(fixed)
        }
    }

    /// 以给定时刻重放一次未完成的邀请创建。
    ///
    /// - Parameters:
    ///   - intent: 待恢复的创建意图。
    ///   - now: 本次恢复使用的服务端时刻。
    /// - Throws: 与 ``create(_:)`` 相同的错误。
    public func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws {
        _ = try await create(intent.request.evaluated(at: now))
    }

    /// 列出房间内仍然可用的邀请。
    ///
    /// 归属提交可能因响应丢失而早于目录标记完成，因此管理列表不会返回尚未登记的令牌；
    /// 这类邀请需要由创建重试来完成收尾。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起查询的用户。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 已登记且可用的邀请列表。
    /// - Throws: 归属解析或持久化失败时抛出。
    public func activeInvites(roomID: RoomID, actorUserID: UserID, now: Date) async throws -> [V2StoredGroupInvite] {
        let values = try await owner(roomID: roomID).activeInvites(roomID: roomID, actorUserID: actorUserID, now: now)
        // An owner commit can outlive a lost finalize response. Never return an
        // unregistered token from the management list; creation retry resumes it.
        let ready = try await directory.readyInvites(roomID: roomID, inviteIDs: Set(values.map(\.inviteID)))
        return values.filter { ready.contains($0.inviteID) }
    }

    /// 撤销邀请。
    ///
    /// - Parameters:
    ///   - inviteID: 目标邀请。
    ///   - roomID: 邀请所属房间。
    ///   - actorUserID: 发起撤销的用户。
    ///   - operationID: 幂等操作标识。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 无权限、邀请不可撤销或持久化失败时抛出。
    public func revoke(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, now: Date) async throws {
        try await owner(roomID: roomID).revoke(inviteID: inviteID, roomID: roomID, actorUserID: actorUserID, operationID: operationID, now: now)
    }

    /// 按令牌摘要预览邀请。
    ///
    /// 目录中没有该令牌时返回不可用，而不会继续猜测归属。
    ///
    /// - Parameters:
    ///   - tokenDigest: 邀请令牌摘要。
    ///   - applicantUserID: 申请人。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 预览结果。
    /// - Throws: 归属解析或持久化失败时抛出。
    public func preview(tokenDigest: Data, applicantUserID: UserID, now: Date) async throws -> V2GroupInvitePreviewPersistenceOutcome {
        guard let location = try await directory.resolve(tokenDigest: tokenDigest) else { return .unavailable }
        return try await owner(roomID: location.roomID, inviteID: location.inviteID).preview(tokenDigest: tokenDigest, applicantUserID: applicantUserID, now: now)
    }

    /// 提交入群申请。
    ///
    /// 目录中没有该令牌时返回不可用，而不会继续猜测归属。
    ///
    /// - Parameter request: 入群申请持久化请求。
    /// - Returns: 提交结果。
    /// - Throws: 归属解析或持久化失败时抛出。
    public func submit(_ request: V2GroupJoinSubmissionPersistenceRequest) async throws -> V2GroupJoinSubmissionPersistenceOutcome {
        guard let location = try await directory.resolve(tokenDigest: request.tokenDigest) else { return .unavailable }
        guard try await identities.read(userIDs: [request.applicantUserID])[request.applicantUserID]?.isActive == true else {
            throw V2GroupInvitationServiceError.permissionDenied
        }
        guard case .reserved(let intent) = try await quota.reserve(request, roomID: location.roomID, inviteID: location.inviteID, now: request.createdAt) else { return .rateLimited }
        let store = try await owner(roomID: .init(uuid: intent.roomID), inviteID: .init(uuid: intent.inviteID))
        let receipt = try await store.applyReservedSubmission(intent, now: request.createdAt)
        try await quota.resolve(intent, outcome: receipt.outcome, targetRequestID: receipt.targetRequestID, now: request.createdAt)
        return try await store.reservedSubmissionResponse(intent, observed: receipt)
    }

    /// 分页读取待审核的入群申请。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - reviewerUserID: 发起查询的审核人。
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 申请分页。
    /// - Throws: 无审核权限、游标非法或持久化失败时抛出。
    public func pendingRequests(roomID: RoomID, reviewerUserID: UserID, cursor: String?, pageSize: Int, now: Date) async throws -> V2GroupJoinRequestRecordPage {
        try await owner(roomID: roomID).pendingRequests(roomID: roomID, reviewerUserID: reviewerUserID, cursor: cursor, pageSize: pageSize, now: now)
    }

    /// 批准一条入群申请。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - requestID: 目标申请。
    ///   - reviewerUserID: 审核人。
    ///   - operationID: 幂等操作标识。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 批准结果。
    /// - Throws: 无审核权限、归属变化或持久化失败时抛出。
    public func approve(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupJoinApprovalPersistenceOutcome {
        let result = try await owner(roomID: roomID).approve(roomID: roomID, requestID: requestID, reviewerUserID: reviewerUserID, operationID: operationID, capacityProfile: capacityProfile, eventID: eventID, now: now)
        switch result {
        case .approved(let request), .alreadyDecided(let request): try await quota.releaseTerminal(request, now: now)
        default: break
        }
        return result
    }

    /// 拒绝一条入群申请。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - requestID: 目标申请。
    ///   - reviewerUserID: 审核人。
    ///   - operationID: 幂等操作标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 拒绝准备结果。
    /// - Throws: 无审核权限、归属变化或持久化失败时抛出。
    public func reject(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, now: Date) async throws -> V2GroupJoinDecisionPreparationOutcome {
        let result = try await owner(roomID: roomID).reject(roomID: roomID, requestID: requestID, reviewerUserID: reviewerUserID, operationID: operationID, now: now)
        switch result {
        case .rejected(let request), .alreadyApproved(let request), .alreadyRejected(let request): try await quota.releaseTerminal(request, now: now)
        default: break
        }
        return result
    }

    public func cancel(roomID: RoomID, requestID: GroupJoinRequestID, applicantUserID: UserID, now: Date) async throws -> V2GroupJoinRequestRecord {
        let result = try await owner(roomID: roomID).cancel(roomID: roomID, requestID: requestID, applicantUserID: applicantUserID, now: now)
        try await quota.releaseTerminal(result, now: now)
        return result
    }

    /// Recovery replays the exact persisted generation, without reserving again
    /// or hydrating a user-facing profile. Lost terminal notifications converge here.
    func resumeSubmission(_ intent: V2GroupJoinQuotaIntent, now: Date) async throws {
        let receipt = try await owner(roomID: .init(uuid: intent.roomID), inviteID: .init(uuid: intent.inviteID)).applyReservedSubmission(intent, now: now)
        try await quota.resolve(intent, outcome: receipt.outcome, targetRequestID: receipt.targetRequestID, now: now)
    }

    /// 解析房间归属并构造对应的邀请存储。
    ///
    /// 归属位置的 schema 必须为 `im_v2`；其他 schema 视为配置错误而拒绝，
    /// 避免把邀请写入非标准位置。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - inviteID: 可选邀请标识，用于把令牌解析结果一并带入作用域。
    /// - Returns: 已绑定归属作用域的邀请存储。
    /// - Throws: 房间标识非法时抛出 ``V2GroupInvitationServiceError/invalidRequest``；
    ///   归属未配置或 schema 不符时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    private func owner(roomID: RoomID, inviteID: GroupInviteID? = nil) async throws -> PostgresV2GroupInvitationStore {
        guard let room = roomID.uuidValue else { throw V2GroupInvitationServiceError.invalidRequest }
        let route = try await router.route(for: roomID)
        let location = try owners.location(for: route.shardID)
        guard location.schema == "im_v2" else { throw V2RoomShardStorageRegistryError.invalidLocation }
        return .init(database: location.database, identities: identities, scope: .init(roomID: room, route: route, inviteID: inviteID?.uuidValue))
    }
}
