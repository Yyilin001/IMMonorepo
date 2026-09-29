import Foundation
import IMV2Core

/// 已认证连接准入策略。
public struct V2AuthenticatedConnectionAdmissionPolicy: Equatable, Sendable {
    /// 单设备允许的并发连接数。
    public let maximumConnectionsPerDevice: Int
    /// 单用户允许的并发连接数。
    public let maximumConnectionsPerUser: Int

    /// 校验并保存准入策略。
    ///
    /// - Parameters:
    ///   - maximumConnectionsPerDevice: 单设备连接上限，需大于零。
    ///   - maximumConnectionsPerUser: 单用户连接上限，需不小于单设备上限。
    ///
    /// 参数不满足上述关系时直接失败，避免出现用户上限小于设备上限的矛盾配置。
    public init(maximumConnectionsPerDevice: Int, maximumConnectionsPerUser: Int) {
        precondition(
            maximumConnectionsPerDevice > 0 &&
            maximumConnectionsPerUser >= maximumConnectionsPerDevice
        )
        self.maximumConnectionsPerDevice = maximumConnectionsPerDevice
        self.maximumConnectionsPerUser = maximumConnectionsPerUser
    }
}

/// 已认证连接租约的结果。
public enum V2AuthenticatedConnectionLeaseOutcome: Equatable, Sendable {
    /// 准入通过，并给出租约到期时刻。
    case accepted(expiresAt: Date)
    /// 准入被拒绝。
    case rejected
}
