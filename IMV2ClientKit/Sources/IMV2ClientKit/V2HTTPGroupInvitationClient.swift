import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public enum V2ClientGroupInvitationError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidRequest, authorizationUnavailable, authorizationDenied
    case unavailable, conflict, memberLimitReached, rateLimited(retryAfterSeconds: Int?)
    case invalidResponse, networkFailure, serverStatus(Int)
}

public enum V2ClientGroupJoinSubmissionOutcome: Equatable, Sendable {
    case submitted(V2GroupJoinRequest)
    case alreadyPending(V2GroupJoinRequest)
    case alreadyMember(V2GroupInvitePreview)
    case rejected(V2GroupJoinRequest)
}

public enum V2ClientGroupJoinDecisionOutcome: Equatable, Sendable {
    case approved(V2GroupJoinRequest), rejected(V2GroupJoinRequest), alreadyDecided(V2GroupJoinRequest)
}

public protocol V2ClientGroupInvitationManaging: Sendable {
    func create(roomID: RoomID, operationID: GroupInviteOperationID, lifetimeSeconds: Int, maximumApprovedUses: Int) async throws -> V2GroupInviteLink
    func activeInvites(roomID: RoomID) async throws -> [V2GroupInviteLink]
    func revoke(inviteID: GroupInviteID, roomID: RoomID, operationID: GroupInviteOperationID) async throws
    func preview(secret: V2GroupInviteSecret) async throws -> V2GroupInvitePreview
    func submit(secret: V2GroupInviteSecret, operationID: GroupJoinRequestOperationID, note: String?) async throws -> V2ClientGroupJoinSubmissionOutcome
    func pendingRequests(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2GroupJoinRequestPage
    func decide(roomID: RoomID, requestID: GroupJoinRequestID, operationID: GroupJoinDecisionOperationID, decision: V2GroupJoinDecision) async throws -> V2ClientGroupJoinDecisionOutcome
}

public protocol V2ClientGroupInvitationHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public actor V2URLSessionGroupInvitationHTTPTransport: V2ClientGroupInvitationHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = V2SecureURLSession.account) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw V2ClientGroupInvitationError.invalidResponse
        }
        return (data, response)
    }
}

public struct V2HTTPGroupInvitationClient: V2ClientGroupInvitationManaging, Sendable {
    private let baseURL: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientGroupInvitationHTTPTransport

    public init(
        baseURL: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientGroupInvitationHTTPTransport = V2URLSessionGroupInvitationHTTPTransport()
    ) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else { throw V2ClientGroupInvitationError.invalidEndpoint }
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
    }

    public func create(roomID: RoomID, operationID: GroupInviteOperationID, lifetimeSeconds: Int, maximumApprovedUses: Int) async throws -> V2GroupInviteLink {
        let data = try await execute(path: ["v2", "group-invites"], method: "POST", body: CreateBody(roomID: roomID.rawValue, operationID: operationID.rawValue, lifetimeSeconds: lifetimeSeconds, maximumApprovedUses: maximumApprovedUses))
        return try decodeLink(data)
    }

    public func activeInvites(roomID: RoomID) async throws -> [V2GroupInviteLink] {
        let data = try await execute(path: ["v2", "group-invites"], method: "GET", query: [.init(name: "room_id", value: roomID.rawValue)])
        do { return try JSONDecoder().decode(LinksBody.self, from: data).items.map(decodeLink) }
        catch { throw V2ClientGroupInvitationError.invalidResponse }
    }

    public func revoke(inviteID: GroupInviteID, roomID: RoomID, operationID: GroupInviteOperationID) async throws {
        _ = try await execute(path: ["v2", "group-invites", inviteID.rawValue, "revoke"], method: "POST", body: RevokeBody(roomID: roomID.rawValue, operationID: operationID.rawValue), expectedStatuses: [204])
    }

    public func preview(secret: V2GroupInviteSecret) async throws -> V2GroupInvitePreview {
        let data = try await execute(path: ["v2", "group-invites", "preview"], method: "POST", body: TokenBody(token: secret.rawValue))
        do { return try decodePreview(JSONDecoder().decode(PreviewBody.self, from: data)) }
        catch let error as V2ClientGroupInvitationError { throw error }
        catch { throw V2ClientGroupInvitationError.invalidResponse }
    }

    public func submit(secret: V2GroupInviteSecret, operationID: GroupJoinRequestOperationID, note: String?) async throws -> V2ClientGroupJoinSubmissionOutcome {
        let data = try await execute(path: ["v2", "group-join-requests"], method: "POST", body: SubmitBody(token: secret.rawValue, operationID: operationID.rawValue, note: note))
        do {
            let body = try JSONDecoder().decode(SubmissionBody.self, from: data)
            switch body.kind {
            case "submitted": guard let value = body.request else { throw V2ClientGroupInvitationError.invalidResponse }; return .submitted(try decodeRequest(value))
            case "already_pending": guard let value = body.request else { throw V2ClientGroupInvitationError.invalidResponse }; return .alreadyPending(try decodeRequest(value))
            case "already_member": guard let value = body.preview else { throw V2ClientGroupInvitationError.invalidResponse }; return .alreadyMember(try decodePreview(value))
            case "rejected": guard let value = body.request else { throw V2ClientGroupInvitationError.invalidResponse }; return .rejected(try decodeRequest(value))
            default: throw V2ClientGroupInvitationError.invalidResponse
            }
        } catch let error as V2ClientGroupInvitationError { throw error }
        catch { throw V2ClientGroupInvitationError.invalidResponse }
    }

    public func pendingRequests(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2GroupJoinRequestPage {
        guard (1 ... 100).contains(pageSize) else { throw V2ClientGroupInvitationError.invalidRequest }
        var query = [URLQueryItem(name: "room_id", value: roomID.rawValue), .init(name: "page_size", value: String(pageSize))]
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        let data = try await execute(path: ["v2", "group-join-requests"], method: "GET", query: query)
        do { let body = try JSONDecoder().decode(RequestPageBody.self, from: data); return .init(requests: try body.items.map(decodeRequest), nextCursor: body.nextCursor) }
        catch let error as V2ClientGroupInvitationError { throw error }
        catch { throw V2ClientGroupInvitationError.invalidResponse }
    }

    public func decide(roomID: RoomID, requestID: GroupJoinRequestID, operationID: GroupJoinDecisionOperationID, decision: V2GroupJoinDecision) async throws -> V2ClientGroupJoinDecisionOutcome {
        let data = try await execute(path: ["v2", "group-join-requests", requestID.rawValue, "decision"], method: "POST", body: DecisionRequestBody(roomID: roomID.rawValue, operationID: operationID.rawValue, decision: decision.rawValue))
        do {
            let body = try JSONDecoder().decode(DecisionBody.self, from: data), value = try decodeRequest(body.request)
            switch body.kind { case "approved": return .approved(value); case "rejected": return .rejected(value); case "already_decided": return .alreadyDecided(value); default: throw V2ClientGroupInvitationError.invalidResponse }
        } catch let error as V2ClientGroupInvitationError { throw error }
        catch { throw V2ClientGroupInvitationError.invalidResponse }
    }

    private func execute<Body: Encodable>(path: [String], method: String, query: [URLQueryItem] = [], body: Body, expectedStatuses: Set<Int> = [200]) async throws -> Data {
        let encoded: Data
        do { encoded = try JSONEncoder().encode(body) }
        catch { throw V2ClientGroupInvitationError.invalidRequest }
        return try await execute(path: path, method: method, query: query, bodyData: encoded, expectedStatuses: expectedStatuses)
    }

    private func execute(path: [String], method: String, query: [URLQueryItem] = [], expectedStatuses: Set<Int> = [200]) async throws -> Data {
        try await execute(path: path, method: method, query: query, bodyData: nil, expectedStatuses: expectedStatuses)
    }

    private func execute(path: [String], method: String, query: [URLQueryItem], bodyData: Data?, expectedStatuses: Set<Int>) async throws -> Data {
        let credential: V2ClientPushEndpointCredentials
        do { credential = try await credentials.pushEndpointCredentials() }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2ClientGroupInvitationError.authorizationUnavailable }
        guard !credential.accessToken.isEmpty,
              !credential.accessToken.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2ClientGroupInvitationError.authorizationUnavailable }
        let pathURL = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        guard var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) else { throw V2ClientGroupInvitationError.invalidEndpoint }
        components.queryItems = query.isEmpty ? nil : query
        guard let target = components.url else { throw V2ClientGroupInvitationError.invalidRequest }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if let bodyData { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = bodyData }
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2ClientGroupInvitationError.networkFailure }
        let response = result.1
        guard expectedStatuses.contains(response.statusCode) else { throw failure(response) }
        if response.statusCode != 204, !V2HTTPContract.isJSON(response) { throw V2ClientGroupInvitationError.invalidResponse }
        return result.0
    }

    private func failure(_ response: HTTPURLResponse) -> V2ClientGroupInvitationError {
        switch response.statusCode {
        case 400: .invalidRequest
        case 401, 403: .authorizationDenied
        case 404: .unavailable
        case 409: .conflict
        case 422: .memberLimitReached
        case 429: .rateLimited(retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: .serverStatus(response.statusCode)
        }
    }
}

private struct CreateBody: Encodable { let roomID, operationID: String; let lifetimeSeconds, maximumApprovedUses: Int; enum CodingKeys: String, CodingKey { case roomID = "room_id", operationID = "operation_id", lifetimeSeconds = "lifetime_seconds", maximumApprovedUses = "maximum_approved_uses" } }
private struct RevokeBody: Encodable { let roomID, operationID: String; enum CodingKeys: String, CodingKey { case roomID = "room_id", operationID = "operation_id" } }
private struct TokenBody: Encodable { let token: String }
private struct SubmitBody: Encodable { let token, operationID: String; let note: String?; enum CodingKeys: String, CodingKey { case token, operationID = "operation_id", note } }
private struct DecisionRequestBody: Encodable { let roomID, operationID, decision: String; enum CodingKeys: String, CodingKey { case roomID = "room_id", operationID = "operation_id", decision } }
private struct LinksBody: Decodable { let items: [LinkBody] }
private struct LinkBody: Decodable { let inviteID, roomID, roomTitle, token, state: String; let expiresAtMilliseconds: Int64; let maximumApprovedUses, approvedUseCount: Int; let createdAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", token, state, expiresAtMilliseconds = "expires_at_ms", maximumApprovedUses = "maximum_approved_uses", approvedUseCount = "approved_use_count", createdAtMilliseconds = "created_at_ms" } }
private struct PreviewBody: Decodable { let inviteID, roomID, roomTitle: String; let expiresAtMilliseconds: Int64; let requestState: String?, requestID: String?; let isAlreadyMember: Bool; enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", expiresAtMilliseconds = "expires_at_ms", requestState = "request_state", requestID = "request_id", isAlreadyMember = "is_already_member" } }
private struct IdentityBody: Decodable { let userID, handle, displayName, accountKind: String; enum CodingKeys: String, CodingKey { case userID = "user_id", handle, displayName = "display_name", accountKind = "account_kind" } }
private struct RequestBody: Decodable { let requestID, inviteID, roomID: String; let applicant: IdentityBody; let note: String?, state: String, resumableDecisionOperationID: String?; let createdAtMilliseconds: Int64, decidedAtMilliseconds: Int64?; enum CodingKeys: String, CodingKey { case requestID = "request_id", inviteID = "invite_id", roomID = "room_id", applicant, note, state, resumableDecisionOperationID = "resumable_decision_operation_id", createdAtMilliseconds = "created_at_ms", decidedAtMilliseconds = "decided_at_ms" } }
private struct SubmissionBody: Decodable { let kind: String; let request: RequestBody?; let preview: PreviewBody? }
private struct RequestPageBody: Decodable { let items: [RequestBody]; let nextCursor: String?; enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" } }
private struct DecisionBody: Decodable { let kind: String; let request: RequestBody }

private func decodeLink(_ body: LinkBody) throws -> V2GroupInviteLink { guard let state = V2GroupInviteState(rawValue: body.state) else { throw V2ClientGroupInvitationError.invalidResponse }; return try .init(inviteID: .init(body.inviteID), roomID: .init(body.roomID), roomTitle: body.roomTitle, secret: .init(body.token), state: state, expiresAt: Date(timeIntervalSince1970: Double(body.expiresAtMilliseconds) / 1_000), maximumApprovedUses: body.maximumApprovedUses, approvedUseCount: body.approvedUseCount, createdAt: Date(timeIntervalSince1970: Double(body.createdAtMilliseconds) / 1_000)) }
private func decodeLink(_ data: Data) throws -> V2GroupInviteLink { do { return try decodeLink(JSONDecoder().decode(LinkBody.self, from: data)) } catch let error as V2ClientGroupInvitationError { throw error } catch { throw V2ClientGroupInvitationError.invalidResponse } }
private func decodePreview(_ body: PreviewBody) throws -> V2GroupInvitePreview { guard let state = try body.requestState.map({ guard let value = V2GroupJoinRequestState(rawValue: $0) else { throw V2ClientGroupInvitationError.invalidResponse }; return value }) else { return try .init(inviteID: .init(body.inviteID), roomID: .init(body.roomID), roomTitle: body.roomTitle, expiresAt: Date(timeIntervalSince1970: Double(body.expiresAtMilliseconds) / 1_000), requestState: nil, requestID: nil, isAlreadyMember: body.isAlreadyMember) }; guard let requestID = body.requestID else { throw V2ClientGroupInvitationError.invalidResponse }; return try .init(inviteID: .init(body.inviteID), roomID: .init(body.roomID), roomTitle: body.roomTitle, expiresAt: Date(timeIntervalSince1970: Double(body.expiresAtMilliseconds) / 1_000), requestState: state, requestID: .init(requestID), isAlreadyMember: body.isAlreadyMember) }
private func decodeRequest(_ body: RequestBody) throws -> V2GroupJoinRequest { guard let state = V2GroupJoinRequestState(rawValue: body.state), let kind = V2AccountKind(rawValue: body.applicant.accountKind) else { throw V2ClientGroupInvitationError.invalidResponse }; return try .init(requestID: .init(body.requestID), inviteID: .init(body.inviteID), roomID: .init(body.roomID), applicant: .init(userID: .init(body.applicant.userID), handle: .init(body.applicant.handle), displayName: body.applicant.displayName, accountKind: kind), note: body.note, state: state, resumableDecisionOperationID: try body.resumableDecisionOperationID.map(GroupJoinDecisionOperationID.init), createdAt: Date(timeIntervalSince1970: Double(body.createdAtMilliseconds) / 1_000), decidedAt: body.decidedAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) }) }
