import Foundation
import IMV2Core

/// 账号边缘限流判定结果。
public enum V2AccountEdgeClientRateLimitResult: Equatable, Sendable {
    /// 本次请求被允许并已计入窗口。
    case allowed
    /// 本次请求被拒绝，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
}

/// 跨副本共享的账号边缘请求预算能力。
///
/// 输入是已通过认证的边缘地址或连接身份，持久化只保存其带密钥摘要。
public protocol V2AccountEdgeClientRateLimiting: Sendable {
    /// 消耗一次按客户端地址计费的额度。
    ///
    /// - Parameter address: 已通过边缘校验的客户端地址。
    /// - Returns: 允许或限流结果。
    /// - Throws: 密钥派生、时刻编码或存储不可用时抛出。
    func consume(address: V2AccountEdgeClientAddress) async throws -> V2AccountEdgeClientRateLimitResult
}

/// 跨副本共享的已认证账号请求预算能力。
public protocol V2AuthenticatedAccountRateLimiting: Sendable {
    /// 消耗指定作用域与代价的已认证额度。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接的用户与设备身份。
    ///   - scope: 计费作用域，例如某类账号接口。
    ///   - cost: 本次消耗的额度，需大于零且不超过窗口上限。
    /// - Returns: 允许或限流结果。
    /// - Throws: 作用域或代价非法、时刻编码失败或存储不可用时抛出。
    func consume(
        identity: V2AuthenticatedConnection,
        scope: String,
        cost: Int
    ) async throws -> V2AccountEdgeClientRateLimitResult
}
