import Foundation
import IMV2Core

/// 角色策略恢复请求。
///
/// 只有本地存储在获取账号、成员关系与同步代次栅栏之后才会签发它。
/// 该令牌只标识本地意图，并不是服务端授权或一次已完成网络读取的证明。
public struct V2RolePolicyRecoveryRequest: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 本次恢复请求标识。
    let requestID: UUID
    /// 本地安装绑定标识。
    let installationBinding: String
    /// 目标用户。
    let userID: UserID
    /// 请求时的成员修订。
    let membershipRevision: Int64
    /// 成员关系来源事件标识。
    let membershipSourceEventID: String
    /// 请求时的同步代次。
    let generation: Int64
    /// 已尝试次数。
    let attemptCount: Int
}

/// 角色策略恢复错误。
public enum V2RolePolicyRecoveryError: Error, Equatable, Sendable {
    /// 账号当前不可用。
    case accountUnavailable
    /// 房间未授权或已不可访问。
    case roomUnauthorized
    /// 分页或批量上限非法。
    case invalidLimit
    /// 服务端返回的基线不合法。
    case invalidBaseline
    /// 时刻字段异常。
    case invalidDate
}

/// 一次恢复尝试的处置方式。
public enum V2RolePolicyRecoveryDisposition: Sendable {
    /// 在指定时刻重试。
    case retry(at: Date)
    /// 暂停等待人工处理。
    case pause
    /// 判定为未授权，停止恢复。
    case unauthorized
}

/// 客户端可见的角色策略恢复状态。
public enum V2ClientRolePolicyRecoveryState: Equatable, Sendable {
    /// 恢复能力当前不可用。
    case unavailable
    /// 需要等待本地同步推进后再决定。
    case waitingForSynchronization
    /// 需要向服务端请求基线。
    case needed
    /// 已安排下一次尝试。
    case pending(nextAttemptAt: Date)
    /// 已暂停。
    case paused
    /// 已具备可用策略。
    case ready
}

/// 群角色策略状态。
///
/// 可见策略与恢复状态取自同一次 SQLite 快照，保证两者相互一致。
public struct V2ClientGroupRolePolicyState: Equatable, Sendable {
    /// 当前可见的角色策略。
    public let policies: [V2ClientGroupRolePolicy]
    /// 当前恢复状态。
    public let recovery: V2ClientRolePolicyRecoveryState

    /// 保存策略与恢复状态。
    ///
    /// - Parameters:
    ///   - policies: 可见策略。
    ///   - recovery: 恢复状态。
    public init(policies: [V2ClientGroupRolePolicy], recovery: V2ClientRolePolicyRecoveryState) {
        self.policies = policies
        self.recovery = recovery
    }
}
