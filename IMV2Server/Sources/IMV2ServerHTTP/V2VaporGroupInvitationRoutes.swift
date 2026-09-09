import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2VaporGroupInvitationRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let invitations: V2GroupInvitationService

    public init(authenticator: any V2GatewayAuthenticator, invitations: V2GroupInvitationService) {
        self.authenticator = authenticator
        self.invitations = invitations
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "group-invites") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try request.content.decode(CreateBody.self)
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
            let body = try request.content.decode(RevokeBody.self)
            guard let rawInvite = request.parameters.get("inviteID"), let invite = try? GroupInviteID(rawInvite), let room = try? RoomID(body.roomID), let operation = try? GroupInviteOperationID(body.operationID) else { throw Abort(.badRequest) }
            try await mapErrors { try await invitations.revoke(inviteID: invite, roomID: room, actorUserID: actor.userID, operationID: operation) }
            return noContentResponse()
        }

        routes.post("v2", "group-invites", "preview") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try request.content.decode(TokenBody.self)
            guard let secret = try? V2GroupInviteSecret(body.token) else { throw Abort(.badRequest) }
            guard let preview = try await mapErrors({ try await invitations.preview(secret: secret, applicantUserID: actor.userID) }) else { throw Abort(.notFound) }
            return try response(PreviewResponse(preview))
        }

        routes.post("v2", "group-join-requests") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try request.content.decode(SubmitBody.self)
            guard let secret = try? V2GroupInviteSecret(body.token), let operation = try? GroupJoinRequestOperationID(body.operationID) else { throw Abort(.badRequest) }
            switch try await mapErrors({ try await invitations.submit(.init(applicantUserID: actor.userID, operationID: operation, secret: secret, note: body.note)) }) {
            case .submitted(let value): return try response(SubmissionResponse(kind: "submitted", request: RequestResponse(value, resumable: nil), preview: nil))
            case .alreadyPending(let value): return try response(SubmissionResponse(kind: "already_pending", request: RequestResponse(value, resumable: nil), preview: nil))
            case .rejected(let value): return try response(SubmissionResponse(kind: "rejected", request: RequestResponse(value, resumable: nil), preview: nil))
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

        routes.post("v2", "group-join-requests", ":requestID", "decision") { request async throws -> Response in
            let actor = try await authenticate(request)
            let body = try request.content.decode(DecisionBody.self)
            guard let rawID = request.parameters.get("requestID"), let requestID = try? GroupJoinRequestID(rawID), let room = try? RoomID(body.roomID), let operation = try? GroupJoinDecisionOperationID(body.operationID), let decision = V2GroupJoinDecision(rawValue: body.decision) else { throw Abort(.badRequest) }
            switch try await mapErrors({ try await invitations.decide(.init(roomID: room, requestID: requestID, reviewerUserID: actor.userID, operationID: operation, decision: decision)) }) {
            case .approved(let value): return try response(DecisionResponse(kind: "approved", request: RequestResponse(value)))
            case .rejected(let value): return try response(DecisionResponse(kind: "rejected", request: RequestResponse(value)))
            case .alreadyDecided(let value): return try response(DecisionResponse(kind: "already_decided", request: RequestResponse(value)))
            case .conflict: throw Abort(.conflict)
            case .memberLimitReached: throw Abort(.unprocessableEntity, reason: "member_limit_reached")
            case .rateLimited(let seconds): return retryAfter(seconds)
            case .unavailable: throw unavailableResponseError()
            }
        }
    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }
}

private struct CreateBody: Content { let roomID: String; let operationID: String; let lifetimeSeconds: Int; let maximumApprovedUses: Int; enum CodingKeys: String, CodingKey { case roomID = "room_id", operationID = "operation_id", lifetimeSeconds = "lifetime_seconds", maximumApprovedUses = "maximum_approved_uses" } }
private struct RevokeBody: Content { let roomID: String; let operationID: String; enum CodingKeys: String, CodingKey { case roomID = "room_id", operationID = "operation_id" } }
private struct TokenBody: Content { let token: String }
private struct SubmitBody: Content { let token: String; let operationID: String; let note: String?; enum CodingKeys: String, CodingKey { case token, operationID = "operation_id", note } }
private struct DecisionBody: Content { let roomID: String; let operationID: String; let decision: String; enum CodingKeys: String, CodingKey { case roomID = "room_id", operationID = "operation_id", decision } }

private struct LinksResponse: Content { let items: [LinkResponse] }
private struct LinkResponse: Content {
    let inviteID, roomID, roomTitle, token, state: String
    let expiresAtMilliseconds: Int64
    let maximumApprovedUses, approvedUseCount: Int
    let createdAtMilliseconds: Int64
    init(_ value: V2GroupInviteLink) throws { inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; roomTitle = value.roomTitle; token = value.secret.rawValue; state = value.state.rawValue; expiresAtMilliseconds = try value.expiresAt.millisecondsSince1970; maximumApprovedUses = value.maximumApprovedUses; approvedUseCount = value.approvedUseCount; createdAtMilliseconds = try value.createdAt.millisecondsSince1970 }
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", token, state, expiresAtMilliseconds = "expires_at_ms", maximumApprovedUses = "maximum_approved_uses", approvedUseCount = "approved_use_count", createdAtMilliseconds = "created_at_ms" }
}
private struct PreviewResponse: Content {
    let inviteID, roomID, roomTitle: String
    let expiresAtMilliseconds: Int64
    let requestState: String?, requestID: String?
    let isAlreadyMember: Bool
    init(_ value: V2GroupInvitePreview) throws { inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; roomTitle = value.roomTitle; expiresAtMilliseconds = try value.expiresAt.millisecondsSince1970; requestState = value.requestState?.rawValue; requestID = value.requestID?.rawValue; isAlreadyMember = value.isAlreadyMember }
    init(_ value: V2GroupInvitePreviewRecord) throws { inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; roomTitle = value.roomTitle; expiresAtMilliseconds = try value.expiresAt.millisecondsSince1970; requestState = value.requestState?.rawValue; requestID = value.requestID?.rawValue; isAlreadyMember = value.isAlreadyMember }
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", expiresAtMilliseconds = "expires_at_ms", requestState = "request_state", requestID = "request_id", isAlreadyMember = "is_already_member" }
}
private struct PublicIdentityResponse: Content { let userID, handle, displayName, accountKind: String; init(_ value: V2PublicIdentity) { userID = value.userID.rawValue; handle = value.handle.rawValue; displayName = value.displayName; accountKind = value.accountKind.rawValue }; enum CodingKeys: String, CodingKey { case userID = "user_id", handle, displayName = "display_name", accountKind = "account_kind" } }
private struct RequestResponse: Content {
    let requestID, inviteID, roomID: String
    let applicant: PublicIdentityResponse
    let note: String?, state: String, resumableDecisionOperationID: String?
    let createdAtMilliseconds: Int64, decidedAtMilliseconds: Int64?
    init(_ value: V2GroupJoinRequest, resumable: String? = nil) throws { requestID = value.requestID.rawValue; inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; applicant = .init(value.applicant); note = value.note; state = value.state.rawValue; resumableDecisionOperationID = value.resumableDecisionOperationID?.rawValue ?? resumable; createdAtMilliseconds = try value.createdAt.millisecondsSince1970; decidedAtMilliseconds = try value.decidedAt?.millisecondsSince1970 }
    init(_ value: V2GroupJoinRequestRecord, resumable: String? = nil) throws { requestID = value.requestID.rawValue; inviteID = value.inviteID.rawValue; roomID = value.roomID.rawValue; applicant = .init(value.applicant); note = value.note; state = value.state.rawValue; resumableDecisionOperationID = resumable; createdAtMilliseconds = try value.createdAt.millisecondsSince1970; decidedAtMilliseconds = try value.decidedAt?.millisecondsSince1970 }
    enum CodingKeys: String, CodingKey { case requestID = "request_id", inviteID = "invite_id", roomID = "room_id", applicant, note, state, resumableDecisionOperationID = "resumable_decision_operation_id", createdAtMilliseconds = "created_at_ms", decidedAtMilliseconds = "decided_at_ms" }
}
private struct SubmissionResponse: Content { let kind: String; let request: RequestResponse?; let preview: PreviewResponse? }
private struct RequestPageResponse: Content { let items: [RequestResponse]; let nextCursor: String?; enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" } }
private struct DecisionResponse: Content { let kind: String; let request: RequestResponse }

private func response<T: Encodable>(_ value: T) throws -> Response {
    let data = try JSONEncoder().encode(value)
    var headers = HTTPHeaders(); headers.replaceOrAdd(name: .contentType, value: "application/json"); headers.replaceOrAdd(name: .cacheControl, value: "no-store"); headers.replaceOrAdd(name: "Pragma", value: "no-cache")
    return .init(status: .ok, headers: headers, body: .init(data: data))
}
private func noContentResponse() -> Response { var headers = HTTPHeaders(); headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return .init(status: .noContent, headers: headers) }
private func retryAfter(_ seconds: Int) -> Response { var headers = HTTPHeaders(); headers.replaceOrAdd(name: .cacheControl, value: "no-store"); headers.replaceOrAdd(name: "Retry-After", value: String(max(1, seconds))); return .init(status: .tooManyRequests, headers: headers) }
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

private func unavailableResponseError() -> Abort {
    Abort(.serviceUnavailable, headers: ["Cache-Control": "no-store", "Pragma": "no-cache"])
}

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
