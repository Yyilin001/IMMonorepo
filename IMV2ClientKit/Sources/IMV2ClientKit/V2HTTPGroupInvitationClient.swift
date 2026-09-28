import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 客户端群邀请与入群申请的封闭错误分类。
///
/// 每一类都对应一个可被上层稳定处理的结果，而不是把底层错误文本直接外泄。
public enum V2ClientGroupInvitationError: Error, Equatable, Sendable {
    /// 配置的服务端点非法（非 HTTPS 或缺少主机）。
    case invalidEndpoint
    /// 本地请求参数非法。
    case invalidRequest
    /// 当前无法取得有效凭据。
    case authorizationUnavailable
    /// 服务端拒绝了本次凭据授权。
    case authorizationDenied
    /// 依赖的服务暂时不可用。
    case unavailable
    /// 与服务端状态冲突（例如邀请已失效或已被处理）。
    case conflict
    /// 群成员数量已达上限。
    case memberLimitReached
    /// 触发限流；关联值为服务端建议的重试等待秒数。
    case rateLimited(retryAfterSeconds: Int?)
    /// 响应无法解析为预期结构。
    case invalidResponse
    /// 网络层失败（连接、超时等）。
    case networkFailure
    /// 服务端返回了未映射的状态码。
    case serverStatus(Int)
}

/// Authorized invitation read boundary. Mutations use immutable operation commands.
public protocol V2ClientGroupInvitationManaging:Sendable {
    func activeInvites(roomID:RoomID) async throws -> [V2GroupInviteLink]
    func preview(secret:V2GroupInviteSecret) async throws -> V2GroupInvitePreview
    func pendingRequests(roomID:RoomID,cursor:String?,pageSize:Int) async throws -> V2ClientGroupJoinRequestPage
}

public protocol V2ClientGroupInvitationHTTPTransport: Sendable {
    /// 执行一次请求并返回数据与响应。
    ///
    /// - Parameter request: 待发送的请求。
    /// - Returns: 响应数据与 HTTP 响应。
    /// - Throws: 传输层失败或响应类型不符时抛出。
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 基于 URLSession 的群邀请 HTTP 传输实现。
public actor V2URLSessionGroupInvitationHTTPTransport: V2ClientGroupInvitationHTTPTransport {
    private let executor: V2HTTPExecutor
    public init(session: URLSession = V2SecureURLSession.account) { executor = .init(session: session) }
    public init(executor: V2HTTPExecutor) { self.executor = executor }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await executor.execute(request, budget: .init(timeout: 15, maximumResponseBytes: 1_048_576), service: "groupInvitations")
    }

}

/// 群邀请与入群申请的 HTTP 客户端实现。
public struct V2HTTPGroupInvitationClient: V2ClientGroupInvitationManaging, Sendable {
    private let queries: V2QueryCoordinator<Data>?
    private let queryScope: V2QueryScope?
    private let baseURL: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientGroupInvitationHTTPTransport

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - baseURL: 服务基地址，必须为 HTTPS 且包含主机。
    ///   - credentials: 凭据提供方。
    ///   - transport: HTTP 传输实现，默认使用 URLSession。
    /// - Throws: 服务端点非法时抛出 `invalidEndpoint`。
    public init(
        baseURL: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientGroupInvitationHTTPTransport = V2URLSessionGroupInvitationHTTPTransport(),
        queries: V2QueryCoordinator<Data>? = nil, queryScope: V2QueryScope? = nil
    ) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil, baseURL.fragment == nil else { throw V2ClientGroupInvitationError.invalidEndpoint }
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
        self.queries = queries; self.queryScope = queryScope
    }

    public func activeInvites(roomID: RoomID) async throws -> [V2GroupInviteLink] {
        let data = try await execute(path: ["v2", "group-invites"], method: "GET", query: [.init(name: "room_id", value: roomID.rawValue)])
        do { return try JSONDecoder().decode(LinksBody.self, from: data).items.map(decodeLink) }
        catch { throw V2ClientGroupInvitationError.invalidResponse }
    }

    public func preview(secret: V2GroupInviteSecret) async throws -> V2GroupInvitePreview {
        let data = try await execute(path: ["v2", "group-invites", "preview"], method: "POST", body: TokenBody(token: secret.rawValue))
        do { return try decodePreview(JSONDecoder().decode(PreviewBody.self, from: data)) }
        catch let error as V2ClientGroupInvitationError { throw error }
        catch { throw V2ClientGroupInvitationError.invalidResponse }
    }

    public func pendingRequests(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2ClientGroupJoinRequestPage {
        guard (1 ... 100).contains(pageSize), cursor == nil || (cursor?.isEmpty == false && cursor!.utf8.count <= 1_024)
        else { throw V2ClientGroupInvitationError.invalidRequest }
        var query = [URLQueryItem(name: "room_id", value: roomID.rawValue), .init(name: "page_size", value: String(pageSize))]
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        let data = try await execute(path: ["v2", "group-join-requests"], method: "GET", query: query)
        do {
            let body = try JSONDecoder().decode(RequestPageBody.self, from: data)
            guard body.items.count <= pageSize,
                  body.nextCursor == nil || (body.nextCursor != cursor && body.nextCursor?.isEmpty == false && body.nextCursor!.utf8.count <= 1_024)
            else { throw V2ClientGroupInvitationError.invalidResponse }
            let items = try body.items.map(decodeRequest)
            guard Set(items.map(\.requestID)).count == items.count,
                  items.allSatisfy({ $0.roomID == roomID && $0.state == .pending })
            else { throw V2ClientGroupInvitationError.invalidResponse }
            return .init(requests: items, nextCursor: body.nextCursor)
        }
        catch let error as V2ClientGroupInvitationError { throw error }
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
        if method == "GET", let queries, let queryScope {
            let normalized = query.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            var components = URLComponents()
            components.path = path.joined(separator: "/")
            components.queryItems = normalized
            let key = V2QueryKey(scope: queryScope, requestID: "group-invitations:" + baseURL.absoluteString + ":" + (components.string ?? ""))
            return try await queries.query(key) {
                try await self.perform(path: path, method: method, query: normalized, bodyData: nil, expectedStatuses: expectedStatuses)
            }
        }
        return try await perform(path: path, method: method, query: query, bodyData: bodyData, expectedStatuses: expectedStatuses)
    }

    private func perform(path: [String], method: String, query: [URLQueryItem], bodyData: Data?, expectedStatuses: Set<Int>) async throws -> Data {
        let credential: V2ClientPushEndpointCredentials
        do { credential = try await credentials.pushEndpointCredentials() }
        catch is CancellationError { throw CancellationError() } catch let failure as V2HTTPFailure { throw failure } catch let auth as V2AuthSessionError { throw auth } catch { throw V2ClientGroupInvitationError.authorizationUnavailable }
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
        V2HTTPRequestDeadline.attach(credential.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if let bodyData { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = bodyData }
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as V2HTTPFailure { throw failure }
        catch let auth as V2AuthSessionError { throw auth }
        catch { throw V2ClientGroupInvitationError.networkFailure }
        try Task.checkCancellation()
        let response = result.1
        guard expectedStatuses.contains(response.statusCode) else { throw failure(response) }
        if response.statusCode != 204, !V2HTTPContract.isJSON(response) { throw V2ClientGroupInvitationError.invalidResponse }
        return result.0
    }

    private func failure(_ response: HTTPURLResponse) -> V2ClientGroupInvitationError {
        switch response.statusCode {
        case 400: .invalidRequest
        case 401: .authorizationUnavailable
        case 403: .authorizationDenied
        case 404: .unavailable
        case 409: .conflict
        case 422: .memberLimitReached
        case 429: .rateLimited(retryAfterSeconds: V2RetryAfter.date(from: response.value(forHTTPHeaderField: "Retry-After")).map { Int(ceil(max(0, $0.timeIntervalSinceNow))) })
        default: .serverStatus(response.statusCode)
        }
    }
}

private struct TokenBody: Encodable { let token: String }
private struct LinksBody: Decodable { let items: [LinkBody] }
private struct LinkBody: Decodable { let inviteID, roomID, roomTitle, token, state: String; let expiresAtMilliseconds: Int64; let maximumApprovedUses, approvedUseCount: Int; let createdAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", token, state, expiresAtMilliseconds = "expires_at_ms", maximumApprovedUses = "maximum_approved_uses", approvedUseCount = "approved_use_count", createdAtMilliseconds = "created_at_ms" } }
private struct PreviewBody: Decodable { let inviteID, roomID, roomTitle: String; let expiresAtMilliseconds: Int64; let requestState: String?, requestID: String?; let isAlreadyMember: Bool; enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id", roomTitle = "room_title", expiresAtMilliseconds = "expires_at_ms", requestState = "request_state", requestID = "request_id", isAlreadyMember = "is_already_member" } }
private struct RequestBody: Decodable { let requestID, inviteID, roomID: String; let applicantUserID: String; let note: String?, state: String, resumableDecisionOperationID: String?; let createdAtMilliseconds: Int64, decidedAtMilliseconds: Int64?; enum CodingKeys: String, CodingKey { case requestID = "request_id", inviteID = "invite_id", roomID = "room_id", applicantUserID = "applicant_user_id", note, state, resumableDecisionOperationID = "resumable_decision_operation_id", createdAtMilliseconds = "created_at_ms", decidedAtMilliseconds = "decided_at_ms" } }
private struct RequestPageBody: Decodable { let items: [RequestBody]; let nextCursor: String?; enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" } }
private func decodeLink(_ body: LinkBody) throws -> V2GroupInviteLink { guard let state = V2GroupInviteState(rawValue: body.state) else { throw V2ClientGroupInvitationError.invalidResponse }; return try .init(inviteID: .init(body.inviteID), roomID: .init(body.roomID), roomTitle: body.roomTitle, secret: .init(body.token), state: state, expiresAt: Date(timeIntervalSince1970: Double(body.expiresAtMilliseconds) / 1_000), maximumApprovedUses: body.maximumApprovedUses, approvedUseCount: body.approvedUseCount, createdAt: Date(timeIntervalSince1970: Double(body.createdAtMilliseconds) / 1_000)) }
private func decodeLink(_ data: Data) throws -> V2GroupInviteLink { do { return try decodeLink(JSONDecoder().decode(LinkBody.self, from: data)) } catch let error as V2ClientGroupInvitationError { throw error } catch { throw V2ClientGroupInvitationError.invalidResponse } }
private func decodePreview(_ body: PreviewBody) throws -> V2GroupInvitePreview { guard let state = try body.requestState.map({ guard let value = V2GroupJoinRequestState(rawValue: $0) else { throw V2ClientGroupInvitationError.invalidResponse }; return value }) else { return try .init(inviteID: .init(body.inviteID), roomID: .init(body.roomID), roomTitle: body.roomTitle, expiresAt: Date(timeIntervalSince1970: Double(body.expiresAtMilliseconds) / 1_000), requestState: nil, requestID: nil, isAlreadyMember: body.isAlreadyMember) }; guard let requestID = body.requestID else { throw V2ClientGroupInvitationError.invalidResponse }; return try .init(inviteID: .init(body.inviteID), roomID: .init(body.roomID), roomTitle: body.roomTitle, expiresAt: Date(timeIntervalSince1970: Double(body.expiresAtMilliseconds) / 1_000), requestState: state, requestID: .init(requestID), isAlreadyMember: body.isAlreadyMember) }
private func decodeRequest(_ body: RequestBody) throws -> V2ClientGroupJoinRequest { guard let state = V2GroupJoinRequestState(rawValue: body.state) else { throw V2ClientGroupInvitationError.invalidResponse }; return try .init(requestID: .init(body.requestID), inviteID: .init(body.inviteID), roomID: .init(body.roomID), applicantUserID: .init(body.applicantUserID), note: body.note, state: state, resumableDecisionOperationID: try body.resumableDecisionOperationID.map(GroupJoinDecisionOperationID.init), createdAt: Date(timeIntervalSince1970: Double(body.createdAtMilliseconds) / 1_000), decidedAt: body.decidedAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) }) }
