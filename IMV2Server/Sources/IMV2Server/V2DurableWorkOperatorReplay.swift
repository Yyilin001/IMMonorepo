import Foundation
import IMV2Core

/// 运维可重放的持久化工作形态。
///
/// 该词表是封闭集合，使控制面无法把任意表更新变成管理接口。
public enum V2DurableWorkReplayTargetKind: String, CaseIterable, Codable, Equatable, Sendable {
    /// 房间发件箱。
    case roomOutbox = "room_outbox"
    /// 扇出投递。
    case fanoutDelivery = "fanout_delivery"
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
    /// 投影类型；仅扇出投递需要。
    public let projectionKind: String?

    /// 按工作类型校验并保存目标描述。
    ///
    /// 房间发件箱、内容审核、媒体扫描与媒体清理不允许携带用户或投影类型；
    /// 回执偏好传播与用户投影必须携带用户且不允许投影类型；扇出投递则两者都必须给出，
    /// 且投影类型不超过 64 字节。
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
        case .roomOutbox, .contentReview, .mediaScan, .mediaPurge:
            guard targetUserID == nil, projectionKind == nil else {
                throw V2DurableWorkReplayValidationError.invalidTargetShape
            }
        case .readReceiptPreferencePropagation, .userProjection:
            guard targetUserID != nil, projectionKind == nil else {
                throw V2DurableWorkReplayValidationError.invalidTargetShape
            }
        case .fanoutDelivery:
            guard targetUserID != nil,
                  let projectionKind,
                  !projectionKind.isEmpty,
                  projectionKind.utf8.count <= 64
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
}

/// 运维重放服务，固定运维主体后转交存储。
public struct V2DurableWorkOperatorReplayService: Sendable {
    private let store: any V2DurableWorkReplayStore
    private let operatorPrincipal: String
    private let now: @Sendable () -> Date

    /// 组合重放存储与运维主体。
    ///
    /// - Parameters:
    ///   - store: 执行重放的持久化存储。
    ///   - operatorPrincipal: 运维主体标识，需满足 ``isValidPrincipal(_:)``。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 主体格式非法时直接失败，避免把未校验的身份带入审计记录。
    public init(
        store: any V2DurableWorkReplayStore,
        operatorPrincipal: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal))
        self.store = store
        self.operatorPrincipal = operatorPrincipal
        self.now = now
    }

    /// 执行一次运维重放。
    ///
    /// - Parameter command: 重放命令。
    /// - Returns: 重放结果。
    /// - Throws: 存储实现抛出的错误。
    public func replay(_ command: V2DurableWorkReplayCommand) async throws -> V2DurableWorkReplayResult {
        try await store.replay(command, operatorPrincipal: operatorPrincipal, now: now())
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
