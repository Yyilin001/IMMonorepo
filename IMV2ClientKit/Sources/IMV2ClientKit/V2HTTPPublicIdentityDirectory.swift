import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 在已认证账户服务端按精确公开标识查找单个身份。
///
/// 用于明确发起的命令目标解析。返回内容不授予长期展示权限；发现页面使用
/// V2PublicIdentityPresentationResolving，其余页面使用完整上下文的资料管线。
public protocol V2PublicIdentityResolving: Sendable {
    /// 解析一个公开账号标识并返回身份，查找、授权或传输失败通过错误报告。
    func resolve(handle: String) async throws -> V2PublicIdentity
}

/// 公开身份目录的输入、授权、查询及传输错误。
public enum V2PublicIdentityDirectoryClientError: Error, Equatable, Sendable {
    /// 端点不满足 HTTPS 与主机条件，或查询 URL 无法构造。
    case invalidEndpoint
    /// 输入未通过 V2PublicHandle 校验。
    case invalidHandle
    /// 无法取得请求所需的访问令牌与设备身份。
    case authorizationUnavailable
    /// 服务端返回 401 或 403，拒绝本次查询。
    case authorizationDenied
    /// 服务端返回 404，未找到目标。
    case notFound
    /// 服务端限流，附带能解析为 Int 的 Retry-After；此处未约束非负值，也不支持 HTTP 日期。
    case rateLimited(retryAfterSeconds: Int?)
    /// 成功响应类型、JSON 或公开身份字段不符合模型要求。
    case invalidResponse
    /// 非 CancellationError 的传输失败。
    case networkFailure
    /// 未单独映射的 HTTP 状态码。
    case serverStatus(Int)
}

/// 通过带账户令牌和设备身份的 HTTPS GET 查询公开身份，每次调用发送一次请求，不保存结果。
public struct V2HTTPPublicIdentityDirectory: V2PublicIdentityResolving, V2PublicIdentityPresentationResolving, Sendable {
    /// 公开身份查询地址，发送时将查询参数替换为单个 handle 参数。
    private let endpoint: URL
    /// 提供一致访问令牌与设备身份的凭证边界。
    private let credentials: any V2ClientPushEndpointCredentialProvider
    /// 执行目录查询的 HTTP 传输，可注入账户代际约束适配器。
    private let transport: any V2ClientPushEndpointHTTPTransport
    private let actorUserID: UserID

    /// 保存查询端点与认证依赖，不立即获取令牌。
    ///
    /// - Parameters:
    ///   - endpoint: 带主机的 HTTPS 地址，不允许用户信息或片段。
    ///   - actorUserID: 当前账户，用于验证查询结果的接收者绑定。
    ///   - credentials: 提供业务请求令牌与设备身份。
    ///   - transport: 默认使用推送端点 URLSession 传输适配器。
    /// - Throws: 地址不符合条件时抛出 invalidEndpoint。
    public init(
        endpoint: URL,
        actorUserID: UserID,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host?.isEmpty == false,
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil
        else { throw V2PublicIdentityDirectoryClientError.invalidEndpoint }
        self.endpoint = endpoint
        self.actorUserID = actorUserID
        self.credentials = credentials
        self.transport = transport
    }

    /// 规范化公开标识、获取凭证并发送一次带 handle 查询参数的 GET 请求。
    ///
    /// - Parameter handle: 须通过 V2PublicHandle 校验的公开账号标识。
    /// - Returns: 与精确查询匹配且本次仍获准的命令目标；不允许据此无限期展示。
    /// - Throws: 输入、凭证读取、授权、未找到、限流或响应错误。
    ///
    /// 设置 15 秒超时及禁止缓存策略，200 必须满足 JSON 内容类型判断。仅 CancellationError 保持取消语义，其他底层错误映射为网络失败。
    /// 结果必须绑定当前账户、请求设备和精确 handle。账户代际仍由共用的会话授权适配器约束。
    public func resolve(handle: String) async throws -> V2PublicIdentity {
        try await resolveForPresentation(handle: handle).identity
    }

    public func resolveForPresentation(handle: String) async throws -> V2PublicIdentityLookupSnapshot {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let canonical: V2PublicHandle
        do { canonical = try .init(handle) } catch { throw V2PublicIdentityDirectoryClientError.invalidHandle }
        let edgeCredentials: V2ClientPushEndpointCredentials
        do { edgeCredentials = try await credentials.pushEndpointCredentials() } catch is CancellationError { throw CancellationError() }
        catch { throw V2PublicIdentityDirectoryClientError.authorizationUnavailable }
        try Task.checkCancellation()
        guard !edgeCredentials.accessToken.isEmpty,
              !edgeCredentials.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw V2PublicIdentityDirectoryClientError.authorizationUnavailable }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "handle", value: canonical.rawValue)]
        guard let url = components?.url else { throw V2PublicIdentityDirectoryClientError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(edgeCredentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(edgeCredentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) } catch is CancellationError { throw CancellationError() }
        catch { throw V2PublicIdentityDirectoryClientError.networkFailure }
        try Task.checkCancellation()
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2PublicIdentityDirectoryClientError.invalidResponse
        case 401, 403: throw V2PublicIdentityDirectoryClientError.authorizationDenied
        case 404: throw V2PublicIdentityDirectoryClientError.notFound
        case 429: throw V2PublicIdentityDirectoryClientError.rateLimited(retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: throw V2PublicIdentityDirectoryClientError.serverStatus(response.statusCode)
        }
        guard data.count <= 8 * 1_024,
              let resolution = try? JSONDecoder().decode(V2PublicIdentityResolution.self, from: data),
              resolution.actorUserID == actorUserID, resolution.deviceID == edgeCredentials.deviceID,
              resolution.identity.handle == canonical
        else { throw V2PublicIdentityDirectoryClientError.invalidResponse }
        return try .init(resolution: resolution, requestStartedAt: started, responseReceivedAt: .now)
    }
}
