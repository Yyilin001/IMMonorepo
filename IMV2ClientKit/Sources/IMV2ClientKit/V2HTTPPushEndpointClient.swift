import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 与账号边缘一致的窄提供方集合。
///
/// 它刻意不是开放字符串，避免应用升级后自行启用未经评审的提供方。
public enum V2ClientPushEndpointProvider: String, Codable, Equatable, Sendable {
    /// Apple 推送通知服务。
    case apns
}

/// APNs 运行环境。
///
/// 它属于部署选择，而不是用户可控的标签。
public enum V2ClientPushEndpointEnvironment: String, Codable, Equatable, Sendable {
    /// 沙盒环境。
    case development
    /// 生产环境。
    case production
}

/// 仅在已认证账号边缘使用的一组配套访问令牌与设备标识。
///
/// Bearer 令牌与不透明推送令牌都绝不能持久化、写入日志、附加到分析数据，
/// 也不能作为返回值的一部分。
public struct V2ClientPushEndpointCredentials: Sendable {
    /// 访问令牌。
    public let accessToken: String
    /// 当前设备标识。
    public let deviceID: DeviceID
    /// Local monotonic request budget; never encoded or persisted with credentials.
    public let requestDeadline: ContinuousClock.Instant?

    /// 保存边缘凭据。
    ///
    /// - Parameters:
    ///   - accessToken: 访问令牌。
    ///   - deviceID: 当前设备标识。
    public init(accessToken: String, deviceID: DeviceID, requestDeadline: ContinuousClock.Instant? = nil) {
        self.accessToken = accessToken
        self.deviceID = deviceID; self.requestDeadline = requestDeadline
    }
}

/// 推送端点凭据提供能力。
public protocol V2ClientPushEndpointCredentialProvider: Sendable {
    /// 获取一次边缘凭据。
    ///
    /// - Returns: 访问令牌与设备标识。
    /// - Throws: 凭据不可用时抛出。
    func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials
}

/// 推送端点 HTTP 传输能力。
///
/// 把 URLSession 隔离在此边界之后，使端点注册测试可以离线进行，
/// 无需注册进程级 URLProtocol。
public protocol V2ClientPushEndpointHTTPTransport: Sendable {
    /// 执行一次 HTTP 请求。
    ///
    /// - Parameter request: 待发送请求。
    /// - Returns: 响应体与 HTTP 响应。
    /// - Throws: 网络失败或响应不可解析时抛出。
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 基于 URLSession 的推送端点传输实现。
public actor V2URLSessionPushEndpointHTTPTransport: V2ClientPushEndpointHTTPTransport {
    private let executor: V2HTTPExecutor
    public init(session: URLSession = V2SecureURLSession.account) { executor = .init(session: session) }
    public init(executor: V2HTTPExecutor) { self.executor = executor }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await executor.execute(request, budget: .init(timeout: 15, maximumResponseBytes: 1_024), service: "pushEndpoints")
    }

}

/// 设备自有端点的框架无关账号边缘契约。
///
/// 注册与删除刻意都是不自动重试的写操作：调用方必须先取得当前由系统提供的令牌，
/// 并在失败后自行明确决定何时重试。
public protocol V2ClientPushEndpointRegistering: Sendable {
    /// 注册或更新设备的推送端点。
    ///
    /// - Parameters:
    ///   - provider: 推送提供方。
    ///   - environment: 运行环境。
    ///   - token: 系统提供的推送令牌。
    /// - Throws: 认证、网络或服务端拒绝时抛出。
    func register(
        provider: V2ClientPushEndpointProvider,
        environment: V2ClientPushEndpointEnvironment,
        token: String
    ) async throws
    /// 删除当前设备的推送端点。
    ///
    /// - Throws: 认证、网络或服务端拒绝时抛出。
    func remove() async throws
}

/// 推送意图发布能力。
///
/// 调用方把每次操作都绑定到持久化意图所在的设备。代次声明重试时沿用同一请求标识与
/// 期望代次；陈旧状态绝不会自动重新认领。
public protocol V2ClientPushIntentPublishing: Sendable {
    /// 读取设备当前的推送意图代次。
    ///
    /// - Parameter deviceID: 目标设备。
    /// - Returns: 当前代次。
    /// - Throws: 认证、网络或响应解析失败时抛出。
    func intentEpoch(deviceID: DeviceID) async throws -> UInt64

    /// 认领会话并取得其代次。
    ///
    /// - Parameters:
    ///   - deviceID: 目标设备。
    ///   - claim: 会话声明。
    /// - Returns: 认领到的会话代次。
    /// - Throws: 代次不一致、认证或网络失败时抛出。
    func claimIntentSession(deviceID: DeviceID, claim: V2PushIntentSessionClaim) async throws -> UInt64

    /// 发布一次推送意图。
    ///
    /// - Parameters:
    ///   - deviceID: 目标设备。
    ///   - version: 期望的意图版本。
    ///   - intent: 目标意图内容。
    /// - Throws: 版本冲突、认证或网络失败时抛出。
    func publishIntent(deviceID: DeviceID, version: V2PushIntentVersion, intent: V2ClientPushIntent) async throws
}

/// 客户端推送意图。
public enum V2ClientPushIntent: Sendable {
    /// 关闭推送。
    case disabled
    /// 开启推送，并携带提供方、环境与令牌。
    case enabled(provider: V2ClientPushEndpointProvider, environment: V2ClientPushEndpointEnvironment, token: String)
}

/// 已认证 `PUT|DELETE /v2/push-endpoint` 契约的 HTTPS 实现。
///
/// 它不提供读取接口：端点令牌不是应用状态，也绝不能重新进入客户端持久化。
public struct V2HTTPPushEndpointClient: V2ClientPushEndpointRegistering, V2ClientPushIntentPublishing, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientPushEndpointHTTPTransport

    /// 校验并保存端点、凭据提供方与传输实现。
    ///
    /// - Parameters:
    ///   - endpoint: 推送端点，必须是带主机名的 HTTPS 地址。
    ///   - credentials: 提供访问令牌与设备标识的凭据来源。
    ///   - transport: HTTP 传输实现，默认使用系统 URL 会话。
    /// - Throws: 端点不是合法 HTTPS 地址时抛出
    ///   ``V2ClientPushEndpointError/invalidEndpoint``。
    public init(
        endpoint: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw V2ClientPushEndpointError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    /// 注册或更新设备的推送端点。
    ///
    /// - Parameters:
    ///   - provider: 推送提供方。
    ///   - environment: 运行环境。
    ///   - token: 系统提供的推送令牌。
    /// - Throws: 令牌非法时抛出
    ///   ``V2ClientPushEndpointError/invalidRegistration``；
    ///   认证、网络或服务端拒绝时抛出对应错误。
    public func register(
        provider: V2ClientPushEndpointProvider,
        environment: V2ClientPushEndpointEnvironment,
        token: String
    ) async throws {
        guard Self.isValidOpaqueToken(token) else {
            throw V2ClientPushEndpointError.invalidRegistration
        }
        var request = try await authenticatedRequest(method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(
                V2PushEndpointRegistrationBody(provider: provider, environment: environment, token: token)
            )
        } catch {
            throw V2ClientPushEndpointError.invalidRegistration
        }
        try await sendNoContent(request)
    }

    /// 删除当前设备的推送端点。
    ///
    /// - Throws: 认证、网络或服务端拒绝时抛出。
    public func remove() async throws {
        try await sendNoContent(try await authenticatedRequest(method: "DELETE"))
    }

    /// 构造带 Bearer 令牌与设备标识的请求。
    ///
    /// - Parameters:
    ///   - method: HTTP 方法。
    ///   - path: 可选的路径片段。
    ///   - deviceID: 可选的显式设备标识，用于意图发布路径。
    /// - Returns: 可发送请求。
    /// - Throws: 取不到凭据或地址无法构造时抛出对应错误。
    private func authenticatedRequest(method: String, path: String? = nil, deviceID: DeviceID? = nil) async throws -> URLRequest {
        try Task.checkCancellation()
        let edgeCredentials: V2ClientPushEndpointCredentials
        do {
            edgeCredentials = try await credentials.pushEndpointCredentials()
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as V2HTTPFailure { throw failure } catch let auth as V2AuthSessionError { throw auth } catch {
            throw V2ClientPushEndpointError.authorizationUnavailable
        }
        try Task.checkCancellation()
        if let deviceID {
            guard let expected = deviceID.uuidValue, let actual = edgeCredentials.deviceID.uuidValue, expected == actual else {
                throw V2ClientPushEndpointError.authorizationUnavailable
            }
        }
        guard !edgeCredentials.accessToken.isEmpty,
              !edgeCredentials.accessToken.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2ClientPushEndpointError.authorizationUnavailable }

        var request = URLRequest(
            url: path.map { endpoint.appendingPathComponent($0) } ?? endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = method
        request.setValue("Bearer \(edgeCredentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(edgeCredentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        V2HTTPRequestDeadline.attach(edgeCredentials.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    /// 读取设备当前的推送意图代次。
    ///
    /// - Parameter deviceID: 目标设备。
    /// - Returns: 当前代次。
    /// - Throws: 认证、网络或响应解析失败时抛出。
    public func intentEpoch(deviceID: DeviceID) async throws -> UInt64 {
        let request = try await authenticatedRequest(method: "GET", path: "session", deviceID: deviceID)
        return try await sendEpoch(request)
    }

    /// 认领会话并取得其代次。
    ///
    /// - Parameters:
    ///   - deviceID: 目标设备。
    ///   - claim: 会话声明。
    /// - Returns: 认领到的会话代次。
    /// - Throws: 代次不一致、认证或网络失败时抛出。
    public func claimIntentSession(deviceID: DeviceID, claim: V2PushIntentSessionClaim) async throws -> UInt64 {
        struct Body: Encodable { let requestID: UUID; let expectedEpoch: UInt64 }
        var request = try await authenticatedRequest(method: "POST", path: "session", deviceID: deviceID)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(requestID: claim.requestID, expectedEpoch: claim.expectedEpoch))
        let epoch = try await sendEpoch(request)
        guard epoch == claim.expectedEpoch + 1 else { throw V2ClientPushEndpointError.invalidResponse }
        return epoch
    }

    /// 发布一次推送意图。
    ///
    /// - Parameters:
    ///   - deviceID: 目标设备。
    ///   - version: 期望的意图版本。
    ///   - intent: 目标意图内容。
    /// - Throws: 版本冲突、认证或网络失败时抛出。
    public func publishIntent(deviceID: DeviceID, version: V2PushIntentVersion, intent: V2ClientPushIntent) async throws {
        struct Body: Encodable {
            let epoch: UInt64; let revision: UInt64; let enabled: Bool
            let provider: V2ClientPushEndpointProvider?; let environment: V2ClientPushEndpointEnvironment?; let token: String?
        }
        let body: Body
        switch intent {
        case .disabled:
            body = .init(epoch: version.epoch, revision: version.revision, enabled: false, provider: nil, environment: nil, token: nil)
        case .enabled(let provider, let environment, let token):
            guard Self.isValidOpaqueToken(token) else { throw V2ClientPushEndpointError.invalidRegistration }
            body = .init(epoch: version.epoch, revision: version.revision, enabled: true, provider: provider, environment: environment, token: token)
        }
        var request = try await authenticatedRequest(method: "PUT", path: "intent", deviceID: deviceID)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        try await sendNoContent(request)
    }

    /// 发送请求并解析代次响应。
    ///
    /// - Parameter request: 待发送请求。
    /// - Returns: 响应中的代次。
    /// - Throws: 响应不合法或状态码非预期时抛出。
    private func sendEpoch(_ request: URLRequest) async throws -> UInt64 {
        struct Body: Decodable { let epoch: UInt64 }
        let (data, response) = try await send(request)
        try checkStatus(response, expected: 200, data: data)
        guard data.count <= 1_024, let body = try? JSONDecoder().decode(Body.self, from: data), body.epoch <= UInt64(Int64.max) else {
            throw V2ClientPushEndpointError.invalidResponse
        }
        return body.epoch
    }

    /// 发送请求并要求 204 空响应。
    ///
    /// - Parameter request: 待发送请求。
    /// - Throws: 状态码非 204 时抛出对应错误。
    private func sendNoContent(_ request: URLRequest) async throws {
        let (data, response) = try await send(request)
        try checkStatus(response, expected: 204, data: data)
    }

    /// 发送请求并返回响应体与 HTTP 响应。
    ///
    /// - Parameter request: 待发送请求。
    /// - Returns: 响应体与 HTTP 响应。
    /// - Throws: 任务取消时抛出 `CancellationError`；网络失败时抛出
    ///   ``V2ClientPushEndpointError/networkFailure``。
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do { return try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as V2ClientPushEndpointError { throw error }
        catch let failure as V2HTTPFailure { throw failure }
        catch let auth as V2AuthSessionError { throw auth }
        catch { throw V2ClientPushEndpointError.networkFailure }
    }

    private func checkStatus(_ response: HTTPURLResponse, expected: Int, data: Data) throws {
        let status = response.statusCode
        if status == expected { return }
        switch status {
        case 400: throw V2ClientPushEndpointError.invalidRegistration
        case 401: throw V2ClientPushEndpointError.authorizationUnavailable
        case 403: throw V2ClientPushEndpointError.authorizationDenied
        case 429:
            let seconds = V2RetryAfter.date(from: response.value(forHTTPHeaderField: "Retry-After")).map { ceil(max(0, $0.timeIntervalSinceNow)) } ?? 60
            throw V2ClientPushEndpointError.rateLimited(retryAfter: seconds)
        case 503: throw V2HTTPFailure.status(response, service: "pushEndpoints")
        case 428: throw V2ClientPushEndpointError.intentVersionRequired
        case 409:
            struct Failure: Decodable { let code: String }
            guard data.count <= 1_024, let failure = try? JSONDecoder().decode(Failure.self, from: data) else { throw V2ClientPushEndpointError.invalidResponse }
            switch failure.code {
            case "stale_intent": throw V2ClientPushEndpointError.staleIntent
            case "intent_conflict": throw V2ClientPushEndpointError.intentConflict
            default: throw V2ClientPushEndpointError.invalidResponse
            }
        default: throw V2ClientPushEndpointError.serverStatus(status)
        }
    }

    private static func isValidOpaqueToken(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized == token && normalized.utf8.count <= 4_096
            && normalized.unicodeScalars.allSatisfy {
                !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
            }
    }
}

/// 推送端点客户端错误。
public enum V2ClientPushEndpointError: Error, Equatable, Sendable {
    /// 端点不是合法的 HTTPS 地址。
    case invalidEndpoint
    /// 端点注册参数不合法。
    case invalidRegistration
    /// 取不到可用凭据。
    case authorizationUnavailable
    /// 服务端拒绝授权。
    case authorizationDenied
    /// 响应结构不合法。
    case invalidResponse
    /// 服务端限流，并给出建议等待秒数。
    case rateLimited(retryAfter: TimeInterval)
    /// 服务端要求先声明意图版本。
    case intentVersionRequired
    /// 意图版本已过期。
    case staleIntent
    /// 意图与当前状态冲突。
    case intentConflict
    /// 服务端返回非预期状态码。
    case serverStatus(Int)
    case networkFailure
}

private struct V2PushEndpointRegistrationBody: Encodable {
    let provider: V2ClientPushEndpointProvider
    let environment: V2ClientPushEndpointEnvironment
    let token: String
}
