import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 撤销接口返回的业务结果，与暂时传输失败分开建模。
public enum V2DeviceRevocationResult: Equatable, Sendable {
    /// 服务端返回空体 204，确认撤销请求成功。
    case revoked
    /// 服务端识别该撤销能力但确认兑换期限已过；可以结束该能力的重试，不代表撤销事务已提交。
    case expired
    /// 服务端拒绝撤销凭证，应暂停任务而非尝试借用新账户令牌。
    case invalidCredential
    /// 服务端报告操作身份冲突，自动重复请求不能解决，需要暂停处理。
    case operationConflict
}

/// 仅凭独立撤销能力与稳定操作身份执行设备撤销的传输边界。
public protocol V2DeviceRevocationClient: Sendable {
    /// 提交目的受限的撤销凭证并返回服务端业务结果。
    ///
    /// - Parameters:
    ///   - credential: 原设备会话的撤销能力。
    ///   - operationID: 本次撤销在各次重试中稳定的操作身份。
    /// - Returns: 已撤销、已过期、凭证无效或操作冲突。
    /// - Throws: 取消或传输失败，不能据此认定远端操作未发生。
    func revoke(credential: V2DeviceRevocationCredential, operationID: UUID) async throws -> V2DeviceRevocationResult
}

/// 撤销请求的配置、响应、网络及 HTTP 错误分类，由执行器决定退避或暂停。
public enum V2DeviceRevocationClientError: Error, Equatable, Sendable {
    /// 端点不是具有非空主机的 HTTPS URL，或包含用户信息、查询、片段。
    case invalidEndpoint
    /// 服务端成功响应不符合空体 204 合同。
    case invalidResponse
    /// 非取消类传输错误，不暴露底层错误中的敏感上下文。
    case networkFailure
    /// 服务端限流；可选等待值仅解析 Retry-After 的非负整数秒，不支持 HTTP 日期形式。
    case rateLimited(retryAfterSeconds: Int?)
    /// 未单独处理的 HTTP 状态码，由执行器分类是否可重试。
    case serverStatus(Int)
}

/// 通过 HTTPS 提交旧设备会话的独立撤销凭证。
///
/// 不依赖认证会话，也不注入访问令牌；重试不能刷新或借用另一个账户的登录凭证。
/// 不在此维护重试任务，操作身份由持久化撤销队列提供。
public struct V2HTTPDeviceRevocationClient: V2DeviceRevocationClient {
    /// 完整撤销端点，直接用于请求，不追加路径。
    private let endpoint: URL
    /// 可注入的 HTTP 传输，负责执行请求并返回响应。
    private let transport: any V2AuthHTTPTransport

    /// 校验并保存撤销端点及 HTTP 传输，不发送请求。
    ///
    /// - Parameters:
    ///   - endpoint: 包含非空主机的 HTTPS 地址，不允许用户信息、查询或片段。
    ///   - transport: 默认使用 URLSession 认证 HTTP 传输。
    /// - Throws: 端点不符合要求时抛出 invalidEndpoint。
    public init(endpoint: URL, transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()) throws {
        guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
        else { throw V2DeviceRevocationClientError.invalidEndpoint }
        self.endpoint = endpoint
        self.transport = transport
    }

    /// 发送 JSON POST 撤销请求，超时为 15 秒，禁用请求缓存并声明 no-store。
    ///
    /// - Parameters:
    ///   - credential: 原设备会话的撤销凭证。
    ///   - operationID: 跨重试稳定的操作 UUID。
    /// - Returns: 空体 204 映射为 revoked，401 为 invalidCredential，410 为 expired，409 为 operationConflict。
    /// - Throws: 取消、网络失败、非空 204、429 限流或其他 HTTP 状态错误。
    ///
    /// 传输前后检查取消；URLSession 的 cancelled 错误也转换为 CancellationError。
    /// 429 只读取非负整数秒的 Retry-After，不在本方法内等待或重试。
    public func revoke(credential: V2DeviceRevocationCredential, operationID: UUID) async throws -> V2DeviceRevocationResult {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(Body(credential: credential, operationID: operationID))
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let failure as V2HTTPFailure { throw failure }
        catch let error as V2AuthSessionError { throw error }
        catch { throw V2DeviceRevocationClientError.networkFailure }
        try Task.checkCancellation()
        switch response.statusCode {
        case 204:
            guard data.isEmpty else { throw V2DeviceRevocationClientError.invalidResponse }
            return .revoked
        case 401: return .invalidCredential
        case 410: return .expired
        case 409: return .operationConflict
        case 429:
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            throw V2DeviceRevocationClientError.rateLimited(retryAfterSeconds: seconds)
        default: throw V2DeviceRevocationClientError.serverStatus(response.statusCode)
        }
    }

    /// JSON 请求体，只发送目的受限的撤销凭证和稳定操作 UUID。
    private struct Body: Encodable {
        /// 敏感撤销能力，不包含访问或刷新令牌。
        let credential: V2DeviceRevocationCredential
        /// 队列分配并在重试中复用的操作身份。
        let operationID: UUID
    }
}
