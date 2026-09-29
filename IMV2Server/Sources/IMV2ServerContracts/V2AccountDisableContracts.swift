import Foundation
import IMV2Core

/// 由单独认证的运维控制面提供的有界、可审计原因。
///
/// 自由文本的运维记录应留在外部工单系统，永远不进入账号数据库。
public enum V2AccountDisableReason: String, Codable, CaseIterable, Sendable {
    /// 用户本人请求停用。
    case userRequested = "user_requested"
    /// 凭据疑似泄漏。
    case credentialCompromise = "credential_compromise"
    /// 依据策略执行。
    case policyEnforcement = "policy_enforcement"
}

/// 一次账号停用命令。
public struct V2AccountDisableCommand: Sendable {
    /// 目标用户。
    public let userID: UserID
    /// 本次停用的幂等操作标识。
    public let operationID: UUID
    /// 停用原因。
    public let reason: V2AccountDisableReason

    /// 校验并保存停用命令。
    ///
    /// - Parameters:
    ///   - userID: 目标用户，需可解析为 UUID。
    ///   - operationID: 幂等操作标识。
    ///   - reason: 停用原因。
    /// - Throws: 用户标识非法时抛出 ``V2AccountDisableError/invalidUserID``。
    public init(userID: UserID, operationID: UUID, reason: V2AccountDisableReason) throws {
        guard UUID(uuidString: userID.rawValue) != nil else { throw V2AccountDisableError.invalidUserID }
        self.userID = userID
        self.operationID = operationID
        self.reason = reason
    }
}

/// 账号停用结果。
public enum V2AccountDisableOutcome: Equatable, Sendable {
    /// 本次调用实际停用了账号。
    case disabled(disabledAt: Date)
    /// 同一操作此前已执行，返回其原有停用时刻。
    case idempotent(disabledAt: Date)
    /// 账号此前已因其他原因停用，返回既有停用时刻。
    case alreadyDisabled(disabledAt: Date)
}

/// 账号停用错误。
public enum V2AccountDisableError: Error, Equatable, Sendable {
    /// 用户标识不是合法 UUID。
    case invalidUserID
    /// 运维主体标识不满足格式要求。
    case invalidOperatorPrincipal
    /// 同一操作标识已用于其他账号。
    case operationConflict
    /// 数据库或时刻编码当前不可用。
    case unavailable
}

/// 运维边界刻意只包含一个破坏性动作：永久停用单个账号。
///
/// 它不能重新启用账号、删除保留数据，也不接受原始 SQL 或批量操作；
/// 恢复流程由单独定义的产品与审计工作流负责。
public protocol V2AccountDisabling: Sendable {
    /// 停用指定账号。
    ///
    /// - Parameter command: 已校验的停用命令。
    /// - Returns: 停用结果。
    /// - Throws: 操作冲突或存储不可用时抛出。
    func disable(_ command: V2AccountDisableCommand) async throws -> V2AccountDisableOutcome
}
