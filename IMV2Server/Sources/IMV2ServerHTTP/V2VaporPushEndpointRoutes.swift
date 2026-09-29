import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import Vapor
import HTTPTypes

/// 设备推送端点写入请求体。
///
/// - Parameters:
///   - provider: 目标推送服务厂商。
///   - environment: 推送环境（生产或沙箱）。
///   - token: 设备平台发放的推送 token。
public struct V2PushEndpointHTTPRequest: Content, Sendable {
    public let provider: V2PushEndpointProvider
    public let environment: V2PushEndpointEnvironment
    public let token: String

    public init(provider: V2PushEndpointProvider, environment: V2PushEndpointEnvironment, token: String) {
        self.provider = provider
        self.environment = environment
        self.token = token
    }
}

/// 设备端点路由，提供对当前会话设备的推送端点的注册与注销。
///
/// 两个接口均要求已完成 `account-edge` 鉴权，响应使用 `Cache-Control: no-store`
/// 和 `Pragma: no-cache`，不返回端点材料，避免服务端敏感内容泄漏。
public struct V2VaporPushEndpointRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let store: any V2PushDeviceEndpointStore
    private let now: @Sendable () -> Date

    /// 初始化。
    ///
    /// - Parameters:
    ///   - authenticator: 鉴权适配器。
    ///   - store: 端点存储服务。
    ///   - now: 当前时间提供者，便于测试。
    public init(
        authenticator: any V2GatewayAuthenticator,
        store: any V2PushDeviceEndpointStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authenticator = authenticator
        self.store = store
        self.now = now
    }

    /// 挂载以下端点：
    /// - `PUT /v2/push-endpoint`：写入当前设备推送端点。
    /// - `DELETE /v2/push-endpoint`：注销当前设备推送端点。
    public func register(on routes: RoutesBuilder) {
        routes.put("v2", "push-endpoint") { request async throws -> Response in
            let identity = try await authenticate(request)
            let input = try await request.content.decode(V2PushEndpointHTTPRequest.self)
            let endpoint: V2PushDeviceEndpointRegistration
            do {
                endpoint = try .init(provider: input.provider, environment: input.environment, token: input.token)
                try await store.register(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    endpoint: endpoint,
                    now: now()
                )
            } catch { return v2PushIntentErrorResponse(error) }
            return noStoreNoContent()
        }

        routes.delete("v2", "push-endpoint") { request async throws -> Response in
            let identity = try await authenticate(request)
            do {
                try await store.disableOwnedEndpoint(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    now: now()
                )
            } catch { return v2PushIntentErrorResponse(error) }
            return noStoreNoContent()
        }
    }

    /// 从请求中获取已鉴权连接。
    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    /// 构造 no-store 的空体响应。
    private func noStoreNoContent() -> Response {
        var headers = HTTPFields()
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return .init(status: .noContent, headers: headers)
    }
}
