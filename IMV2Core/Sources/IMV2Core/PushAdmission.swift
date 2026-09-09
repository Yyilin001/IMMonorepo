import Foundation

/// 推送活动的不透明身份，仅用于准入上下文，不携带消息内容。
///
/// 合成 Codable 解码不执行普通构造器的非空校验。
public struct V2PushCampaignID: Hashable, Codable, Sendable {
    /// 保留原样的活动标识。
    public let rawValue: String
    /// 要求裁剪后非空，否则抛出 invalidIdentifier；保存原字符串，不自动裁剪。
    public init(rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2CoreError.invalidIdentifier }
        self.rawValue = rawValue
    }
}

/// 设备推送工作与新密钥操作的预算快照，两个额度独立计数。
public struct V2PushDeviceBudget: Equatable, Sendable {
    /// 工作总额度，允许零。
    public let maxWorkUnits: Int
    /// 已使用工作额度，允许大于总额度表示耗尽状态。
    public let usedWorkUnits: Int
    /// 新密钥操作总额度，允许零。
    public let maxNewKeyOperations: Int
    /// 已使用的新密钥操作额度。
    public let usedNewKeyOperations: Int

    /// 要求四个预算数值非负，否则抛出 invalidNonNegativeValue；使用量默认零，不要求使用量小于上限。
    public init(maxWorkUnits: Int, usedWorkUnits: Int = 0, maxNewKeyOperations: Int, usedNewKeyOperations: Int = 0) throws {
        guard maxWorkUnits >= 0, usedWorkUnits >= 0, maxNewKeyOperations >= 0, usedNewKeyOperations >= 0 else { throw V2CoreError.invalidNonNegativeValue }
        self.maxWorkUnits = maxWorkUnits
        self.usedWorkUnits = usedWorkUnits
        self.maxNewKeyOperations = maxNewKeyOperations
        self.usedNewKeyOperations = usedNewKeyOperations
    }
}

/// 一次通用唤醒的准入输入，不携带消息、发送者或房间内容。
public struct V2PushAdmissionRequest: Equatable, Sendable {
    /// 推送活动身份，评估器不自行查询该活动是否开启。
    public let campaignID: V2PushCampaignID
    /// 本次唤醒是否额外消耗一个新密钥操作额度。
    public let requiresNewKeyOperation: Bool

    /// 保存活动与密钥工作需求，不执行推送或扣减预算。
    public init(campaignID: V2PushCampaignID, requiresNewKeyOperation: Bool) {
        self.campaignID = campaignID
        self.requiresNewKeyOperation = requiresNewKeyOperation
    }
}

/// 通用推送提示被抑制的原因，不代表可靠消息同步失败。
public enum V2PushSuppressionReason: Equatable, Sendable {
    /// 活动未启用。
    case campaignDisabled
    /// 目标用户将会话设为免打扰，只抑制尽力而为的唤醒，后续可靠同步仍可进行。
    case conversationMuted
    /// 无法取得设备预算，由外层准入流程报告。
    case deviceBudgetUnavailable
    /// 设备工作额度已经耗尽。
    case deviceWorkBudgetExhausted
    /// 本次需要的新密钥操作额度已经耗尽。
    case deviceNewKeyBudgetExhausted
    /// 设备没有当前提供方端点，当前唤醒不再尝试，不触发可靠房间投递重试。
    case endpointUnavailable
    /// 提供方确认端点不可用，外层流程应先禁用端点再记录此抑制原因。
    case endpointRejected
}

/// 准入计算的允许或抑制结果，不执行持久化。
public enum V2PushAdmission: Equatable, Sendable {
    /// 允许本次唤醒并返回扣除相应额度后的预算快照，调用方负责原子保存。
    case allowed(nextBudget: V2PushDeviceBudget)
    /// 本次提示被抑制，附带原因。
    case suppressed(V2PushSuppressionReason)
}

/// 在密钥查找或提供方请求之前执行的纯预算准入计算。
///
/// 只检查活动开关及设备预算，会话免打扰、端点状态等检查由外层完成。
public enum V2PushAdmissionEvaluator {
    /// 按活动开关、工作额度、新密钥额度的顺序判断是否允许唤醒。
    ///
    /// - Parameters:
    ///   - campaignEnabled: 调用方已查询的活动启用状态。
    ///   - request: 本次活动身份及新密钥操作需求。
    ///   - budget: 同一设备当前预算快照。
    /// - Returns: 首个失败条件对应的抑制原因；通过时工作使用量加一，按需将新密钥使用量加一。
    /// - Throws: 返回预算构造错误，正常已校验输入在严格小于额度的检查后不会递增溢出。
    ///
    /// 不读取 campaignID 对应配置，不修改原快照，也不提供并发扣减互斥；持久化所有者必须协调检查与提交。
    public static func evaluate(
        campaignEnabled: Bool,
        request: V2PushAdmissionRequest,
        budget: V2PushDeviceBudget
    ) throws -> V2PushAdmission {
        guard campaignEnabled else { return .suppressed(.campaignDisabled) }
        guard budget.usedWorkUnits < budget.maxWorkUnits else { return .suppressed(.deviceWorkBudgetExhausted) }
        guard !request.requiresNewKeyOperation || budget.usedNewKeyOperations < budget.maxNewKeyOperations else {
            return .suppressed(.deviceNewKeyBudgetExhausted)
        }
        return .allowed(nextBudget: try V2PushDeviceBudget(
            maxWorkUnits: budget.maxWorkUnits,
            usedWorkUnits: budget.usedWorkUnits + 1,
            maxNewKeyOperations: budget.maxNewKeyOperations,
            usedNewKeyOperations: budget.usedNewKeyOperations + (request.requiresNewKeyOperation ? 1 : 0)
        ))
    }
}
