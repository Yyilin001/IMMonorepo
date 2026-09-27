import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes

/// 关系展示名与群昵称相关路由。
///
/// 本模块提供 `v2/profile-presentations` 相关接口，所有入口都要求鉴权用户身份。
/// 响应统一加入 no-cache/no-store 头，避免展示名数据被缓存泄露。
public struct V2VaporProfilePresentationRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let presentations: any V2ProfilePresentationManaging
    private let authorizedProfiles: V2ResourceProfilePresentationService?

    /// 初始化路由。
    ///
    /// - Parameters:
    ///   - authenticator: 请求上下文鉴权器。
    ///   - presentations: 展示名服务依赖。
    public init(authenticator: any V2GatewayAuthenticator, presentations: any V2ProfilePresentationManaging,
                authorizedProfiles: V2ResourceProfilePresentationService? = nil) {
        self.authenticator = authenticator
        self.presentations = presentations
        self.authorizedProfiles = authorizedProfiles
    }

    /// 注册展示名路由。
    ///
    /// - GET `/v2/profile-presentations/contact-aliases`：分页读取联系人别名。
    /// - PUT `/v2/profile-presentations/contact-aliases/:target`：更新联系人备注。
    /// - GET `/v2/profile-presentations/groups/:room/nicknames`：分页读取带授权期限的资料，每页最多 100 项。
    /// - PUT `/v2/profile-presentations/groups/:room/nickname`：更新自己在群里的昵称。
    ///
    /// 所有异常统一转为 HTTP 错误码，其中鉴权和参数错误优先返回 4xx。
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "profile-presentations", "contact-aliases") { request async throws -> Response in
            let actor = try await authenticate(request)
            let cursor = try paginationCursor(request)
            let limit = try paginationLimit(request)
            do {
                let page = try await presentations.contactAliases(ownerUserID: actor.userID, afterTargetUserID: cursor, limit: limit)
                return try response(AliasListResponse(values: page.values, nextCursor: page.nextCursor?.rawValue))
            }
            catch { throw map(error) }
        }
        routes.put("v2", "profile-presentations", "contact-aliases", ":target") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawTarget = request.parameters.get("target"), let target = try? UserID(rawTarget) else { throw Abort(.badRequest) }
            let input = try await request.content.decode(AliasUpdateRequest.self)
            do {
                let value = try await presentations.updateContactAlias(ownerUserID: actor.userID, targetUserID: target, operationID: try .init(input.operationID), expectedRevision: validatedRevision(input.expectedRevision), remarkName: input.remarkName)
                return try response(AliasResponse(value: value))
            } catch { throw map(error) }
        }
        routes.get("v2", "profile-presentations", "groups", ":room", "nicknames") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawRoom = request.parameters.get("room"), let room = try? RoomID(rawRoom) else { throw Abort(.badRequest) }
            let cursor = try paginationCursor(request)
            let rawLimit = request.query[String.self, at: "limit"]
            guard let limit = rawLimit.map(Int.init) ?? V2ProfileViewLookupLimits.maximumKeys,
                  (1...V2ProfileViewLookupLimits.maximumKeys).contains(limit) else { throw Abort(.badRequest) }
            guard let authorizedProfiles else { throw Abort(.serviceUnavailable) }
            do {
                let page = try await authorizedProfiles.readGroupNicknames(roomID: room, afterUserID: cursor,
                    limit: limit, actorUserID: actor.userID, deviceID: actor.deviceID) {
                    try await presentations.groupNicknames(actorUserID: actor.userID, roomID: room, afterUserID: cursor, limit: limit)
                }
                return try response(page)
            }
            catch V2ResourceProviderError.throttled {
                var headers = HTTPFields(); headers[.retryAfter] = "1"; headers[.cacheControl] = "no-store"
                throw Abort(.tooManyRequests, headers: headers)
            }
            catch V2ProfileViewReadError.invalidRequest { throw Abort(.badRequest) }
            catch V2MediaStoreError.downloadNotAuthorized { throw Abort(.forbidden) }
            catch { throw map(error) }
        }
        routes.put("v2", "profile-presentations", "groups", ":room", "nickname") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawRoom = request.parameters.get("room"), let room = try? RoomID(rawRoom) else { throw Abort(.badRequest) }
            let input = try await request.content.decode(NicknameUpdateRequest.self)
            do {
                let value = try await presentations.updateOwnGroupNickname(actorUserID: actor.userID, roomID: room, operationID: try .init(input.operationID), expectedRevision: validatedRevision(input.expectedRevision), nickname: input.nickname)
                return try response(NicknameResponse(value: value))
            } catch { throw map(error) }
        }
    }

    /// 解析可选的乐观锁版本。
    ///
    /// - Parameter raw: 请求中的版本整数。
    /// - Returns: 解析后的版本。
    /// - Throws: 当版本非法时报 `invalidPresentation`。
    private func validatedRevision(_ raw: UInt64?) throws -> V2ProfileRevision? {
        guard let raw else { return nil }
        guard let revision = V2ProfileRevision(rawValue: raw) else { throw V2ProfilePresentationError.invalidPresentation }
        return revision
    }

    /// 获取 `cursor` 分页参数。
    ///
    /// - Returns: 游标用户 ID；未传入时返回 nil。
    private func paginationCursor(_ request: Request) throws -> UserID? {
        guard let raw = request.query[String.self, at: "cursor"] else { return nil }
        guard raw.utf8.count <= 64, let cursor = try? UserID(raw) else { throw Abort(.badRequest) }
        return cursor
    }

    /// 获取 `limit` 分页参数。
    ///
    /// - Returns: 限制在 `1...500` 的取值。
    /// - Throws: 超出边界时抛 `badRequest`。
    private func paginationLimit(_ request: Request) throws -> Int {
        let limit = request.query[Int.self, at: "limit"] ?? 200
        guard (1...500).contains(limit) else { throw Abort(.badRequest) }
        return limit
    }

    /// 获取鉴权上下文。
    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    /// 映射业务错误为 HTTP 错误码。
    private func map(_ error: Error) -> Abort {
        guard let error = error as? V2ProfilePresentationError else { return Abort(.serviceUnavailable) }
        switch error {
        case .forbidden: return Abort(.forbidden)
        case .unavailable: return Abort(.notFound)
        case .revisionConflict: return Abort(.conflict)
        case .operationPayloadMismatch, .invalidPresentation: return Abort(.badRequest)
        case .corruptPersistenceState: return Abort(.serviceUnavailable)
        }
    }

    /// 统一编码 JSON 响应体。
    private func response<T: Encodable>(_ value: T) throws -> Response {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}

/// 联系人别名更新请求。
private struct AliasUpdateRequest: Content {
    let operationID: String
    let expectedRevision: UInt64?
    let remarkName: String?

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case expectedRevision = "expected_revision"
        case remarkName = "remark_name"
    }
}

/// 群昵称更新请求。
private struct NicknameUpdateRequest: Content {
    let operationID: String
    let expectedRevision: UInt64?
    let nickname: String?

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case expectedRevision = "expected_revision"
        case nickname
    }
}

/// 联系人别名列表响应。
private struct AliasListResponse: Content {
    let values: [V2ContactAlias]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case values = "aliases"
        case nextCursor = "next_cursor"
    }
}

/// 单条联系人别名响应。
private struct AliasResponse: Content {
    let value: V2ContactAlias

    enum CodingKeys: String, CodingKey {
        case value = "alias"
    }
}

/// 单条群昵称响应。
private struct NicknameResponse: Content {
    let value: V2GroupMemberPresentation

    enum CodingKeys: String, CodingKey {
        case value = "nickname"
    }
}
