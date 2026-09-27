import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes

/// 精确 Handle 查询路由族（仅支持单条 exact 查询，不提供模糊、批量或前缀列表）。
///
/// 所有接口都要求鉴权用户上下文，返回结果采用 no-store，不允许客户端缓存 handle 解析结果。
public struct V2VaporPublicIdentityRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let directory: any V2PublicIdentityAccountManaging
    private let resolutions: V2PublicIdentityResolutionService

    /// 初始化路由。
    ///
    /// - Parameters:
    ///   - authenticator: 鉴权器。
    ///   - directory: handle 与账号映射服务。
    public init(authenticator: any V2GatewayAuthenticator, directory: any V2PublicIdentityAccountManaging,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.authenticator = authenticator
        self.directory = directory
        resolutions = .init(authenticator: authenticator, directory: directory, now: now)
    }

    /// 注册端点：
    /// - `GET /v2/public-identities/resolve?handle=`：按 handle 解析用户身份。
    /// - `GET /v2/public-identities/me`：读取当前调用者公开身份信息。
    /// 查询到的 profile 仅返回对外展示字段，避免返回内部信息。
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "public-identities", "resolve") { request async throws -> Response in
            guard let rawHandle = request.query[String.self, at: "handle"], let handle = try? V2PublicHandle(rawHandle) else { throw Abort(.badRequest) }
            guard let token = request.headers.bearerAuthorization?.token,
                  let rawDevice = request.headers[.v2DeviceID], let device = try? DeviceID(rawDevice)
            else { throw Abort(.unauthorized) }
            do {
                guard let result = try await resolutions.resolve(handle: handle, accessToken: token, deviceID: device) else {
                    return noStoreResponse(status: .notFound)
                }
                return try noStoreJSONResponse(result)
            } catch V2GatewayAuthenticationError.unauthenticated {
                return noStoreResponse(status: .unauthorized)
            } catch let error as V2PublicIdentityDirectoryError {
                switch error {
                case .rateLimited(let retryAfterSeconds): return noStoreRetryAfterResponse(seconds: retryAfterSeconds)
                case .unavailable: return noStoreResponse(status: .serviceUnavailable)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { return noStoreResponse(status: .serviceUnavailable) }
        }

        routes.get("v2", "public-identities", "me") { request async throws -> Response in
            let actor = try await authenticate(request)
            do {
                guard let result = try await directory.profile(for: actor.userID) else { throw Abort(.notFound) }
                return try noStoreJSONResponse(V2PublicIdentityHTTPResponse(userID: result.userID.rawValue, handle: result.handle.rawValue, displayName: result.displayName, accountKind: result.accountKind))
            } catch is Abort { throw Abort(.notFound) }
            catch { throw Abort(.serviceUnavailable) }
        }

    }

    /// 解析认证连接上下文。
    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    /// no-store JSON 响应输出。
    private func noStoreJSONResponse(_ result: some Encodable) throws -> Response {
        let data = try JSONEncoder().encode(result)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }

    private func noStoreResponse(status: HTTPResponse.Status) -> Response {
        var headers = HTTPFields()
        headers[.cacheControl] = "no-store"; headers[.v2Pragma] = "no-cache"
        return .init(status: status, headers: headers)
    }

    /// 超频返回 `Retry-After`，并保持 no-store。
    private func noStoreRetryAfterResponse(seconds: Int) -> Response {
        var headers = HTTPFields()
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        headers[.retryAfter] = String(seconds)
        return .init(status: .tooManyRequests, headers: headers)
    }
}

/// 公共身份查询响应模型。
public struct V2PublicIdentityHTTPResponse: Content, Sendable {
    /// 用户 ID。
    public let userID: String
    /// 公开 handle。
    public let handle: String
    /// 展示名。
    public let displayName: String
    /// 账号类型。
    public let accountKind: V2AccountKind
}
