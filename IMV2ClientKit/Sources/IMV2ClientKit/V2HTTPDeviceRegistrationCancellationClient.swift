import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 注册取消接口可确认的终结结果，区分明确取消与服务端确认期限结束。
public enum V2DeviceRegistrationCancellationResult: Equatable, Sendable {
    /// 服务端确认注册已持久化取消，包括该注册已签发的会话。
    case cancelled
    /// 服务端确认不再允许后续签发，或绑定会话期限已结束；不代表本请求提交了撤销事务。
    case expired
}

/// 注册取消传输错误。
///
/// invalidEndpoint 表示端点配置无效；invalidResponse 表示终结响应不符合空体约定；networkFailure 表示非取消类传输失败。
public enum V2DeviceRegistrationCancellationClientError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidResponse, networkFailure
    /// 服务端限流，可选等待值仅解析非负整数秒形式的 Retry-After，不支持 HTTP 日期。
    case rateLimited(retryAfterSeconds: Int?)
    /// 未单独处理的 HTTP 状态码，交由执行器分类暂停或重试。
    case serverStatus(Int)
}

/// 使用签发前保存的完整取消材料终结单个注册的传输边界。
public protocol V2DeviceRegistrationCancellationClient: Sendable {
    /// 提交稳定取消材料，返回服务端确认的终结结果；失败抛出错误，不因本地截止时间已过而伪造完成。
    func cancel(_ registration: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationResult
}

/// 只使用签发前取消证明的 HTTPS 注册取消适配器。
///
/// 不持有账户访问或刷新凭证，重试不能借用当前登录权限。每次调用只发送一次请求，重试与持久化由外层执行器负责。
public struct V2HTTPDeviceRegistrationCancellationClient: V2DeviceRegistrationCancellationClient {
    /// 完整取消端点，发送时不追加路径。
    private let endpoint: URL
    /// 执行 HTTP 请求的可注入传输。
    private let transport: any V2AuthHTTPTransport

    /// 校验端点并保存传输，不立即取消注册。
    ///
    /// - Parameters:
    ///   - endpoint: HTTPS 地址，主机非空且不含用户信息、查询和片段。
    ///   - transport: 默认使用账户服务的隔离 URLSession 适配器。
    /// - Throws: 端点不满足约束时抛出 invalidEndpoint。
    public init(endpoint: URL, transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()) throws {
        guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
        else { throw V2DeviceRegistrationCancellationClientError.invalidEndpoint }
        self.endpoint = endpoint; self.transport = transport
    }

    /// 将完整取消材料编码为 JSON POST，设置 15 秒超时并禁止缓存。
    ///
    /// - Parameter registration: 原始设备、操作身份、证明及签发截止时间，重试时应保持不变。
    /// - Returns: 空体 204 对应 cancelled，空体 410 对应 expired。
    /// - Throws: 取消、网络错误、204/410 非空响应、限流或其他状态错误。
    ///
    /// 传输前后检查取消，URLError.cancelled 也映射为 CancellationError。429 的等待秒数由上层约束并执行，本方法不等待或重试。
    public func cancel(_ registration: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationResult {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(registration)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw V2DeviceRegistrationCancellationClientError.networkFailure }
        try Task.checkCancellation()
        switch response.statusCode {
        case 204, 410:
            guard data.isEmpty else { throw V2DeviceRegistrationCancellationClientError.invalidResponse }
            return response.statusCode == 204 ? .cancelled : .expired
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            throw V2DeviceRegistrationCancellationClientError.rateLimited(retryAfterSeconds: delay)
        default: throw V2DeviceRegistrationCancellationClientError.serverStatus(response.statusCode)
        }
    }
}
