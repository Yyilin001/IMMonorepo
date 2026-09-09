import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 将业务 HTTP 凭证读取与响应处理绑定到同一个账户代际。
///
/// 客户端的凭证提供者与 HTTP 传输应复用同一实例，防止旧账户所有者取得新登录凭证或接纳迟到响应。
/// 401 可触发共享刷新，但本适配器不重放原业务请求，避免重复写入或消耗一次性媒体授权。
public struct V2SessionHTTPAuthorization: Sendable,
    V2ClientPushEndpointCredentialProvider, V2ClientDeviceSessionCredentialProvider,
    V2ClientMediaEdgeCredentialProvider, V2ClientPushEndpointHTTPTransport,
    V2ClientDeviceSessionHTTPTransport, V2ClientGroupInvitationHTTPTransport,
    V2ClientMediaEdgeHTTPTransport
{
    /// 凭证及刷新轮换的唯一会话所有者。
    private let session: V2AuthSession
    /// 本适配器固定绑定的账户代际，创建后不随新登录变化。
    private let epoch: V2AuthSessionEpoch
    /// 执行一次 HTTP 请求的底层传输。
    private let transport: any V2AuthHTTPTransport

    /// 绑定认证会话、固定代际与业务 HTTP 传输，不立即读取凭证。
    ///
    /// - Parameters:
    ///   - session: 负责一致凭证读取与轮换的会话。
    ///   - epoch: 本客户端生命周期允许使用的代际。
    ///   - transport: 默认使用账户服务的隔离 URLSession 传输。
    public init(session: V2AuthSession, epoch: V2AuthSessionEpoch,
                transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()) {
        self.session = session
        self.epoch = epoch
        self.transport = transport
    }

    /// 读取本代际的一致令牌与设备身份，转换为推送端点凭证；代际失效映射为取消。
    public func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials {
        let credentials = try await credentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    /// 读取本代际的一致令牌与设备身份，转换为设备管理凭证；不允许借用后续登录的凭证。
    public func deviceSessionCredentials() async throws -> V2ClientDeviceSessionCredentials {
        let credentials = try await credentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    /// 读取本代际的一致令牌与设备身份，转换为媒体服务凭证；必要时由认证会话刷新。
    public func mediaEdgeCredentials() async throws -> V2ClientMediaEdgeCredentials {
        let credentials = try await credentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    /// 在请求前后校验账户代际，并处理业务接口的 401 响应。
    ///
    /// - Parameter request: 已设置非空 Bearer 令牌与可解析 X-IM-Device-ID 的完整请求。
    /// - Returns: 原始响应体与 HTTP 响应；刷新成功后仍返回原 401，不自动重发请求。
    /// - Throws: 凭证头格式错误、代际失效对应的 CancellationError、传输错误或刷新错误。
    ///
    /// 此方法只校验请求头格式；401 时才由会话检查设备及被拒绝令牌是否仍适用。
    /// 旧令牌的迟到 401 不能发起额外轮换，只有刷新接口的明确拒绝才允许终止会话。
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await requireCurrent()
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer "), authorization.count > 7,
              let rawDevice = request.value(forHTTPHeaderField: "X-IM-Device-ID"),
              let device = try? DeviceID(rawDevice)
        else { throw V2AuthSessionError.malformedCredentials }
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.data(for: request) }
        catch {
            try await requireCurrent()
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw error
        }
        try await requireCurrent()
        if result.1.statusCode == 401 {
            // An expired access token alone does not prove session revocation.
            // Only the refresh contract can make that terminal decision. Do
            // not replay an application write or one-use media grant here.
            do {
                try await session.refreshAfterHTTPUnauthorized(
                    ifCurrent: epoch, rejectedAccessToken: String(authorization.dropFirst(7)),
                    deviceID: device
                )
            } catch V2AuthSessionError.sessionInvalidated {
                throw CancellationError()
            }
            try await requireCurrent()
        }
        return result
    }

    /// 在一致凭证读取前后校验固定代际，并要求返回元组的代际相同。
    ///
    /// - Returns: 当前所有者的一致实时凭证视图，用于转换为各业务凭证。
    /// - Throws: 代际失效转换为取消；当前代际的终态及存储不可用错误保留原语义。
    private func credentials() async throws -> V2ClientRealtimeCredentials {
        try await requireCurrent()
        let credentials: V2ClientRealtimeCredentials
        do { credentials = try await session.realtimeCredentials() }
        catch {
            // Preserve terminal/locked-store errors from this epoch. A
            // replacement login is instead cancellation of the old owner.
            if case V2AuthSessionError.sessionInvalidated = error { throw CancellationError() }
            throw error
        }
        try await requireCurrent()
        guard credentials.sessionEpoch == epoch else { throw CancellationError() }
        return credentials
    }

    /// 在跨 actor 代际校验前后检查任务取消，将 sessionInvalidated 转换为 CancellationError。
    private func requireCurrent() async throws {
        try Task.checkCancellation()
        do { try await session.requireCurrentEpoch(epoch) }
        catch V2AuthSessionError.sessionInvalidated { throw CancellationError() }
        try Task.checkCancellation()
    }
}
