import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 资料视图读取能力。
public protocol V2ProfileViewReading: Sendable {
    /// 按查询键批量读取资料视图。
    ///
    /// - Parameter keys: 查询键列表。
    /// - Returns: 与查询键一一对应的结果。
    /// - Throws: 请求非法、认证失败或网络失败时抛出。
    func readProfileViews(_ keys: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult]
}

/// 资料视图客户端错误。
public enum V2ProfileViewClientError: Error, Equatable, Sendable {
    /// 端点不是合法的 HTTPS 地址。
    case invalidEndpoint
    /// 请求参数不满足约束。
    case invalidRequest
    /// 取不到可用凭据。
    case authorizationUnavailable
    /// 服务端拒绝授权。
    case authorizationDenied
    /// 响应结构不合法。
    case invalidResponse
    /// 网络请求失败。
    case networkFailure
    /// 服务端返回非预期状态码。
    case serverStatus(Int)
}

/// 面向有界、按查看者授权的资料读取的 HTTPS 账号边缘适配器。
///
/// 它刻意使用禁用缓存的请求策略：持久化资料状态由本地 SQLite 投影负责，
/// 而不是由 URLSession 的共享缓存负责。
@available(*, deprecated, message: "Use V2ProfileProjectionReader with the account's shared V2ProfilePresentationRepository. The legacy endpoint returns HTTP 410.")
public struct V2HTTPProfileViewClient: V2ProfileViewReading, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientPushEndpointHTTPTransport

    /// 校验并保存端点、凭据提供方与传输实现。
    ///
    /// - Parameters:
    ///   - endpoint: 资料端点，必须是带主机名的 HTTPS 地址。
    ///   - credentials: 提供访问令牌与设备标识的凭据来源。
    ///   - transport: HTTP 传输实现，默认使用系统 URL 会话。
    /// - Throws: 端点不是合法 HTTPS 地址时抛出
    ///   ``V2ProfileViewClientError/invalidEndpoint``。
    public init(
        endpoint: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw V2ProfileViewClientError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    /// 批量读取资料视图。
    ///
    /// 校验要求查询键非空、不超过上限且无重复；响应必须为 JSON，
    /// 且返回的结果集合必须与请求键集合完全一致，部分或多出的结果都会被拒绝。
    ///
    /// - Parameter keys: 查询键列表。
    /// - Returns: 与查询键一一对应的结果。
    /// - Throws: 键不满足约束时抛出 ``V2ProfileViewClientError/invalidRequest``；
    ///   取不到凭据时抛出 ``V2ProfileViewClientError/authorizationUnavailable``；
    ///   401 或 403 抛出 ``V2ProfileViewClientError/authorizationDenied``；
    ///   响应不合法时抛出 ``V2ProfileViewClientError/invalidResponse``；
    ///   网络失败或非预期状态码时抛出 ``V2ProfileViewClientError/networkFailure`` 或
    ///   ``V2ProfileViewClientError/serverStatus(_:)``。
    public func readProfileViews(_ keys: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult] {
        guard !keys.isEmpty, keys.count <= V2ProfileViewLookupLimits.maximumKeys, Set(keys).count == keys.count else {
            throw V2ProfileViewClientError.invalidRequest
        }
        let edgeCredentials: V2ClientPushEndpointCredentials
        do { edgeCredentials = try await credentials.pushEndpointCredentials() }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2ProfileViewClientError.authorizationUnavailable }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(edgeCredentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(edgeCredentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(RequestBody(keys: keys.map(RequestKey.init)))

        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2ProfileViewClientError.networkFailure }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2ProfileViewClientError.invalidResponse
        case 400: throw V2ProfileViewClientError.invalidRequest
        case 401, 403: throw V2ProfileViewClientError.authorizationDenied
        default: throw V2ProfileViewClientError.serverStatus(response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw V2ProfileViewClientError.invalidResponse
        }
        let results: [V2ProfileViewLookupResult]
        do { results = try body.results.map { try $0.result() } }
        catch { throw V2ProfileViewClientError.invalidResponse }
        guard results.count == keys.count,
              Set(results.map(Self.key(for:))) == Set(keys)
        else { throw V2ProfileViewClientError.invalidResponse }
        return results
    }

    /// 从结果中取出其对应的查询键。
    ///
    /// - Parameter result: 单条查询结果。
    /// - Returns: 该结果对应的查询键。
    private static func key(for result: V2ProfileViewLookupResult) -> V2ProfileViewLookupKey {
        switch result {
        case .profile(let key, _), .unavailable(let key): key
        }
    }
}

private struct RequestBody: Encodable {
    let keys: [RequestKey]
}

private struct RequestKey: Encodable {
    let userID: String
    let context: String
    let roomID: String?

    init(_ key: V2ProfileViewLookupKey) {
        userID = key.userID.rawValue
        switch key.context {
        case .directConversation:
            context = "direct"
            roomID = nil
        case .relationship:
            context = "relationship"
            roomID = nil
        case .room(let roomID):
            context = "room"
            self.roomID = roomID.rawValue
        case .groupJoinReview(let roomID):
            // The retired endpoint has no authority for this new context.
            context = "group_join_review"
            self.roomID = roomID.rawValue
        }
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case context
        case roomID = "room_id"
    }
}

private struct ResponseBody: Decodable {
    let results: [ResponseItem]
}

private struct ResponseItem: Decodable {
    let userID: String
    let context: String
    let roomID: String?
    let unavailable: Bool
    let handle: String?
    let displayName: String?
    let accountKind: V2AccountKind?
    let avatarMediaID: String?
    let state: String?
    let revision: UInt64?
    let visibilityRevision: UInt64?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case context
        case roomID = "room_id"
        case unavailable
        case handle
        case displayName = "display_name"
        case accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
    }

    /// 把线路结果解析为领域结果。
    ///
    /// 不可用结果不得携带任何资料字段；可用结果必须同时给出状态与两个修订，
    /// 身份三要素要么全部缺失要么全部存在。
    ///
    /// - Returns: 领域层查询结果。
    /// - Throws: 字段组合非法时抛出 ``V2ProfileViewClientError/invalidResponse``。
    func result() throws -> V2ProfileViewLookupResult {
        let userID = try UserID(userID)
        let context: V2ProfileViewContext
        switch self.context {
        case "direct":
            guard roomID == nil else { throw V2ProfileViewClientError.invalidResponse }
            context = .directConversation
        case "relationship":
            guard roomID == nil else { throw V2ProfileViewClientError.invalidResponse }
            context = .relationship
        case "room":
            guard let roomID else { throw V2ProfileViewClientError.invalidResponse }
            context = .room(try RoomID(roomID))
        default:
            throw V2ProfileViewClientError.invalidResponse
        }
        let key = V2ProfileViewLookupKey(userID: userID, context: context)
        if unavailable {
            guard handle == nil, displayName == nil, accountKind == nil, avatarMediaID == nil,
                  state == nil, revision == nil, visibilityRevision == nil
            else { throw V2ProfileViewClientError.invalidResponse }
            return .unavailable(key: key)
        }
        guard let rawState = state,
              let state = V2ProfileState(rawValue: rawState),
              let revision, let profileRevision = V2ProfileRevision(rawValue: revision),
              let visibilityRevision, let accessRevision = V2ProfileRevision(rawValue: visibilityRevision)
        else { throw V2ProfileViewClientError.invalidResponse }
        let identity: V2PublicIdentity?
        switch (handle, displayName, accountKind) {
        case (.none, .none, .none): identity = nil
        case let (.some(handle), .some(displayName), .some(accountKind)):
            identity = try .init(userID: userID, handle: .init(handle), displayName: displayName, accountKind: accountKind)
        default: throw V2ProfileViewClientError.invalidResponse
        }
        let avatar = try avatarMediaID.map { try V2AvatarReference(mediaID: .init($0)) }
        let view = try V2ProfileView(
            userID: userID,
            publicIdentity: identity,
            avatar: avatar,
            state: state,
            revision: profileRevision,
            visibilityRevision: accessRevision
        )
        return .profile(key: key, view: view)
    }
}
