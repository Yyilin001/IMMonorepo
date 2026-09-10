import Foundation

/// 群审批恢复的作用域。
public struct V2GroupApprovalRecoveryScope: Equatable, Sendable {
    /// 逻辑分片标识。
    public let shardID: String
    /// 期望的归属代次。
    public let ownerEpoch: Int64
    /// 目标房间。
    public let roomID: UUID

    /// 校验并保存作用域。
    ///
    /// - Parameters:
    ///   - shardID: 逻辑分片标识，需非空、不超过 128 字节且不含首尾空白。
    ///   - ownerEpoch: 非负的归属代次。
    ///   - roomID: 目标房间。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2GroupApprovalRecoveryError/invalidRequest``。
    public init(shardID: String, ownerEpoch: Int64, roomID: UUID) throws {
        guard !shardID.isEmpty, shardID.utf8.count <= 128,
              shardID == shardID.trimmingCharacters(in: .whitespacesAndNewlines), ownerEpoch >= 0
        else { throw V2GroupApprovalRecoveryError.invalidRequest }
        self.shardID = shardID; self.ownerEpoch = ownerEpoch; self.roomID = roomID
    }
}

/// 一次群审批恢复请求。
public struct V2GroupApprovalRecoveryCommand: Equatable, Sendable {
    /// 本次恢复的幂等操作标识。
    public let operationID: UUID
    /// 恢复作用域。
    public let scope: V2GroupApprovalRecoveryScope
    /// 目标入群申请。
    public let requestID: UUID
    /// 原审核人。
    public let reviewerUserID: UUID
    /// 原审批决定的操作标识。
    public let decisionOperationID: UUID
    /// 运维重放原因。
    public let reason: V2DurableWorkReplayReason

    /// 保存恢复请求，不做取值校验。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - scope: 恢复作用域。
    ///   - requestID: 目标申请。
    ///   - reviewerUserID: 原审核人。
    ///   - decisionOperationID: 原审批操作标识。
    ///   - reason: 重放原因。
    public init(operationID: UUID, scope: V2GroupApprovalRecoveryScope, requestID: UUID,
                reviewerUserID: UUID, decisionOperationID: UUID, reason: V2DurableWorkReplayReason) {
        self.operationID = operationID; self.scope = scope; self.requestID = requestID
        self.reviewerUserID = reviewerUserID; self.decisionOperationID = decisionOperationID; self.reason = reason
    }
}

/// 一个待恢复的审批候选。
public struct V2GroupApprovalRecoveryCandidate: Equatable, Codable, Sendable {
    /// 入群申请标识。
    public let requestID: UUID
    /// 原审核人。
    public let reviewerUserID: UUID
    /// 原审批决定的操作标识。
    public let decisionOperationID: UUID
    /// 申请人。
    public let applicantUserID: UUID
    /// 准备阶段记录的成员修订。
    public let preparedRevision: Int64

    /// 保存候选记录，不做取值校验。
    ///
    /// - Parameters:
    ///   - requestID: 入群申请标识。
    ///   - reviewerUserID: 原审核人。
    ///   - decisionOperationID: 原审批操作标识。
    ///   - applicantUserID: 申请人。
    ///   - preparedRevision: 准备阶段的成员修订。
    public init(requestID: UUID, reviewerUserID: UUID, decisionOperationID: UUID,
                applicantUserID: UUID, preparedRevision: Int64) {
        self.requestID = requestID; self.reviewerUserID = reviewerUserID
        self.decisionOperationID = decisionOperationID; self.applicantUserID = applicantUserID
        self.preparedRevision = preparedRevision
    }
}

/// 待恢复审批的分页。
public struct V2GroupApprovalRecoveryPage: Equatable, Codable, Sendable {
    /// 本页候选。
    public let candidates: [V2GroupApprovalRecoveryCandidate]
    /// 下一页游标；为空表示已到末尾。
    public let nextCursor: UUID?

    /// 保存分页结果。
    ///
    /// - Parameters:
    ///   - candidates: 本页候选。
    ///   - nextCursor: 下一页游标。
    public init(candidates: [V2GroupApprovalRecoveryCandidate], nextCursor: UUID?) {
        self.candidates = candidates; self.nextCursor = nextCursor
    }
}

/// 审批恢复的结论分类。
public enum V2GroupApprovalRecoveryOutcome: String, Codable, Sendable {
    /// 原审批实际已提交，成员已加入。
    case completed
    /// 申请已释放，需要按普通审批路径重新决定。
    case released
    /// 状态无法自动判定，需要隔离人工处理。
    case quarantined
    /// 申请当前并不处于审批中状态。
    case notApproving = "not_approving"
}

/// 审批恢复结论的细分原因。
public enum V2GroupApprovalRecoveryDetail: String, Codable, Sendable {
    /// 决定操作已提交。
    case committedOperation = "committed_operation"
    /// 没有历史加入记录。
    case noHistoricalAdd = "no_historical_add"
    /// 操作标识与记录不一致。
    case operationMismatch = "operation_mismatch"
    /// 存在历史加入记录但没有对应回执。
    case historicalAddWithoutReceipt = "historical_add_without_receipt"
    /// 成员修订非法。
    case invalidRevision = "invalid_revision"
    /// 邀请可用次数已耗尽。
    case inviteExhausted = "invite_exhausted"
    /// 申请不处于审批中状态。
    case notApproving = "not_approving"
}

/// 单次审批恢复的结果。
public struct V2GroupApprovalRecoveryResult: Equatable, Codable, Sendable {
    /// 本次恢复的幂等操作标识。
    public let operationID: UUID
    /// 恢复结论。
    public let outcome: V2GroupApprovalRecoveryOutcome
    /// 结论的细分原因。
    public let detail: V2GroupApprovalRecoveryDetail
    /// 本次调用是否命中已有结果。
    public let wasIdempotent: Bool

    /// 保存恢复结果。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - outcome: 恢复结论。
    ///   - detail: 细分原因。
    ///   - wasIdempotent: 是否命中已有结果。
    public init(operationID: UUID, outcome: V2GroupApprovalRecoveryOutcome,
                detail: V2GroupApprovalRecoveryDetail, wasIdempotent: Bool) {
        self.operationID = operationID; self.outcome = outcome
        self.detail = detail; self.wasIdempotent = wasIdempotent
    }
}

/// 审批恢复错误。
public enum V2GroupApprovalRecoveryError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 请求的分片不在当前部署配置中。
    case unknownShard
    /// 目标房间归属已变更。
    case ownerChanged
    /// 目标申请不存在。
    case requestNotFound
    /// 审批决定在恢复期间发生变化。
    case decisionChanged
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 审批恢复的持久化能力。
public protocol V2GroupApprovalRecoveryStore: Sendable {
    /// 分页读取待恢复的审批候选。
    ///
    /// - Parameters:
    ///   - scope: 恢复作用域。
    ///   - after: 上一页游标。
    ///   - limit: 本页最多返回的候选数。
    /// - Returns: 候选分页。
    /// - Throws: 作用域不符或持久化失败时抛出。
    func candidates(scope: V2GroupApprovalRecoveryScope, after: UUID?, limit: Int) async throws -> V2GroupApprovalRecoveryPage

    /// 恢复一条审批决策。
    ///
    /// - Parameters:
    ///   - command: 恢复请求。
    ///   - operatorPrincipal: 已认证的运维主体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 恢复结果。
    /// - Throws: 归属变化、申请缺失或持久化失败时抛出。
    func recover(_ command: V2GroupApprovalRecoveryCommand, operatorPrincipal: String, now: Date) async throws -> V2GroupApprovalRecoveryResult
}

/// 审批恢复服务。
///
/// 恢复过程绝不直接添加成员：被释放的申请必须带着新的操作标识与当时的审核人授权，
/// 重新走一遍普通审批路径。
public struct V2GroupApprovalRecoveryService: Sendable {
    private let stores: [String: any V2GroupApprovalRecoveryStore]
    private let principal: String
    private let now: @Sendable () -> Date
    /// 组合各分片的恢复存储与运维主体。
    ///
    /// - Parameters:
    ///   - stores: 逻辑分片标识到恢复实现的映射。
    ///   - operatorPrincipal: 运维主体标识，需符合通用运维主体格式。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 运维主体格式非法时抛出
    ///   ``V2GroupApprovalRecoveryError/invalidRequest``。
    public init(stores: [String: any V2GroupApprovalRecoveryStore], operatorPrincipal: String,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal)
        else { throw V2GroupApprovalRecoveryError.invalidRequest }
        self.stores = stores; principal = operatorPrincipal; self.now = now
    }
    /// 分页读取待恢复候选。
    ///
    /// - Parameters:
    ///   - scope: 恢复作用域。
    ///   - after: 上一页游标。
    ///   - limit: 本页条数，需落在 `1...100`。
    /// - Returns: 候选分页。
    /// - Throws: 条数越界时抛出 ``V2GroupApprovalRecoveryError/invalidRequest``；
    ///   作用域分片未配置时抛出 ``V2GroupApprovalRecoveryError/unknownShard``。
    public func candidates(scope: V2GroupApprovalRecoveryScope, after: UUID?, limit: Int) async throws -> V2GroupApprovalRecoveryPage {
        guard (1...100).contains(limit) else { throw V2GroupApprovalRecoveryError.invalidRequest }
        guard let store = stores[scope.shardID] else { throw V2GroupApprovalRecoveryError.unknownShard }
        return try await store.candidates(scope: scope, after: after, limit: limit)
    }
    /// 恢复一条审批决策。
    ///
    /// - Parameter command: 恢复请求。
    /// - Returns: 恢复结果。
    /// - Throws: 作用域分片未配置时抛出
    ///   ``V2GroupApprovalRecoveryError/unknownShard``；其余错误来自存储实现。
    public func recover(_ command: V2GroupApprovalRecoveryCommand) async throws -> V2GroupApprovalRecoveryResult {
        guard let store = stores[command.scope.shardID] else { throw V2GroupApprovalRecoveryError.unknownShard }
        return try await store.recover(command, operatorPrincipal: principal, now: now())
    }
}
