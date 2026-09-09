import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 缺少新版取消证明的历史注册目标，只保存精确设备与操作身份。
///
/// 取消需要另外取得新账户因子，不能将此记录本身视为取消权限。
public struct V2LegacyDeviceRegistration: Codable, Equatable, Sendable {
    /// 待清理历史注册的设备身份。
    public let deviceID: DeviceID
    /// 历史注册原操作 UUID，恢复时不得替换为新身份。
    public let operationID: UUID

    /// 保存历史注册目标并要求设备标识可解析为 UUID。
    ///
    /// - Parameters:
    ///   - deviceID: 历史设备身份，保留输入表示。
    ///   - operationID: 原注册操作身份。
    /// - Throws: 设备标识不能解析为 UUID 时抛出 invalidRequest。
    ///
    /// 自动合成的 Codable 解码不调用此构造器，取消客户端会再次检查设备格式。
    public init(deviceID: DeviceID, operationID: UUID) throws {
        guard deviceID.uuidValue != nil else { throw V2LegacyRegistrationCancellationError.invalidRequest }
        self.deviceID = deviceID; self.operationID = operationID
    }
}

/// 历史注册恢复的端点、输入、传输及业务错误。
///
/// invalidEndpoint 表示端点无效，invalidRequest 表示输入或服务端请求校验失败，invalidResponse 表示成功响应不符合约定，networkFailure 表示非取消类传输失败。
/// authenticationRequired、accountUnavailable、targetUnavailable、conflict、capacityExceeded 分别保留认证、账户、目标、冲突和容量失败语义。
public enum V2LegacyRegistrationCancellationError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidRequest, invalidResponse, networkFailure
    case authenticationRequired, accountUnavailable, targetUnavailable, conflict, capacityExceeded
    /// 服务端限流，可选等待值仅解析 Retry-After 中的非负整数秒。
    case rateLimited(retryAfterSeconds: Int?)
    /// 没有单独业务映射的 HTTP 状态码。
    case serverStatus(Int)
}

/// 使用新账户断言清理精确历史注册目标的传输边界，不依赖现有登录令牌。
public protocol V2LegacyRegistrationCancellationClient: Sendable {
    /// 用新账户断言取消归档的精确历史注册，仅在确认完成后返回。
    ///
    /// - Parameters:
    ///   - registration: 历史注册设备及原操作身份。
    ///   - accountAssertion: 新取得的一次性账户因子。
    ///   - assertionDeviceID: 该因子绑定的设备身份。
    /// - Throws: 认证、目标、冲突、传输或取消错误；失败不代表远端操作没有发生。
    func cancel(_ registration: V2LegacyDeviceRegistration, accountAssertion: String, assertionDeviceID: DeviceID) async throws
}

/// 提交新账户因子与归档目标的历史注册取消 HTTPS 客户端。
///
/// 不读取当前登录凭证，不持久化或自动重试账户断言；仅空体 204 表示本次操作确认完成。
public struct V2HTTPLegacyRegistrationCancellationClient: V2LegacyRegistrationCancellationClient {
    /// 完整历史注册取消端点，不追加路径。
    private let endpoint: URL
    /// 可注入的账户 HTTP 传输。
    private let transport: any V2AuthHTTPTransport

    /// 校验并保存 HTTPS 取消端点与传输。
    ///
    /// - Parameters:
    ///   - endpoint: 主机非空，不包含用户信息、查询或片段的 HTTPS URL。
    ///   - transport: 默认使用账户服务的隔离 URLSession 传输。
    /// - Throws: 地址不符合约束时抛出 invalidEndpoint。
    public init(endpoint: URL, transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()) throws {
        guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
        else { throw V2LegacyRegistrationCancellationError.invalidEndpoint }
        self.endpoint = endpoint; self.transport = transport
    }

    /// 校验新断言与历史目标后发送一次 JSON POST，要求空体 204 才成功。
    ///
    /// - Parameters:
    ///   - registration: 精确历史设备及原操作 UUID。
    ///   - accountAssertion: 新账户因子产生的断言，裁剪后非空且 UTF-8 长度不超过 4096 字节。
    ///   - assertionDeviceID: 断言绑定的设备，须为 UUID 且与目标设备的 DeviceID 值不同。
    /// - Throws: 输入无效、取消、网络或响应错误，以及按状态分类的恢复业务错误。
    ///
    /// 400/401/403/404/409/507 分别映射为请求无效、需要认证、账户不可用、目标不可用、冲突和容量不足；429 提供可选等待秒数。
    /// 请求超时为 15 秒并禁止缓存；传输前后检查取消，URL 取消错误也保留取消语义。此处不额外校验断言控制字符，也不自动重试。
    public func cancel(_ registration: V2LegacyDeviceRegistration, accountAssertion: String, assertionDeviceID: DeviceID) async throws {
        try Task.checkCancellation()
        guard registration.deviceID.uuidValue != nil, assertionDeviceID.uuidValue != nil,
              registration.deviceID != assertionDeviceID,
              !accountAssertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountAssertion.utf8.count <= 4_096 else { throw V2LegacyRegistrationCancellationError.invalidRequest }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(Request(accountAssertion: accountAssertion,
            assertionDeviceID: assertionDeviceID.rawValue, targetDeviceID: registration.deviceID.rawValue, operationID: registration.operationID))
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw V2LegacyRegistrationCancellationError.networkFailure }
        try Task.checkCancellation()
        switch response.statusCode {
        case 204:
            guard data.isEmpty else { throw V2LegacyRegistrationCancellationError.invalidResponse }
        case 400: throw V2LegacyRegistrationCancellationError.invalidRequest
        case 401: throw V2LegacyRegistrationCancellationError.authenticationRequired
        case 403: throw V2LegacyRegistrationCancellationError.accountUnavailable
        case 404: throw V2LegacyRegistrationCancellationError.targetUnavailable
        case 409: throw V2LegacyRegistrationCancellationError.conflict
        case 507: throw V2LegacyRegistrationCancellationError.capacityExceeded
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            throw V2LegacyRegistrationCancellationError.rateLimited(retryAfterSeconds: delay)
        default: throw V2LegacyRegistrationCancellationError.serverStatus(response.statusCode)
        }
    }

    /// 历史恢复 JSON 请求体，同时指定断言绑定设备与被清理的历史设备。
    private struct Request: Encodable {
        /// 仅用于本次恢复的敏感账户断言。
        let accountAssertion: String
        /// 新账户因子绑定设备的原始标识。
        let assertionDeviceID: String
        /// 待清理历史注册设备的原始标识。
        let targetDeviceID: String
        /// 精确历史注册操作 UUID。
        let operationID: UUID
    }
}
