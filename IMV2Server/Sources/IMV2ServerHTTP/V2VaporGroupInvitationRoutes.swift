import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes

/// 群邀请与入群申请的 HTTP 路由入口。
///
/// 提供创建/查询/撤销邀请、预览邀请链接、提交入群申请以及审批决策等接口。
/// 所有操作都要求已鉴权身份，返回值默认走 `no-store`，避免会话级邀请信息被缓存。
public struct V2VaporGroupInvitationRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let invitations: any V2GroupInvitationHandling

    /// 初始化路由。
    ///
    /// - Parameters:
    ///   - authenticator: 鉴权组件，解析并校验 `Request` 身份上下文。
    ///   - invitations: 邀请服务（命令执行与状态机）。
    public init(authenticator: any V2GatewayAuthenticator, invitations: any V2GroupInvitationHandling) {
        self.authenticator = authenticator
        self.invitations = invitations
    }

    /// 挂载以下端点：
    ///
    /// - `POST /v2/group-invites`：创建群邀请链接。
    /// - `GET /v2/group-invites`：分页读取当前用户在某个 room 的有效邀请。
    /// - `POST /v2/group-invites/:inviteID/revoke`：撤销邀请。
    /// - `POST /v2/group-invites/preview`：根据 token 预览邀请。
    /// - `POST /v2/group-join-requests`：提交入群申请。
    /// - `GET /v2/group-join-requests`：分页读取待审批的入群申请。
    /// - `POST /v2/group-join-requests/:requestID/decision`：对申请进行审批。
    ///
    /// 错误策略由 `mapErrors` 与顶层错误转换统一处理，常见映射到 400/403/404/409/422/429/503。
    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "group-invites") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try await request.content.decode(CreateBody.self)
            guard let room = try? RoomID(body.roomID), let operation = try? GroupInviteOperationID(body.operationID) else { throw Abort(.badRequest) }
            let link = try await mapErrors {
                try await invitations.create(.init(roomID: room, actorUserID: actor.userID, operationID: operation, lifetime: TimeInterval(body.lifetimeSeconds), maximumApprovedUses: body.maximumApprovedUses))
            }
            return try response(LinkResponse(link))
        }

        routes.get("v2", "group-invites") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawRoom = request.query[String.self, at: "room_id"], let room = try? RoomID(rawRoom) else { throw Abort(.badRequest) }
            return try response(LinksResponse(items: try await mapErrors { try await invitations.activeInvites(roomID: room, actorUserID: actor.userID) }.map(LinkResponse.init)))
        }

        routes.post("v2", "group-invites", ":inviteID", "revoke") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try await request.content.decode(RevokeBody.self)
            guard let rawInvite = request.parameters.get("inviteID"), let invite = try? GroupInviteID(rawInvite), let room = try? RoomID(body.roomID), let operation = try? GroupInviteOperationID(body.operationID) else { throw Abort(.badRequest) }
            try await mapErrors { try await invitations.revoke(inviteID: invite, roomID: room, actorUserID: actor.userID, operationID: operation) }
            return noContentResponse()
        }

        routes.post("v2", "group-invites", "preview") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try await request.content.decode(TokenBody.self)
            guard let secret = try? V2GroupInviteSecret(body.token) else { throw Abort(.badRequest) }
            guard let preview = try await mapErrors({ try await invitations.preview(secret: secret, applicantUserID: actor.userID) }) else { throw Abort(.notFound) }
            return try response(PreviewResponse(preview))
        }

        routes.post("v2", "group-join-requests") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try await request.content.decode(SubmitBody.self)
            guard let secret = try? V2GroupInviteSecret(body.token), let operation = try? GroupJoinRequestOperationID(body.operationID) else { throw Abort(.badRequest) }
            switch try await mapErrors({ try await invitations.submit(.init(applicantUserID: actor.userID, operationID: operation, secret: secret, note: body.note)) }) {
            case .submitted(let value): return try response(SubmissionResponse(kind: "submitted", request: RequestResponse(value), preview: nil))
            case .alreadyPending(let value): return try response(SubmissionResponse(kind: "already_pending", request: RequestResponse(value), preview: nil))
            case .cancelled(let value): return try response(SubmissionResponse(kind: "cancelled", request: RequestResponse(value), preview: nil))
            case .rejected(let value): return try response(SubmissionResponse(kind: "rejected", request: RequestResponse(value), preview: nil))
            case .alreadyMember(let value): return try response(SubmissionResponse(kind: "already_member", request: nil, preview: PreviewResponse(value)))
            case .unavailable: throw Abort(.notFound)
            case .rateLimited: throw Abort(.tooManyRequests)
            }
        }

        routes.get("v2", "group-join-requests") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawRoom = request.query[String.self, at: "room_id"],
                  let room = try? RoomID(rawRoom)
            else { throw Abort(.badRequest) }
            let cursor = request.query[String.self, at: "cursor"]
            let pageSize = request.query[Int.self, at: "page_size"] ?? 50
            let page = try await mapErrors {
                try await invitations.pendingRequests(
                    roomID: room,
                    reviewerUserID: actor.userID,
                    cursor: cursor,
                    pageSize: pageSize
                )
            }
            let items = try page.requests.map { try RequestResponse($0) }
            return try response(RequestPageResponse(items: items, nextCursor: page.nextCursor))
        }

        routes.post("v2", "group-join-requests", ":requestID", "cancel") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try await request.content.decode(CancelBody.self)
            guard let rawID = request.parameters.get("requestID"), let requestID = try? GroupJoinRequestID(rawID),
                  let room = try? RoomID(body.roomID) else { throw Abort(.badRequest) }
            let value = try await mapErrors {
                try await invitations.cancel(roomID: room, requestID: requestID, applicantUserID: actor.userID)
            }
            return try response(RequestResponse(value))
        }

        routes.post("v2", "group-join-requests", ":requestID", "decision") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try await request.content.decode(DecisionBody.self)
            guard let rawID = request.parameters.get("requestID"), let requestID = try? GroupJoinRequestID(rawID), let room = try? RoomID(body.roomID), let operation = try? GroupJoinDecisionOperationID(body.operationID), let decision = V2GroupJoinDecision(rawValue: body.decision) else { throw Abort(.badRequest) }
            switch try await mapErrors({ try await invitations.decide(.init(roomID: room, requestID: requestID, reviewerUserID: actor.userID, operationID: operation, decision: decision)) }) {
            case .approved(let value): return try response(DecisionResponse(kind: "approved", request: RequestResponse(value)))
            case .rejected(let value): return try response(DecisionResponse(kind: "rejected", request: RequestResponse(value)))
            case .alreadyDecided(let value): return try response(DecisionResponse(kind: "already_decided", request: RequestResponse(value)))
            case .conflict: throw Abort(.conflict)
            case .memberLimitReached: throw Abort(.unprocessableContent, reason: "member_limit_reached")
            case .rateLimited(let seconds): return retryAfter(seconds)
            case .unavailable: throw unavailableResponseError()
            }
        }
    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }
}

/// 创建邀请时的入参。
/// - `lifetimeSeconds`：邀请有效期秒数。
/// - `maximumApprovedUses`：最大审批通过次数。
private struct CreateBody: Content { let roomID: String; let operationID: String; let lifetimeSeconds: Int; let maximumApprovedUses: Int; enum CodingKeys: String, CodingKey { case roomID = "room_id", operationID = "operation_id", lifetimeSeconds = "lifetime_seconds", maximumApprovedUses = "maximum_approved_uses" } }

/// 撤销邀请时的入参。
private struct RevokeBody: Content { let roomID: String; let operationID: String; enum CodingKeys: String, CodingKey { case roomID = "room_id", operationID = "operation_id" } }

/// 预览邀请链接时的入参。
private struct TokenBody: Content { let token: String }

/// 提交入群申请时的入参。
private struct SubmitBody: Content { let token: String; let operationID: String; let note: String?; enum CodingKeys: String, CodingKey { case token, operationID = "operation_id", note } }

/// 申请人取消时仅需房间身份，申请人来自认证。
private struct CancelBody: Content { let roomID: String; enum CodingKeys: String, CodingKey { case roomID = "room_id" } }
/// 审批入群申请时的入参。
private struct DecisionBody: Content { let roomID: String; let operationID: String; let decision: String; enum CodingKeys: String, CodingKey { case roomID = "room_id", operationID = "operation_id", decision } }

/// 邀请列表响应分页容器。
private struct LinksResponse: Content { let items: [LinkResponse] }

/// 单条邀请元数据响应。
private struct LinkResponse: Content {
    let inviteID, roomID, roomTitle, token, state: String
    let expiresAtMilliseconds: Int64
    let maximumApprovedUses, approvedUseCount: Int
    let createdAtMilliseconds: Int64
    init(_ value: V2GroupInviteLink) throws { inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; roomTitle = value.roomTitle; token = value.secret.rawValue; state = value.state.rawValue; expiresAtMilliseconds = try value.expiresAt.millisecondsSince1970; maximumApprovedUses = value.maximumApprovedUses; approvedUseCount = value.approvedUseCount; createdAtMilliseconds = try value.createdAt.millisecondsSince1970 }
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", token, state, expiresAtMilliseconds = "expires_at_ms", maximumApprovedUses = "maximum_approved_uses", approvedUseCount = "approved_use_count", createdAtMilliseconds = "created_at_ms" }
}

/// 入群申请预览响应。
private struct PreviewResponse: Content {
    let inviteID, roomID, roomTitle: String
    let expiresAtMilliseconds: Int64
    let requestState: String?, requestID: String?
    let isAlreadyMember: Bool
    init(_ value: V2GroupInvitePreview) throws { inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; roomTitle = value.roomTitle; expiresAtMilliseconds = try value.expiresAt.millisecondsSince1970; requestState = value.requestState?.rawValue; requestID = value.requestID?.rawValue; isAlreadyMember = value.isAlreadyMember }
    init(_ value: V2GroupInvitePreviewRecord) throws { inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; roomTitle = value.roomTitle; expiresAtMilliseconds = try value.expiresAt.millisecondsSince1970; requestState = value.requestState?.rawValue; requestID = value.requestID?.rawValue; isAlreadyMember = value.isAlreadyMember }
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", expiresAtMilliseconds = "expires_at_ms", requestState = "request_state", requestID = "request_id", isAlreadyMember = "is_already_member" }
}

/// 公开身份信息响应模型（用于申请列表中的申请方视图）。
private struct PublicIdentityResponse: Content { let userID, handle, displayName, accountKind: String; init(_ value: V2PublicIdentity) { userID = value.userID.rawValue; handle = value.handle.rawValue; displayName = value.displayName; accountKind = value.accountKind.rawValue }; enum CodingKeys: String, CodingKey { case userID = "user_id", handle, displayName = "display_name", accountKind = "account_kind" } }

/// 入群申请单条返回模型。
private struct RequestResponse: Content {
    let requestID, inviteID, roomID: String
    let applicant: PublicIdentityResponse
    let note: String?, state: String
    let createdAtMilliseconds: Int64, decidedAtMilliseconds: Int64?
    init(_ value: V2GroupJoinRequest) throws { requestID = value.requestID.rawValue; inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; applicant = .init(value.applicant); note = value.note; state = value.state.rawValue; createdAtMilliseconds = try value.createdAt.millisecondsSince1970; decidedAtMilliseconds = try value.decidedAt?.millisecondsSince1970 }
    init(_ value: V2GroupJoinRequestRecord) throws { requestID = value.requestID.rawValue; inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; applicant = .init(value.applicant); note = value.note; state = value.state.rawValue; createdAtMilliseconds = try value.createdAt.millisecondsSince1970; decidedAtMilliseconds = try value.decidedAt?.millisecondsSince1970 }
    enum CodingKeys: String, CodingKey { case requestID = "request_id", inviteID = "invite_id", roomID = "room_id", applicant, note, state, createdAtMilliseconds = "created_at_ms", decidedAtMilliseconds = "decided_at_ms" }
}

/// 入群申请提交的统一返回模型，包含分支状态。
private struct SubmissionResponse: Content { let kind: String; let request: RequestResponse?; let preview: PreviewResponse? }

/// 分页返回容器：申请列表与下一页游标。
private struct RequestPageResponse: Content { let items: [RequestResponse]; let nextCursor: String?; enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" } }

/// 申请审批返回模型。
private struct DecisionResponse: Content { let kind: String; let request: RequestResponse }

/// 统一 JSON 编码 helper，统一加 no-store 响应头。
private func response<T: Encodable>(_ value: T) throws -> Response {
    let data = try JSONEncoder().encode(value)
    var headers = HTTPFields(); headers[.contentType] = "application/json"; headers[.cacheControl] = "no-store"; headers[.v2Pragma] = "no-cache"
    return .init(status: .ok, headers: headers, body: .init(data: data))
}

/// 无内容响应，使用 no-store 禁止缓存。
private func noContentResponse() -> Response { var headers = HTTPFields(); headers[.cacheControl] = "no-store"; return .init(status: .noContent, headers: headers) }

/// 限流响应。
private func retryAfter(_ seconds: Int) -> Response { var headers = HTTPFields(); headers[.cacheControl] = "no-store"; headers[.retryAfter] = String(max(1, seconds)); return .init(status: .tooManyRequests, headers: headers) }

/// 统一错误映射工具，隐藏底层实现差异，确保异常码边界稳定。
private func mapErrors<T>(_ operation: () async throws -> T) async throws -> T {
    do { return try await operation() }
    catch let error as V2GroupInvitationServiceError {
        switch error {
        case .invalidRequest: throw Abort(.badRequest)
        case .roomNotFound, .inviteNotFound, .requestNotFound: throw Abort(.notFound)
        case .permissionDenied: throw Abort(.forbidden)
        case .rateLimited: throw Abort(.tooManyRequests)
        case .conflict, .ownerChanged, .creationExpired: throw Abort(.conflict)
        case .invalidConfiguration, .corruptPersistenceState: throw unavailableResponseError()
        }
    }
    catch let error as V2GroupInviteDirectoryError {
        switch error {
        case .invalidRequest: throw Abort(.badRequest)
        case .conflict: throw Abort(.conflict)
        case .ownerResultMismatch, .corruptPersistenceState: throw unavailableResponseError()
        }
    }
    catch V2RoomShardRouteError.roomNotFound { throw Abort(.notFound) }
    catch { throw unavailableResponseError() }
}

/// 统一返回服务不可用错误，并带 no-store/no-cache 头。
private func unavailableResponseError() -> Abort {
    Abort(.serviceUnavailable, headers: [.cacheControl: "no-store", .v2Pragma: "no-cache"])
}

/// 时间转换为毫秒时间戳（服务接口统一使用 Int64 毫秒）。
private extension Date {
    var millisecondsSince1970: Int64 {
        get throws {
            guard let milliseconds = Int64(exactly: (timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
                throw unavailableResponseError()
            }
            return milliseconds
        }
    }
}
