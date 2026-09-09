import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 在已认证账户服务端按精确公开标识查找单个身份。
///
/// 用于用户明确发起的私聊或群成员添加等操作，不提供缓存或批量查询；可靠资料投影由同步层负责。
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
public struct V2HTTPPublicIdentityDirectory: V2PublicIdentityResolving, Sendable {
    /// 公开身份查询地址，发送时将查询参数替换为单个 handle 参数。
    private let endpoint: URL
    /// 提供一致访问令牌与设备身份的凭证边界。
    private let credentials: any V2ClientPushEndpointCredentialProvider
    /// 执行目录查询的 HTTP 传输，可注入账户代际约束适配器。
    private let transport: any V2ClientPushEndpointHTTPTransport

    /// 保存查询端点与认证依赖，不立即获取令牌。
    ///
    /// - Parameters:
    ///   - endpoint: HTTPS 地址，要求 host 非 nil；不额外排除用户信息或片段。
    ///   - credentials: 提供业务请求令牌与设备身份。
    ///   - transport: 默认使用推送端点 URLSession 传输适配器。
    /// - Throws: 地址不符合条件时抛出 invalidEndpoint。
    public init(
        endpoint: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else { throw V2PublicIdentityDirectoryClientError.invalidEndpoint }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    /// 规范化公开标识、获取凭证并发送一次带 handle 查询参数的 GET 请求。
    ///
    /// - Parameter handle: 须通过 V2PublicHandle 校验的公开账号标识。
    /// - Returns: 通过公开身份模型校验的服务端结果；不额外要求响应 handle 与请求一致。
    /// - Throws: 输入、凭证读取、授权、未找到、限流或响应错误。
    ///
    /// 设置 15 秒超时及禁止缓存策略，200 必须满足 JSON 内容类型判断。仅 CancellationError 保持取消语义，其他底层错误映射为网络失败。
    /// 此方法不单独检查账户代际；需要生命周期约束时，凭证提供者和传输应使用同一会话授权适配器。
    public func resolve(handle: String) async throws -> V2PublicIdentity {
        let canonical: V2PublicHandle
        do { canonical = try .init(handle) } catch { throw V2PublicIdentityDirectoryClientError.invalidHandle }
        let edgeCredentials: V2ClientPushEndpointCredentials
        do { edgeCredentials = try await credentials.pushEndpointCredentials() } catch is CancellationError { throw CancellationError() }
        catch { throw V2PublicIdentityDirectoryClientError.authorizationUnavailable }

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
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2PublicIdentityDirectoryClientError.invalidResponse
        case 401, 403: throw V2PublicIdentityDirectoryClientError.authorizationDenied
        case 404: throw V2PublicIdentityDirectoryClientError.notFound
        case 429: throw V2PublicIdentityDirectoryClientError.rateLimited(retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: throw V2PublicIdentityDirectoryClientError.serverStatus(response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(IdentityResponse.self, from: data),
              let userID = try? UserID(body.userID),
              let identity = try? V2PublicIdentity(userID: userID, handle: .init(body.handle), displayName: body.displayName, accountKind: body.accountKind)
        else { throw V2PublicIdentityDirectoryClientError.invalidResponse }
        return identity
    }
}

/// 目录成功响应的 JSON 模型，随后转换为经过校验的公开身份。
private struct IdentityResponse: Decodable {
    /// 响应声明的用户标识。
    let userID: String
    /// 响应声明的公开账号标识。
    let handle: String
    /// 用户展示名称。
    let displayName: String
    /// 服务端返回的账户类别。
    let accountKind: V2AccountKind

}
