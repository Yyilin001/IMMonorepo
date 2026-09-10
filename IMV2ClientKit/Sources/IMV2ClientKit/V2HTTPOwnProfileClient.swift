import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 本人资料的管理能力。
public protocol V2OwnProfileManaging: Sendable {
    /// 读取当前用户的完整资料。
    ///
    /// - Returns: 当前资料视图。
    /// - Throws: 认证、网络或响应解析失败时抛出。
    func currentProfile() async throws -> V2ProfileView

    /// 更新当前用户的资料。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - expectedRevision: 期望的当前修订。
    ///   - displayName: 新的展示名称。
    ///   - avatar: 新的头像引用。
    /// - Returns: 更新后的资料视图。
    /// - Throws: 修订冲突、认证失败或网络失败时抛出。
    func updateProfile(
        operationID: ProfileUpdateOperationID,
        expectedRevision: V2ProfileRevision,
        displayName: String,
        avatar: V2AvatarReference?
    ) async throws -> V2ProfileView
}

/// 本人资料 HTTP 客户端错误。
public enum V2OwnProfileClientError: Error, Equatable, Sendable {
    /// 端点不是合法的 HTTPS 地址。
    case invalidEndpoint
    /// 取不到可用凭据。
    case authorizationUnavailable
    /// 服务端拒绝授权。
    case authorizationDenied
    /// 请求参数不满足服务端约束。
    case invalidRequest
    /// 修订冲突，参数为服务端给出的当前修订。
    case revisionConflict(V2ProfileRevision)
    /// 响应结构不合法。
    case invalidResponse
    /// 网络请求失败。
    case networkFailure
    /// 服务端返回非预期状态码。
    case serverStatus(Int)
}

/// 完整本人资料文档的已认证、禁用缓存客户端。
///
/// 重试身份与修订栅栏由调用方负责；该适配器绝不会在用户不知情的情况下自行重试写入。
public struct V2HTTPOwnProfileClient: V2OwnProfileManaging, Sendable {
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
    ///   ``V2OwnProfileClientError/invalidEndpoint``。
    public init(
        endpoint: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw V2OwnProfileClientError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    /// 读取当前用户的完整资料。
    ///
    /// - Returns: 当前资料视图。
    /// - Throws: 认证或网络失败时抛出对应错误；响应不合法时抛出
    ///   ``V2OwnProfileClientError/invalidResponse``。
    public func currentProfile() async throws -> V2ProfileView {
        let request = try await authenticatedRequest(method: "GET")
        return try await send(request, expectedRevision: nil)
    }

    /// 更新当前用户的资料。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - expectedRevision: 期望的当前修订。
    ///   - displayName: 新的展示名称。
    ///   - avatar: 新的头像引用。
    /// - Returns: 更新后的资料视图。
    /// - Throws: 修订冲突时抛出
    ///   ``V2OwnProfileClientError/revisionConflict(_:)``；其余失败同读取路径。
    public func updateProfile(
        operationID: ProfileUpdateOperationID,
        expectedRevision: V2ProfileRevision,
        displayName: String,
        avatar: V2AvatarReference?
    ) async throws -> V2ProfileView {
        var request = try await authenticatedRequest(method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(UpdateBody(
            operationID: operationID.rawValue,
            expectedRevision: expectedRevision.rawValue,
            displayName: displayName,
            avatarMediaID: avatar?.mediaID.rawValue
        ))
        return try await send(request, expectedRevision: expectedRevision)
    }

    /// 构造带 Bearer 令牌与设备标识的请求。
    ///
    /// 请求显式禁用本地与远端缓存，并设置 15 秒超时。
    ///
    /// - Parameter method: HTTP 方法。
    /// - Returns: 可发送的请求。
    /// - Throws: 任务取消时抛出 `CancellationError`；取不到凭据时抛出
    ///   ``V2OwnProfileClientError/authorizationUnavailable``。
    private func authenticatedRequest(method: String) async throws -> URLRequest {
        let credential: V2ClientPushEndpointCredentials
        do { credential = try await credentials.pushEndpointCredentials() }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2OwnProfileClientError.authorizationUnavailable }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    /// 发送请求并解析资料响应。
    ///
    /// 401 与 403 统一视为授权被拒；409 需要响应中带可解析的当前修订，否则视为响应不合法。
    ///
    /// - Parameters:
    ///   - request: 待发送请求。
    ///   - expectedRevision: 期望的修订，仅用于可读性标注。
    /// - Returns: 解析出的资料视图。
    /// - Throws: 网络失败、授权被拒、修订冲突或响应不合法时抛出对应错误。
    private func send(_ request: URLRequest, expectedRevision: V2ProfileRevision?) async throws -> V2ProfileView {
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2OwnProfileClientError.networkFailure }
        if response.statusCode == 401 || response.statusCode == 403 { throw V2OwnProfileClientError.authorizationDenied }
        let body = try? JSONDecoder().decode(ResponseBody.self, from: data)
        if response.statusCode == 409 {
            guard let revision = body?.currentRevision.flatMap(V2ProfileRevision.init(rawValue:)) else {
                throw V2OwnProfileClientError.invalidResponse
            }
            throw V2OwnProfileClientError.revisionConflict(revision)
        }
        guard (200...299).contains(response.statusCode) else { throw V2OwnProfileClientError.serverStatus(response.statusCode) }
        guard let body, let view = try? body.profileView() else { throw V2OwnProfileClientError.invalidResponse }
        _ = expectedRevision
        return view
    }
}

private struct UpdateBody: Encodable {
    let operationID: String
    let expectedRevision: UInt64
    let displayName: String
    let avatarMediaID: String?
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", expectedRevision = "expected_revision"
        case displayName = "display_name", avatarMediaID = "avatar_media_id"
    }
}

private struct ResponseBody: Decodable {
    let userID: String?
    let handle: String?
    let displayName: String?
    let accountKind: V2AccountKind?
    let avatarMediaID: String?
    let state: V2ProfileState?
    let revision: UInt64?
    let visibilityRevision: UInt64?
    let currentRevision: UInt64?
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", handle
        case displayName = "display_name", accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id", state, revision
        case visibilityRevision = "visibility_revision", currentRevision = "current_revision"
    }
    func profileView() throws -> V2ProfileView {
        guard let userID, let handle, let displayName, let accountKind, let state, let revision,
              let revision = V2ProfileRevision(rawValue: revision),
              let visibilityRevision, let visibilityRevision = V2ProfileRevision(rawValue: visibilityRevision)
        else { throw V2OwnProfileClientError.invalidResponse }
        let parsedUserID = try UserID(userID)
        let identity = try V2PublicIdentity(userID: parsedUserID, handle: .init(handle), displayName: displayName, accountKind: accountKind)
        return try .init(
            userID: parsedUserID,
            publicIdentity: identity,
            avatar: try avatarMediaID.map { try .init(mediaID: .init($0)) },
            state: state,
            revision: revision,
            visibilityRevision: visibilityRevision
        )
    }
}
