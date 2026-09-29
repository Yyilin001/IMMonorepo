import IMV2ServerContracts
import Foundation
import IMV2Core

/// 运维可重放的持久化工作形态。
///
/// 该词表是封闭集合，使控制面无法把任意表更新变成管理接口。
public enum V2DurableWorkReplayTargetKind: String, CaseIterable, Codable, Equatable, Sendable {
    /// 可靠个人状态事件。
    case userStateEvent = "user_state_event"
    /// 内容审核。
    case contentReview = "content_review"
    /// 媒体扫描。
    case mediaScan = "media_scan"
    /// 媒体清理。
    case mediaPurge = "media_purge"
    /// 已读回执偏好传播。
    case readReceiptPreferencePropagation = "read_receipt_preference_propagation"
    /// 用户投影。
    case userProjection = "user_projection"
}

/// 运维解除暂停行的有界、可复核原因。
///
/// 自由文本的事故说明应留在外部事故系统，不进入运维接口或权威聊天数据库。
public enum V2DurableWorkReplayReason: String, CaseIterable, Codable, Equatable, Sendable {
    /// 依赖服务已恢复。
    case dependencyRecovered = "dependency_recovered"
    /// 数据已修复。
    case dataRepaired = "data_repaired"
    /// 原判定为误报。
    case falsePositive = "false_positive"
}

/// 一次重放的目标描述。
public struct V2DurableWorkReplayTarget: Equatable, Sendable {
    /// 目标工作类型。
    public let kind: V2DurableWorkReplayTargetKind
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 目标用户；仅部分类型需要。
    public let targetUserID: UserID?
    /// 投影类型；仅个人事件需要。
    public let projectionKind: String?

    /// 按工作类型校验并保存目标描述。
    ///
    /// 内容审核、媒体扫描与媒体清理不允许携带用户或投影类型；
    /// 回执偏好传播与用户投影必须携带用户且不允许投影类型；个人事件则两者都必须给出，
    /// 且投影类型必须属于可靠个人事件的封闭词表。
    ///
    /// - Parameters:
    ///   - kind: 目标工作类型。
    ///   - sourceEventID: 来源事件标识。
    ///   - targetUserID: 目标用户。
    ///   - projectionKind: 投影类型。
    /// - Throws: 字段组合不符合对应类型要求时抛出
    ///   ``V2DurableWorkReplayValidationError/invalidTargetShape``。
    public init(
        kind: V2DurableWorkReplayTargetKind,
        sourceEventID: EventID,
        targetUserID: UserID? = nil,
        projectionKind: String? = nil
    ) throws {
        switch kind {
        case .contentReview, .mediaScan, .mediaPurge:
            guard targetUserID == nil, projectionKind == nil else {
                throw V2DurableWorkReplayValidationError.invalidTargetShape
            }
        case .readReceiptPreferencePropagation, .userProjection:
            guard targetUserID != nil, projectionKind == nil else {
                throw V2DurableWorkReplayValidationError.invalidTargetShape
            }
        case .userStateEvent:
            guard targetUserID != nil,
                  let projectionKind,
                  V2UserStateEventKind(rawValue: projectionKind) != nil
            else { throw V2DurableWorkReplayValidationError.invalidTargetShape }
        }
        self.kind = kind
        self.sourceEventID = sourceEventID
        self.targetUserID = targetUserID
        self.projectionKind = projectionKind
    }
}

/// 一次运维重放命令。
public struct V2DurableWorkReplayCommand: Equatable, Sendable {
    /// 本次重放的幂等操作标识。
    public let operationID: UUID
    /// 重放目标。
    public let target: V2DurableWorkReplayTarget
    /// 重放原因。
    public let reason: V2DurableWorkReplayReason

    /// 保存重放命令，不做取值校验。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - target: 重放目标。
    ///   - reason: 重放原因。
    public init(operationID: UUID, target: V2DurableWorkReplayTarget, reason: V2DurableWorkReplayReason) {
        self.operationID = operationID
        self.target = target
        self.reason = reason
    }
}

/// 运维重放的结论。
public enum V2DurableWorkReplayOutcome: String, Codable, Equatable, Sendable {
    /// 暂停的行已回到 `pending` 状态，重试预算已重置。
    case requeued
    /// 目标并未处于暂停状态。
    ///
    /// 该结论是持久化的审计证据而非错误：它让重试与并发的应急响应者行为可预期。
    case notPaused = "not_paused"
}

/// 单次运维重放的结果。
public struct V2DurableWorkReplayResult: Equatable, Sendable {
    /// 本次重放的幂等操作标识。
    public let operationID: UUID
    /// 重放结论。
    public let outcome: V2DurableWorkReplayOutcome
    /// 本次调用是否命中已有结果。
    public let wasIdempotent: Bool

    /// 保存重放结果。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - outcome: 重放结论。
    ///   - wasIdempotent: 是否命中已有结果。
    public init(operationID: UUID, outcome: V2DurableWorkReplayOutcome, wasIdempotent: Bool) {
        self.operationID = operationID
        self.outcome = outcome
        self.wasIdempotent = wasIdempotent
    }
}

/// 重放目标校验错误。
public enum V2DurableWorkReplayValidationError: Error, Equatable, Sendable {
    /// 字段组合与工作类型不匹配。
    case invalidTargetShape
}

/// 运维重放存储错误。
public enum V2DurableWorkReplayStoreError: Error, Equatable, Sendable {
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 一次"按来源事件"的批量运维重放命令。
///
/// 这是把"修好根因之后还要逐行重放"的运维负担降下来的一步：同一个来源事件可能对应
/// 多条暂停行（例如同一次成员变化需要通知多个用户），按事件重放一次即可推进有界的一批。
/// 选择面仍然是**精确且可枚举**的：只有这一个事件，没有扫描、没有自由筛选、没有自由文本。
public struct V2DurableWorkEventReplayCommand: Equatable, Sendable {
    /// 单次批量允许重放的最大行数。
    public static let maximumTargets = 500

    /// 本次批量重放的幂等操作标识。
    public let operationID: UUID
    /// 目标工作类型；仅支持按事件定位工作的类型。
    public let kind: V2DurableWorkReplayTargetKind
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 重放原因。
    public let reason: V2DurableWorkReplayReason
    /// 本批最多重放的行数。
    public let limit: Int

    /// 校验并保存批量重放命令。
    ///
    /// 只接受按事件定位工作的类型：个人事件、内容审核、媒体扫描与媒体清理。
    /// 回执偏好传播与用户投影是按用户定位的，批量语义不明确，必须继续逐目标重放。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - kind: 目标工作类型。
    ///   - sourceEventID: 来源事件标识。
    ///   - reason: 重放原因。
    ///   - limit: 本批最多重放的行数，需落在 1...``maximumTargets``。
    /// - Throws: 类型不支持批量或行数越界时抛出
    ///   ``V2DurableWorkReplayValidationError/invalidTargetShape``。
    public init(
        operationID: UUID,
        kind: V2DurableWorkReplayTargetKind,
        sourceEventID: EventID,
        reason: V2DurableWorkReplayReason,
        limit: Int
    ) throws {
        switch kind {
        case .userStateEvent, .contentReview, .mediaScan, .mediaPurge:
            break
        case .readReceiptPreferencePropagation, .userProjection:
            throw V2DurableWorkReplayValidationError.invalidTargetShape
        }
        guard (1 ... Self.maximumTargets).contains(limit) else {
            throw V2DurableWorkReplayValidationError.invalidTargetShape
        }
        self.operationID = operationID
        self.kind = kind
        self.sourceEventID = sourceEventID
        self.reason = reason
        self.limit = limit
    }
}

/// 一次批量重放的结论。
///
/// 逐行的审计与幂等由派生的行级操作标识保证；本结果是**当下状态**的汇总：重复调用不会
/// 重复重放（已经回到 `pending` 的行不再是暂停行），因此返回的是"这次实际推进了多少"。
public struct V2DurableWorkEventReplayResult: Equatable, Sendable {
    /// 本次批量重放的操作标识。
    public let operationID: UUID
    /// 实际被重新排队的行数。
    public let requeued: Int
    /// 命中的行中有多少已经不处于暂停状态。
    public let notPaused: Int
    /// 该事件是否还有超出本批上限的暂停行。
    public let hasMore: Bool

    /// 保存批量重放结论。
    ///
    /// - Parameters:
    ///   - operationID: 批量重放的操作标识。
    ///   - requeued: 实际重新排队的行数。
    ///   - notPaused: 命中但不处于暂停状态的行数。
    ///   - hasMore: 是否还有超出上限的暂停行。
    public init(operationID: UUID, requeued: Int, notPaused: Int, hasMore: Bool) {
        self.operationID = operationID
        self.requeued = requeued
        self.notPaused = notPaused
        self.hasMore = hasMore
    }
}

/// 运维重放的持久化能力。
///
/// 实现必须原子地记录运维操作并执行重放，因此审计记录不会成为「并未真正提交的重放」的证据，
/// 同一操作的重复调用也会得到稳定结果。
public protocol V2DurableWorkReplayStore: Sendable {
    /// 执行一次运维重放。
    ///
    /// - Parameters:
    ///   - command: 重放命令。
    ///   - operatorPrincipal: 已认证的运维主体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 重放结果。
    /// - Throws: 幂等冲突或持久化失败时抛出。
    func replay(
        _ command: V2DurableWorkReplayCommand,
        operatorPrincipal: String,
        now: Date
    ) async throws -> V2DurableWorkReplayResult

    /// 执行一次按来源事件的批量重放。
    ///
    /// - Parameters:
    ///   - command: 批量重放命令。
    ///   - operatorPrincipal: 已认证的运维主体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 本次批量重放结论。
    /// - Throws: 类型不支持批量、行数越界或持久化失败时抛出。
    func replayEvent(
        _ command: V2DurableWorkEventReplayCommand,
        operatorPrincipal: String,
        now: Date
    ) async throws -> V2DurableWorkEventReplayResult
}

/// 运维重放服务，固定运维主体后转交存储。
public struct V2DurableWorkOperatorReplayService: Sendable {
    private let store: any V2DurableWorkReplayStore
    private let roomOwnerStores: [String: any V2DurableWorkReplayStore]
    private let operatorPrincipal: String
    private let now: @Sendable () -> Date

    /// 组合重放存储与运维主体。
    ///
    /// - Parameters:
    ///   - store: 控制库内工作的重放存储。
    ///   - roomOwnerStores: 房间分片到来源库重放存储的映射，个人事件必须明确选择来源。
    ///   - operatorPrincipal: 运维主体标识，需满足 ``isValidPrincipal(_:)``。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 主体格式非法时直接失败，避免把未校验的身份带入审计记录。
    public init(
        store: any V2DurableWorkReplayStore,
        roomOwnerStores: [String: any V2DurableWorkReplayStore] = [:],
        operatorPrincipal: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal))
        self.store = store
        self.roomOwnerStores = roomOwnerStores
        self.operatorPrincipal = operatorPrincipal
        self.now = now
    }

    /// 执行一次运维重放。
    ///
    /// - Parameter command: 重放命令。
    /// - Returns: 重放结果。
    /// - Throws: 存储实现抛出的错误。
    public func replay(_ command: V2DurableWorkReplayCommand, sourceShardID: String? = nil) async throws -> V2DurableWorkReplayResult {
        try await selectedStore(kind: command.target.kind, sourceShardID: sourceShardID).replay(command, operatorPrincipal: operatorPrincipal, now: now())
    }

    /// 执行一次按来源事件的批量重放。
    ///
    /// - Parameter command: 批量重放命令。
    /// - Returns: 本次批量重放结论。
    /// - Throws: 存储实现抛出的错误。
    public func replayEvent(_ command: V2DurableWorkEventReplayCommand, sourceShardID: String? = nil) async throws -> V2DurableWorkEventReplayResult {
        try await selectedStore(kind: command.kind, sourceShardID: sourceShardID).replayEvent(command, operatorPrincipal: operatorPrincipal, now: now())
    }

    private func selectedStore(kind: V2DurableWorkReplayTargetKind, sourceShardID: String?) throws -> any V2DurableWorkReplayStore {
        if kind == .userStateEvent {
            guard let sourceShardID, let owner = roomOwnerStores[sourceShardID] else {
                throw V2DurableWorkReplayValidationError.invalidTargetShape
            }
            return owner
        }
        guard sourceShardID == nil else { throw V2DurableWorkReplayValidationError.invalidTargetShape }
        return store
    }

    /// 校验运维主体格式。
    ///
    /// 允许长度 1 至 128 字节，字符集限定为字母、数字以及 `-`、`_`、`.`、`:`。
    ///
    /// - Parameter value: 待校验的主体标识。
    /// - Returns: 满足约束时为 `true`。
    public static func isValidPrincipal(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) ||
            ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) ||
            $0 == "-" || $0 == "_" || $0 == "." || $0 == ":"
        }
    }
}
