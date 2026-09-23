import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes

/// 个人资料更新要求携带版本号与幂等 ID，并把头像替换与其他字段更新放在同一原子事务中处理。
public struct V2VaporProfileUpdateRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let profiles: V2ProfileUpdateService

    /// 初始化资料更新路由。
    ///
    /// - Parameters:
    ///   - authenticator: 实现身份鉴权与当前连接上下文解析的网关鉴权器。
    ///   - profiles: 负责执行用户资料变更与幂等校验的服务。
    public init(authenticator: any V2GatewayAuthenticator, profiles: V2ProfileUpdateService) {
        self.authenticator = authenticator
        self.profiles = profiles
    }

    /// 注册 `/v2/profile/me` 相关端点：
    ///
    /// - GET: 返回当前账号当前资料视图。
    /// - PUT: 提交昵称/头像更新命令，带 `expected_revision` 与 `operation_id` 进行幂等保护与并发保护。
    ///
    /// 错误映射：
    /// - `.badRequest`：参数结构/校验失败。
    /// - `.conflict`：资料版本冲突，返回当前版本。
    /// - `.serviceUnavailable`：持久化状态异常。
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "profile", "me") { request async throws -> Response in
            let actor = try await authenticate(request)
            do {
                let view = try await profiles.currentProfile(for: actor.userID)
                return try noStoreJSONResponse(.init(view: view, idempotent: true))
            } catch is V2ProfileUpdateError {
                throw Abort(.serviceUnavailable)
            } catch {
                throw Abort(.serviceUnavailable)
            }
        }
        routes.put("v2", "profile", "me") { request async throws -> Response in
            let actor = try await authenticate(request)
            let input = try await request.content.decode(V2ProfileUpdateHTTPRequest.self)
            let command: V2ProfileUpdateCommand
            do {
                guard let expectedRevision = V2ProfileRevision(rawValue: input.expectedRevision) else {
                    throw Abort(.badRequest)
                }
                command = try .init(
                    actorUserID: actor.userID,
                    operationID: .init(input.operationID),
                    expectedRevision: expectedRevision,
                    displayName: input.displayName,
                    avatar: try input.avatarMediaID.map { try .init(mediaID: .init($0)) }
                )
            } catch is Abort {
                throw Abort(.badRequest)
            } catch {
                throw Abort(.badRequest)
            }

            do {
                let outcome = try await profiles.update(command)
                let view: V2ProfileView
                let idempotent: Bool
                switch outcome {
                case .updated(let updated): view = updated; idempotent = false
                case .idempotent(let existing): view = existing; idempotent = true
                }
                return try noStoreJSONResponse(.init(view: view, idempotent: idempotent))
            } catch let error as V2ProfileUpdateError {
                switch error {
                case .revisionConflict(let current):
                    return try noStoreJSONResponse(
                        .init(currentRevision: current.rawValue), status: .conflict
                    )
                case .operationPayloadMismatch, .avatarUnavailable:
                    throw Abort(.badRequest)
                case .unavailable:
                    throw Abort(.notFound)
                case .corruptPersistenceState:
                    throw Abort(.serviceUnavailable)
                }
            }
        }
    }

    /// 解析并返回已鉴权的账号上下文。
    ///
    /// 该方法封装认证调用，统一后续路由的鉴权入口。
    /// - Parameter request: 请求对象。
    /// - Returns: 已认证连接的上下文。
    /// - Throws: 认证失败时抛出 `Abort`。
    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    /// 以 `no-store` 响应头编码 JSON，避免网关和浏览器缓存。
    ///
    /// - Parameters:
    ///   - result: 要序列化的响应体。
    ///   - status: HTTP 状态码，默认 `.ok`。
    /// - Returns: 已设置 `content-type`、`cache-control`、`pragma` 的响应对象。
    private func noStoreJSONResponse(_ result: V2ProfileUpdateHTTPResponse, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONEncoder().encode(result)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return .init(status: status, headers: headers, body: .init(data: data))
    }
}

/// 更新资料接口的请求对象。
///
/// 其中 `operation_id` 用于幂等，`expected_revision` 用于检测并发更新冲突。
public struct V2ProfileUpdateHTTPRequest: Content, Sendable {
    /// 本次操作的幂等 ID（幂等键）。
    public let operationID: String
    /// 客户端已知的资料版本，服务端以此做乐观并发控制。
    public let expectedRevision: UInt64
    /// 新显示名。传入空字符串将按业务规则交由服务层判定合法性。
    public let displayName: String
    /// Avatar 媒体 ID。`null` 表示清空头像；本字段与 `display_name` 一起形成完整目标状态。
    public let avatarMediaID: String?

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case expectedRevision = "expected_revision"
        case displayName = "display_name"
        case avatarMediaID = "avatar_media_id"
    }
}

/// 返回客户端的资料更新结果。
///
/// 当更新成功/幂等命中时返回完整资料镜像；冲突场景返回当前版本。
public struct V2ProfileUpdateHTTPResponse: Content, Sendable {
    /// 用户 ID。
    public let userID: String?
    /// 用户公开句柄。
    public let handle: String?
    /// 显示名。
    public let displayName: String?
    /// 账号类型（普通/管理员等）。
    public let accountKind: V2AccountKind?
    /// 当前绑定头像媒体 ID。
    public let avatarMediaID: String?
    /// 账号状态字段。
    public let state: String?
    /// 资料主版本号。
    public let revision: UInt64?
    /// 可见性版本号。
    public let visibilityRevision: UInt64?
    /// 本次请求是否幂等命中。
    public let idempotent: Bool?
    /// 发生 `revisionConflict` 时返回的当前版本。
    public let currentRevision: UInt64?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case handle
        case displayName = "display_name"
        case accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
        case idempotent
        case currentRevision = "current_revision"
    }

    init(view: V2ProfileView, idempotent: Bool) {
        userID = view.userID.rawValue
        handle = view.publicIdentity?.handle.rawValue
        displayName = view.publicIdentity?.displayName
        accountKind = view.publicIdentity?.accountKind
        avatarMediaID = view.avatar?.mediaID.rawValue
        state = view.state.rawValue
        revision = view.revision.rawValue
        visibilityRevision = view.visibilityRevision.rawValue
        self.idempotent = idempotent
        currentRevision = nil
    }

    init(currentRevision: UInt64) {
        userID = nil
        handle = nil
        displayName = nil
        accountKind = nil
        avatarMediaID = nil
        state = nil
        revision = nil
        visibilityRevision = nil
        idempotent = nil
        self.currentRevision = currentRevision
    }
}
