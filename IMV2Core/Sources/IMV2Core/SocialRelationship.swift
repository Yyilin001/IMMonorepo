import Foundation

/// 双方关系的可见状态，none 仅表示没有活动关系，不披露对方是否屏蔽当前用户。
public enum V2RelationshipState: String, Codable, Equatable, Sendable {
    /// 没有可见活动关系，不编码屏蔽原因。
    case none
    /// 方向明确的关系请求正在等待处理。
    case pending
    /// 双方关系已经建立。
    case accepted
}

/// 关系业务动作，请求待处理时有方向性。
///
/// 接受与拒绝应由被请求者执行，已建立关系允许任一方移除；模型只描述动作，实际授权由服务端检查。
public enum V2RelationshipAction: String, Codable, Equatable, Sendable {
    /// 向对方发起关系请求。
    case request
    /// 接受收到的关系请求。
    case accept
    /// 拒绝收到的关系请求。
    case reject
    /// 移除已建立关系。
    case remove
}

/// 关系变更的持久业务意图，包含跨重试稳定的操作身份。
public struct V2ChangeRelationshipCommand: Equatable, Sendable {
    /// 请求操作者。
    public let actorUserID: UserID
    /// 本次关系变更稳定幂等身份。
    public let operationID: RelationshipOperationID
    /// 对方用户，必须不同于操作者。
    public let targetUserID: UserID
    /// 请求、接受、拒绝或移除动作。
    public let action: V2RelationshipAction

    /// 保存业务命令。
    ///
    /// - Parameters:
    ///   - actorUserID: 请求操作者。
    ///   - operationID: 本次关系变更稳定幂等身份。
    ///   - targetUserID: 对方用户，必须不同于操作者。
    ///   - action: 请求、接受、拒绝或移除动作。
    ///
    /// 构造器仅拒绝自身目标并抛出 selfTargetingNotAllowed，不检查请求方向、当前关系或隐私策略。
    public init(actorUserID: UserID, operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) throws {
        guard actorUserID != targetUserID else { throw V2SocialRelationshipValidationError.selfTargetingNotAllowed }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
    }
}

/// 当前用户对目标的单向屏蔽意图，不表示对方的隐私状态。
public enum V2UserBlockAction: String, Codable, Equatable, Sendable {
    /// 屏蔽目标用户。
    case block
    /// 解除当前用户对目标的屏蔽。
    case unblock
}

/// 修改当前用户对目标的单向屏蔽状态的幂等命令。
public struct V2ChangeUserBlockCommand: Equatable, Sendable {
    /// 屏蔽策略所有者。
    public let actorUserID: UserID
    /// 本次屏蔽变更稳定身份。
    public let operationID: UserBlockOperationID
    /// 被屏蔽或解除屏蔽的目标。
    public let targetUserID: UserID
    /// 屏蔽或解除动作。
    public let action: V2UserBlockAction

    /// 保存业务命令。
    ///
    /// - Parameters:
    ///   - actorUserID: 屏蔽策略所有者。
    ///   - operationID: 本次屏蔽变更稳定身份。
    ///   - targetUserID: 被屏蔽或解除屏蔽的目标。
    ///   - action: 屏蔽或解除动作。
    ///
    /// 仅检查目标与操作者不同，否则抛出 selfTargetingNotAllowed；不读取当前屏蔽状态或修改关系。
    public init(actorUserID: UserID, operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) throws {
        guard actorUserID != targetUserID else { throw V2SocialRelationshipValidationError.selfTargetingNotAllowed }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
    }
}

/// 关系动作的结果快照，包含对当前操作可披露的最终状态。
public struct V2RelationshipChange: Equatable, Sendable {
    /// 本次操作发起者。
    public let actorUserID: UserID
    /// 关系对方。
    public let targetUserID: UserID
    /// 已处理的动作。
    public let action: V2RelationshipAction
    /// 最终可见关系状态，不携带屏蔽详情。
    public let resultingState: V2RelationshipState
    /// 服务端变更时间。
    public let updatedAt: Date

    /// 保存变更结果。
    ///
    /// - Parameters:
    ///   - actorUserID: 本次操作发起者。
    ///   - targetUserID: 关系对方。
    ///   - action: 已处理的动作。
    ///   - resultingState: 最终可见关系状态，不携带屏蔽详情。
    ///   - updatedAt: 服务端变更时间。
    ///
    /// 直接保存字段，不验证动作与状态对应关系、双方是否不同、日期或事务提交状态。
    public init(actorUserID: UserID, targetUserID: UserID, action: V2RelationshipAction, resultingState: V2RelationshipState, updatedAt: Date) {
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.action = action
        self.resultingState = resultingState
        self.updatedAt = updatedAt
    }
}

/// 单向屏蔽动作的结果快照，只描述操作者拥有的屏蔽关系。
public struct V2UserBlockChange: Equatable, Sendable {
    /// 屏蔽关系所有者。
    public let actorUserID: UserID
    /// 目标用户。
    public let targetUserID: UserID
    /// 已处理的屏蔽动作。
    public let action: V2UserBlockAction
    /// 最终是否被该操作者屏蔽。
    public let isBlocked: Bool
    /// 变更时间。
    public let updatedAt: Date

    /// 保存变更结果。
    ///
    /// - Parameters:
    ///   - actorUserID: 屏蔽关系所有者。
    ///   - targetUserID: 目标用户。
    ///   - action: 已处理的屏蔽动作。
    ///   - isBlocked: 最终是否被该操作者屏蔽。
    ///   - updatedAt: 变更时间。
    ///
    /// 直接保存字段，不强制 action 与 isBlocked 一致，也不验证日期或双方身份差异；权威业务路径负责一致性。
    public init(actorUserID: UserID, targetUserID: UserID, action: V2UserBlockAction, isBlocked: Bool, updatedAt: Date) {
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.action = action
        self.isBlocked = isBlocked
        self.updatedAt = updatedAt
    }
}

/// 关系及屏蔽命令的输入错误。
public enum V2SocialRelationshipValidationError: Error, Equatable, Sendable {
    /// 目标与操作者相同，不能通过这些命令操作自身关系。
    case selfTargetingNotAllowed
}
