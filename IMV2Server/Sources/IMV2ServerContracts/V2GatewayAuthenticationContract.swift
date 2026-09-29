import Foundation
import IMV2Core

/// 认证适配器返回的可信用户身份与会话有效期。
///
/// 用户身份来自注入的认证边界，不能直接从未认证的 protobuf 载荷读取。构造此值本身不执行凭证校验。
public struct V2GatewayAuthentication: Equatable, Sendable {
    /// 认证后的用户身份。
    public let userID: UserID
    /// 会话失效时间；`nil` 仅供明确允许永不过期的适配器使用。
    public let expiresAt: Date?

    /// 保存一次认证读取的结果。
    ///
    /// - Parameters:
    ///   - userID: 经认证确定的用户。
    ///   - expiresAt: 同一次撤销一致性读取所得的期限，`nil` 表示适配器明确不设置期限。
    public init(userID: UserID, expiresAt: Date?) {
        self.userID = userID
        self.expiresAt = expiresAt
    }
}

/// Gateway 的认证依赖，负责将访问令牌和设备绑定转换为可信会话结果。
public protocol V2GatewayAuthenticator: Sendable {
    /// 认证访问令牌及其设备绑定。
    ///
    /// - Parameters:
    ///   - accessToken: 客户端提交的访问令牌，不应进入日志或业务命令载荷。
    ///   - deviceID: 本次连接请求绑定的设备。
    /// - Returns: 必须来自同一次撤销一致性读取的身份与有效期。
    /// - Throws: 确定凭证无效时抛出 `V2GatewayAuthenticationError.unauthenticated`；基础设施错误应保留独立错误语义。
    ///
    /// Gateway 对确定的凭证拒绝生成不可重试响应；数据库暂时失败不能被伪装成凭证失效。
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication
}

/// Gateway 认证的配置、凭证与持久化状态错误。
public enum V2GatewayAuthenticationError: Error, Equatable, Sendable {
    /// HMAC 密钥编码无效或解码后不足 32 字节。
    case invalidKeyMaterial
    /// 无法认证令牌和设备；当前适配器也以此报告非 SQL 数据库配置或无法转换为 UUID 的设备标识。
    case unauthenticated
    /// 读取到的用户或时间数据不可表示，或本地时钟不能安全用于 PostgreSQL 时间参数。
    case corruptPersistenceState
}
