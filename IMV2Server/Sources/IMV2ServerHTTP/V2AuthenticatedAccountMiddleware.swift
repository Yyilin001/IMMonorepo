import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Core
import Vapor
import HTTPTypes

/// 请求缓存的已鉴权连接上下文。
private struct V2AuthenticatedAccountIdentity: Authenticatable {
    let connection: V2AuthenticatedConnection
}

public extension Request {
    /// 读取当前请求的已鉴权身份。
    ///
    /// - Parameter authenticator: 账户鉴权器。
    /// - Returns: 已鉴权连接（用户 ID + 设备 ID）。
    func v2AuthenticatedAccountIdentity(
        using authenticator: any V2GatewayAuthenticator
    ) async throws -> V2AuthenticatedConnection {
        if let identity = auth.get(V2AuthenticatedAccountIdentity.self) {
            return identity.connection
        }
        guard let accessToken = headers.bearerAuthorization?.token,
              let rawDeviceID = headers[.v2DeviceID],
              let deviceID = try? DeviceID(rawDeviceID)
        else { throw Abort(.unauthorized) }
        do {
            let authentication = try await authenticator.authenticateSession(
                accessToken: accessToken,
                deviceID: deviceID
            )
            let identity = V2AuthenticatedConnection(
                userID: authentication.userID,
                deviceID: deviceID,
                capabilityProfile: "account-edge"
            )
            auth.login(V2AuthenticatedAccountIdentity(connection: identity))
            return identity
        } catch V2GatewayAuthenticationError.unauthenticated {
            throw Abort(.unauthorized)
        } catch {
            // 依赖故障和持久化数据损坏不能证明调用方凭据无效。
            throw Abort(.serviceUnavailable)
        }
    }
}

/// 会话鉴权中间件。
///
/// 解析并缓存 `V2AuthenticatedConnection`，避免后续路由重复鉴权。
public struct V2AuthenticatedAccountMiddleware: Middleware, Sendable {
    private let authenticator: any V2GatewayAuthenticator

    /// 初始化。
    public init(authenticator: any V2GatewayAuthenticator) {
        self.authenticator = authenticator
    }

    public func respond(
        to request: Request,
        chainingTo next: any Responder
    ) async throws -> Response {
        let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
        request.auth.login(V2AuthenticatedAccountIdentity(connection: identity))
        return try await next.respond(to: request)
    }
}

/// 鉴权后的路由级速率限制中间件。
///
/// 用于已认证账号路由的跨副本设备预算。代价按端点计算，
/// 因此批量与变更类接口无法被当作一次廉价请求来放大。
/// 与鉴权器解耦，按路径和方法计算代价，避免单次请求消耗无限资源。
/// 领域层的基数上限仍然是权威约束。
public struct V2AuthenticatedAccountRateLimitMiddleware: Middleware, Sendable {
    private let limiter: any V2AuthenticatedAccountRateLimiting

    /// 初始化。
    public init(limiter: any V2AuthenticatedAccountRateLimiting) {
        self.limiter = limiter
    }

    public func respond(
        to request: Request,
        chainingTo next: any Responder
    ) async throws -> Response {
        guard let identity = request.auth.get(V2AuthenticatedAccountIdentity.self)?.connection else {
            throw Abort(.serviceUnavailable)
        }
        // 精确账号标识解析在领域存储中有更严格的逐用户反枚举预算。
        // 若再扣通用的逐设备预算，一次查询就须串行更新两个 PostgreSQL 计数器。
        guard let budget = Self.budget(for: request) else {
            return try await next.respond(to: request)
        }
        let result: V2AccountEdgeClientRateLimitResult
        do {
            result = try await limiter.consume(
                identity: identity,
                scope: budget.scope,
                cost: budget.cost
            )
        } catch {
            throw Abort(.serviceUnavailable)
        }
        switch result {
        case .allowed:
            return try await next.respond(to: request)
        case .rateLimited(let retryAfterSeconds):
            var headers = HTTPFields()
            headers[.cacheControl] = "no-store"
            headers[.v2Pragma] = "no-cache"
            headers[.retryAfter] = String(max(1, retryAfterSeconds))
            return .init(status: .tooManyRequests, headers: headers)
        }
    }

    /// 按路径和方法返回速率预算（scope 与 cost）。
    private static func budget(for request: Request) -> (scope: String, cost: Int)? {
        let path = request.url.path
        if path.hasPrefix("/v2/media/") || path == "/v2/media/uploads" { return ("media", 5) }
        if path.hasPrefix("/v2/profile-presentations/") {
            guard request.method == .get else { return ("profile-presentations", 4) }
            let limit = min(500, max(1, request.query[Int.self, at: "limit"] ?? 200))
            return ("profile-presentations", 1 + ((limit + 99) / 100))
        }
        // Recovery has its own persistent budget; random-ID close cannot evade mutation admission.
        if path.hasPrefix("/v2/profile-presentations/contact-aliases/"),path.hasSuffix("/operations/recover") { return ("contact-alias-recovery",3) }
        if path.hasPrefix("/v2/profile-presentations/groups/"),path.hasSuffix("/nickname/operations/recover") { return ("group-nickname-recovery",3) }
        if path.hasPrefix("/v2/rooms/"),path.contains("/message-operations/") { return ("message-operations",3) }
        if path.hasPrefix("/v2/rooms/"),path.contains("/message-mutations/") { return ("message-mutations",3) }
        if path.hasPrefix("/v2/rooms/"),path.contains("/message-reactions/") { return ("message-reactions",3) }
        if path.hasPrefix("/v2/account-preferences/") { return ("account-preference-operations",3) }
        if path.hasPrefix("/v2/direct-room-operations/") { return ("direct-room-operations",3) }
        if path.hasPrefix("/v2/social/") { return ("social-operations",3) }
        if path.hasPrefix("/v2/rooms/"),path.contains("/group-capability-operations/") { return ("group-capabilities",3) }
        if path.hasPrefix("/v2/rooms/"),path.contains("/membership/") { return ("membership",3) }
        if path.hasPrefix("/v2/rooms/"),path.contains("/invitation-operations/") { return ("group-invitation-operations",3) }
        if path.hasPrefix("/v2/rooms/"),path.contains("/message-moderation-operations/") { return ("message-moderation-operations",3) }
        if path.hasPrefix("/v2/rooms/"),path.contains("/member-administration/") { return ("member-administration",3) }
        if path.hasPrefix("/v2/forward-plans/") { return ("forward-plans",3) }
        if path.hasPrefix("/v2/rooms/"),path.hasSuffix("/read-receipts/operations/recover") { return ("read-receipt-recovery",1) }
        if path.hasPrefix("/v2/rooms/"),path.hasSuffix("/personal-preferences/operations/recover") { return ("personal-preference-recovery",3) }
        if path == "/v2/profile/me/operations/recover" { return ("profile-recovery", 3) }
        if path == "/v2/profile/me" { return ("profile", request.method == .get ? 1 : 3) }
        if path.hasPrefix("/v2/devices") {
            guard request.method == .get else { return ("devices", 3) }
            let pageSize = min(100, max(1, request.query[Int.self, at: "page_size"] ?? 50))
            return ("devices", (pageSize + 49) / 50)
        }
        if path == "/v2/push-endpoint" || path.hasPrefix("/v2/push-endpoint/") {
            return ("push", request.method == .get ? 1 : 3)
        }
        if path == "/v2/public-identities/resolve" { return nil }
        if path.hasPrefix("/v2/public-identities/") { return ("public-identities", 1) }
        return ("account", 1)
    }
}
