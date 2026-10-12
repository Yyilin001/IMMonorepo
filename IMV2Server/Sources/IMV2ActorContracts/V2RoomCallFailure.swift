/// 能力的重试语义由实现指定，不由调用方指定。
public enum V2RoomReplayPolicy: String, Codable, Sendable {
    case readOnly
    case durableIdempotent
    case noAutomaticRetry
}

/// 有限的运行时错误集合；传输消息绝不携带任意数据库错误。
public enum V2RoomFailureReason: String, Codable, Sendable {
    case staleActivation
    case notReady
    case retired
    case authorityLost
    case unavailable
    case overloaded
    case deadlineExceeded
    case cancelled
    case notFound
    case forbidden
    case invalidRequest
    case unsupportedVersion
    case idempotencyConflict
}

/// 描述运行时能够证明的事实，而非超时所暗示的结果。
public enum V2RoomCallFailure: Error, Equatable, Codable, Sendable {
    /// 准入从未接受该请求。
    case notAccepted(V2RoomFailureReason)
    /// 事务已明确回滚，不存在持久化副作用。
    case rolledBack(V2RoomFailureReason)
    /// 已分发的写入可能已提交；保持稳定的操作身份。
    case outcomeUnknown
}

public enum V2RoomRetryAction: Equatable, Sendable {
    case returnFailure
    case refreshLocation
    case retryRead
    case retrySameOperation
    case reconcile
}

extension V2RoomCallFailure {
    /// 此分类用于重试；调用方还须执行单调总截止时间和尝试次数限制。
    /// 不会虚构操作 ID。
    public func retryAction(
        policy: V2RoomReplayPolicy,
        hasStableOperationID: Bool
    ) -> V2RoomRetryAction {
        switch self {
        case .outcomeUnknown:
            switch policy {
            case .readOnly: .retryRead
            case .durableIdempotent:
                hasStableOperationID ? .retrySameOperation : .reconcile
            case .noAutomaticRetry: .reconcile
            }
        case .notAccepted(let reason), .rolledBack(let reason):
            switch reason {
            case .staleActivation, .notReady, .retired, .authorityLost, .unavailable:
                .refreshLocation
            case .overloaded, .deadlineExceeded, .cancelled, .notFound, .forbidden,
                 .invalidRequest, .unsupportedVersion, .idempotencyConflict:
                .returnFailure
            }
        }
    }
}

/// 共享数据库批处理器会向每个参与的房间轮次报告事务结果。
/// 结果不明时必须停止所有这些轮次，而不只是当前调用方。
public enum V2RoomTransactionCompletion<Value: Sendable>: Sendable {
    case committed(Value)
    case rolledBack(V2RoomFailureReason)
    case outcomeUnknown
}
