import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 账号边缘返回的账号自有会话元数据。
///
/// 设备标识是不透明值，只用于显式的远程登出命令。
public struct V2ClientDeviceSession: Equatable, Sendable, Identifiable {
    /// 设备标识。
    public let deviceID: DeviceID
    /// 设备名称。
    public let deviceName: String
    /// 设备平台。
    public let platform: String
    /// 会话创建时刻。
    public let createdAt: Date
    /// 最近活跃时刻。
    public let lastActiveAt: Date
    /// 是否为当前设备。
    public let isCurrentDevice: Bool

    /// 用于列表标识。
    public var id: DeviceID { deviceID }

    /// 保存会话元数据。
    ///
    /// - Parameters:
    ///   - deviceID: 设备标识。
    ///   - deviceName: 设备名称。
    ///   - platform: 设备平台。
    ///   - createdAt: 会话创建时刻。
    ///   - lastActiveAt: 最近活跃时刻。
    ///   - isCurrentDevice: 是否为当前设备。
    public init(deviceID: DeviceID, deviceName: String, platform: String, createdAt: Date, lastActiveAt: Date, isCurrentDevice: Bool) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.isCurrentDevice = isCurrentDevice
    }
}

/// 会话列表分页。
public struct V2ClientDeviceSessionPage: Equatable, Sendable {
    /// 本页会话。
    public let sessions: [V2ClientDeviceSession]
    /// 下一页游标；为空表示已到末尾。
    public let nextCursor: String?

    /// 保存会话分页。
    ///
    /// - Parameters:
    ///   - sessions: 本页会话。
    ///   - nextCursor: 下一页游标。
    public init(sessions: [V2ClientDeviceSession], nextCursor: String?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

/// 会话接口使用的边缘凭据。
public struct V2ClientDeviceSessionCredentials: Sendable {
    /// 访问令牌。
    public let accessToken: String
    /// 当前设备标识。
    public let deviceID: DeviceID
    /// Local monotonic request budget; never encoded or persisted with credentials.
    public let requestDeadline: ContinuousClock.Instant?

    /// 保存凭据。
    ///
    /// - Parameters:
    ///   - accessToken: 访问令牌。
    ///   - deviceID: 当前设备标识。
    public init(accessToken: String, deviceID: DeviceID, requestDeadline: ContinuousClock.Instant? = nil) { self.accessToken = accessToken; self.deviceID = deviceID; self.requestDeadline = requestDeadline }
}

/// 会话接口的凭据提供能力。
public protocol V2ClientDeviceSessionCredentialProvider: Sendable {
    /// 获取一次边缘凭据。
    ///
    /// - Returns: 访问令牌与当前设备标识。
    /// - Throws: 凭据不可用时抛出。
    func deviceSessionCredentials() async throws -> V2ClientDeviceSessionCredentials
}

/// 会话接口的 HTTP 传输能力。
public protocol V2ClientDeviceSessionHTTPTransport: Sendable {
    /// 执行一次 HTTP 请求。
    ///
    /// - Parameter request: 待发送请求。
    /// - Returns: 响应体与 HTTP 响应。
    /// - Throws: 网络失败或响应不可解析时抛出。
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 基于 URLSession 的会话传输实现。
public actor V2URLSessionDeviceSessionHTTPTransport: V2ClientDeviceSessionHTTPTransport {
    private let executor: V2HTTPExecutor
    public init(session: URLSession = V2SecureURLSession.account) { executor = .init(session: session) }
    public init(executor: V2HTTPExecutor) { self.executor = executor }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await executor.execute(request, budget: .init(timeout: 15, maximumResponseBytes: 1_048_576), service: "deviceSessions")
    }

}

/// 账号会话的管理能力。
public protocol V2ClientDeviceSessionManaging: Sendable {
    /// 分页读取账号的活跃会话。
    ///
    /// - Parameters:
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数。
    /// - Returns: 会话分页。
    /// - Throws: 认证、网络或响应解析失败时抛出。
    func list(cursor: String?, pageSize: Int) async throws -> V2ClientDeviceSessionPage


}

/// 账号边缘的 HTTPS 适配器。
///
/// 调用方为每次用户意图提供一个稳定操作标识，因此响应中断后的重试是安全的。
public struct V2HTTPDeviceSessionClient: V2ClientDeviceSessionManaging, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientDeviceSessionCredentialProvider
    private let transport: any V2ClientDeviceSessionHTTPTransport

    /// 校验并保存端点、凭据提供方与传输实现。
    ///
    /// - Parameters:
    ///   - endpoint: 会话端点，必须是带主机名的 HTTPS 地址。
    ///   - credentials: 提供访问令牌与设备标识的凭据来源。
    ///   - transport: HTTP 传输实现，默认使用系统 URL 会话。
    /// - Throws: 端点不是合法 HTTPS 地址时抛出
    ///   ``V2ClientDeviceSessionError/invalidEndpoint``。
    public init(endpoint: URL, credentials: any V2ClientDeviceSessionCredentialProvider, transport: any V2ClientDeviceSessionHTTPTransport = V2URLSessionDeviceSessionHTTPTransport()) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else { throw V2ClientDeviceSessionError.invalidEndpoint }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    /// 分页读取账号的活跃会话。
    ///
    /// - Parameters:
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数，需落在 `1...100`。
    /// - Returns: 会话分页。
    /// - Throws: 条数越界时抛出 ``V2ClientDeviceSessionError/invalidRequest``；
    ///   响应不是 JSON 或字段非法时抛出
    ///   ``V2ClientDeviceSessionError/invalidResponse``；其余失败按状态码映射。
    public func list(cursor: String?, pageSize: Int) async throws -> V2ClientDeviceSessionPage {
        guard (1 ... 100).contains(pageSize) else { throw V2ClientDeviceSessionError.invalidRequest }
        var queryItems = [URLQueryItem(name: "page_size", value: String(pageSize))]
        if let cursor { queryItems.append(.init(name: "cursor", value: cursor)) }
        let request = try await authenticatedRequest(path: [], method: "GET", queryItems: queryItems)
        let (data, response) = try await send(request)
        guard response.statusCode == 200,
              V2HTTPContract.isJSON(response)
        else {
            if response.statusCode == 200 { throw V2ClientDeviceSessionError.invalidResponse }
            throw try failure(for: response)
        }
        do {
            let body = try JSONDecoder().decode(SessionPageBody.self, from: data)
            let sessions: [V2ClientDeviceSession] = try body.sessions.map {
                try V2ClientDeviceSession(
                    deviceID: .init($0.deviceID),
                    deviceName: $0.deviceName,
                    platform: $0.platform,
                    createdAt: Date(timeIntervalSince1970: Double($0.createdAtMilliseconds) / 1_000),
                    lastActiveAt: Date(timeIntervalSince1970: Double($0.lastActiveAtMilliseconds) / 1_000),
                    isCurrentDevice: $0.isCurrentDevice
                )
            }
            return .init(sessions: sessions, nextCursor: body.nextCursor)
        } catch { throw V2ClientDeviceSessionError.invalidResponse }
    }

    /// 构造带 Bearer 令牌与设备标识的请求。
    ///
    /// 访问令牌需非空且不含控制字符；请求显式禁用缓存并设置 15 秒超时。
    ///
    /// - Parameters:
    ///   - path: 追加在端点之后的路径段。
    ///   - method: HTTP 方法。
    ///   - queryItems: 查询参数。
    /// - Returns: 可发送请求。
    /// - Throws: 任务取消时抛出 `CancellationError`；取不到凭据或令牌非法时抛出
    ///   ``V2ClientDeviceSessionError/authorizationUnavailable``；
    ///   端点或路径无法构造出合法地址时抛出对应错误。
    private func authenticatedRequest(path: [String], method: String, queryItems: [URLQueryItem] = []) async throws -> URLRequest {
        let current: V2ClientDeviceSessionCredentials
        do { current = try await credentials.deviceSessionCredentials() }
        catch is CancellationError { throw CancellationError() } catch let failure as V2HTTPFailure { throw failure } catch let auth as V2AuthSessionError { throw auth } catch { throw V2ClientDeviceSessionError.authorizationUnavailable }
        guard !current.accessToken.isEmpty,
              !current.accessToken.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2ClientDeviceSessionError.authorizationUnavailable }
        let pathTarget = path.reduce(endpoint) { $0.appendingPathComponent($1) }
        guard var components = URLComponents(url: pathTarget, resolvingAgainstBaseURL: false) else {
            throw V2ClientDeviceSessionError.invalidEndpoint
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let target = components.url else { throw V2ClientDeviceSessionError.invalidRequest }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(current.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        V2HTTPRequestDeadline.attach(current.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    /// 发送请求并把传输层错误映射为领域错误。
    ///
    /// - Parameter request: 待发送请求。
    /// - Returns: 响应体与 HTTP 响应。
    /// - Throws: 任务取消时抛出 `CancellationError`；已属于本领域错误时原样抛出；
    ///   其余失败抛出 ``V2ClientDeviceSessionError/networkFailure``。
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as V2ClientDeviceSessionError { throw error }
        catch let failure as V2HTTPFailure { throw failure }
        catch let auth as V2AuthSessionError { throw auth }
        catch { throw V2ClientDeviceSessionError.networkFailure }
    }

    /// 按状态码映射领域错误。
    ///
    /// - Parameter response: HTTP 响应。
    /// - Returns: 对应的领域错误。
    private func failure(for response: HTTPURLResponse) throws -> V2ClientDeviceSessionError {
        switch response.statusCode {
        case 400: return .invalidRequest
        case 401: return V2ClientDeviceSessionError.authorizationUnavailable
        case 403: return .authorizationDenied
        case 404: return .sessionUnavailable
        case 429, 503: throw V2HTTPFailure.status(response, service: "deviceSessions")
        default: return .serverStatus(response.statusCode)
        }
    }
}

/// 设备会话客户端错误。
public enum V2ClientDeviceSessionError: Error, Equatable, Sendable {
    /// 端点不是合法的 HTTPS 地址。
    case invalidEndpoint
    /// 请求参数不满足约束。
    case invalidRequest
    /// 取不到可用凭据或令牌非法。
    case authorizationUnavailable
    /// 服务端拒绝授权。
    case authorizationDenied
    /// 目标会话不存在或已不可用。
    case sessionUnavailable
    /// 响应结构不合法。
    case invalidResponse
    /// 服务端返回非预期状态码。
    case serverStatus(Int)
    case networkFailure
}

private struct SessionBody: Decodable {
    let deviceID: String; let deviceName: String; let platform: String
    let createdAtMilliseconds: Int64; let lastActiveAtMilliseconds: Int64; let isCurrentDevice: Bool
}
private struct SessionPageBody: Decodable { let sessions: [SessionBody]; let nextCursor: String? }
