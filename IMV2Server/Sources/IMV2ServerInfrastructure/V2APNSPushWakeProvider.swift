import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import Foundation
import IMV2Core
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 窄传输边界，使 APNs 适配器无需真实提供方即可被测。
///
/// 请求体是通用唤醒载荷，绝不能被写入日志。
public struct V2PushHTTPRequest: Sendable {
    /// 请求地址。
    public let url: URL
    /// 请求头。
    public let headers: [String: String]
    /// 请求体。
    public let body: Data

    /// 保存请求。
    ///
    /// - Parameters:
    ///   - url: 请求地址。
    ///   - headers: 请求头。
    ///   - body: 请求体。
    public init(url: URL, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// 推送 HTTP 响应。
public struct V2PushHTTPResponse: Sendable {
    /// HTTP 状态码。
    public let statusCode: Int
    /// 响应体。
    public let body: Data

    /// 保存响应。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 响应体，默认空。
    public init(statusCode: Int, body: Data = Data()) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// 推送 HTTP 客户端能力。
public protocol V2PushHTTPClient: Sendable {
    /// 执行一次 HTTP 请求。
    ///
    /// - Parameter request: 待发送请求。
    /// - Returns: 提供方响应。
    /// - Throws: 网络失败或响应不可解析时抛出。
    func execute(_ request: V2PushHTTPRequest) async throws -> V2PushHTTPResponse
}

/// 基于 `URLSession` 的推送 HTTP 客户端。
public struct V2URLSessionPushHTTPClient: V2PushHTTPClient {
    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// 构造客户端。
    ///
    /// - Parameters:
    ///   - session: 使用的会话，默认共享会话。
    ///   - requestTimeout: 单次请求超时秒数，需为正的有限值且不超过 60，默认 10 秒。
    ///
    /// 超时越界时直接失败，避免出现无界等待或非法配置。
    public init(session: URLSession = .shared, requestTimeout: TimeInterval = 10) {
        precondition(requestTimeout.isFinite && requestTimeout > 0 && requestTimeout <= 60)
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// 以 POST 方式执行请求。
    ///
    /// - Parameter request: 待发送请求。
    /// - Returns: 提供方响应。
    /// - Throws: 网络失败时抛出；响应不是 HTTP 响应时抛出
    ///   ``V2APNSPushProviderError/invalidResponse``。
    public func execute(_ request: V2PushHTTPRequest) async throws -> V2PushHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = requestTimeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (body, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw V2APNSPushProviderError.invalidResponse }
        return .init(statusCode: http.statusCode, body: body)
    }
}

/// 推送授权值生成能力。
public protocol V2APNSAuthorizer: Sendable {
    /// 生成当前时刻使用的授权头取值。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 完整的授权头取值。
    /// - Throws: 配置或时钟不可用时抛出。
    func authorizationValue(now: Date) throws -> String
}

/// 面向 APNs 的 ES256 令牌授权器。
///
/// 私钥由密钥管理系统以 32 字节 P-256 原始私钥的 Base64 形式提供；
/// 本进程既不持久化也不记录它。
public struct V2APNSJWTAuthorizer: V2APNSAuthorizer {
    private let teamID: String
    private let keyID: String
    private let privateKeyRaw: Data

    /// 校验并以密钥材料构造授权器。
    ///
    /// - Parameters:
    ///   - teamID: 团队标识，去除首尾空白后需非空。
    ///   - keyID: 密钥标识，去除首尾空白后需非空。
    ///   - privateKeyRawBase64: Base64 编码的 32 字节 P-256 私钥。
    /// - Throws: 任一字段为空、密钥无法解码或长度不为 32 字节时抛出
    ///   ``V2APNSPushProviderError/invalidConfiguration``。
    public init(teamID: String, keyID: String, privateKeyRawBase64: String) throws {
        let normalizedTeamID = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKeyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTeamID.isEmpty, !normalizedKeyID.isEmpty,
              let privateKeyRaw = Data(base64Encoded: privateKeyRawBase64),
              privateKeyRaw.count == 32
        else { throw V2APNSPushProviderError.invalidConfiguration }
        self.teamID = normalizedTeamID
        self.keyID = normalizedKeyID
        self.privateKeyRaw = privateKeyRaw
    }

    /// 生成 APNs 授权头取值。
    ///
    /// 载荷为固定算法与密钥标识的头部加上团队与签发时刻的声明，
    /// 签发时刻必须非负且可写入 `Int64`。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 形如 `bearer <头部>.<声明>.<签名>` 的取值。
    /// - Throws: 时刻不可表示时抛出 ``V2APNSPushProviderError/invalidConfiguration``；
    ///   JSON 序列化或签名失败时抛出对应错误。
    public func authorizationValue(now: Date) throws -> String {
        let header = try jsonBase64URL(["alg": "ES256", "kid": keyID])
        let issuedAt = now.timeIntervalSince1970
        guard issuedAt >= 0, let signedIssuedAt = Int64(exactly: issuedAt.rounded(.towardZero)) else {
            throw V2APNSPushProviderError.invalidConfiguration
        }
        let claims = try jsonBase64URL(["iss": teamID, "iat": signedIssuedAt])
        let signingInput = "\(header).\(claims)"
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "bearer \(signingInput).\(base64URL(signature.rawRepresentation))"
    }
}

/// APNs 推送提供方错误。
public enum V2APNSPushProviderError: Error, Equatable, Sendable {
    /// 提供方配置非法。
    case invalidConfiguration
    /// 响应不可解析或不是 HTTP 响应。
    case invalidResponse
    /// 提供方返回可重试的失败状态。
    case providerRejected
}

/// 只发送 APNs 后台唤醒的提供方实现。
///
/// 载荷刻意不包含提醒文案、标题、房间、消息、发送者、附件、令牌或同步数据。
/// APNs 判定设备令牌终态失效时，只会停用当前观察到的端点代次并终态抑制这一条通用唤醒。
public struct V2APNSPushWakeProvider: V2PushWakeProvider {
    private let endpointStore: any V2PushDeviceEndpointStore
    private let httpClient: any V2PushHTTPClient
    private let authorizer: any V2APNSAuthorizer
    private let topic: String
    private let now: @Sendable () -> Date

    /// 组合端点存储、HTTP 客户端、授权器与主题。
    ///
    /// - Parameters:
    ///   - endpointStore: 推送端点存储。
    ///   - httpClient: 执行 HTTP 请求的客户端。
    ///   - authorizer: 生成授权头的实现。
    ///   - topic: APNs 主题，去除首尾空白后需非空且不超过 255 字节。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 主题为空或超长时抛出
    ///   ``V2APNSPushProviderError/invalidConfiguration``。
    public init(
        endpointStore: any V2PushDeviceEndpointStore,
        httpClient: any V2PushHTTPClient,
        authorizer: any V2APNSAuthorizer,
        topic: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let normalizedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTopic.isEmpty, normalizedTopic.utf8.count <= 255 else {
            throw V2APNSPushProviderError.invalidConfiguration
        }
        self.endpointStore = endpointStore
        self.httpClient = httpClient
        self.authorizer = authorizer
        self.topic = normalizedTopic
        self.now = now
    }

    /// 发送一次通用后台唤醒。
    ///
    /// 端点缺失时直接判定抑制；端点不属于 APNs、令牌格式非法或环境无法构造地址时，
    /// 停用该端点并判定拒绝。请求固定为后台类型、低优先级、仅含内容可用标记的载荷。
    /// 终态令牌错误同样停用端点并判定拒绝，其余非 2xx 作为可重试失败抛出。
    ///
    /// - Parameter wake: 已准入的唤醒内容。
    /// - Returns: 提供方结果。
    /// - Throws: 提供方返回可重试失败时抛出
    ///   ``V2APNSPushProviderError/providerRejected``；其余错误来自端点存储或 HTTP 客户端。
    public func send(_ wake: V2GenericPushWake) async throws -> V2PushWakeProviderOutcome {
        guard let endpoint = try await endpointStore.endpoint(for: wake.deviceID) else {
            return .suppressed(.endpointUnavailable)
        }
        guard endpoint.provider == .apns, validAPNSToken(endpoint.token),
              let url = endpointURL(for: endpoint)
        else {
            try await endpointStore.disable(endpoint, now: now())
            return .suppressed(.endpointRejected)
        }
        let authorization = try authorizer.authorizationValue(now: now())
        let request = V2PushHTTPRequest(
            url: url,
            headers: [
                "authorization": authorization,
                "apns-topic": topic,
                "apns-push-type": "background",
                "apns-priority": "5",
                "content-type": "application/json",
            ],
            body: Data(#"{"aps":{"content-available":1}}"#.utf8)
        )
        let response = try await httpClient.execute(request)
        if (200...299).contains(response.statusCode) {
            return .sent
        }
        if isTerminalEndpointRejection(statusCode: response.statusCode, body: response.body) {
            try await endpointStore.disable(endpoint, now: now())
            return .suppressed(.endpointRejected)
        }
        throw V2APNSPushProviderError.providerRejected
    }

    /// 按端点环境构造 APNs 请求地址。
    ///
    /// - Parameter endpoint: 目标端点。
    /// - Returns: 对应环境的请求地址；无法构造时为 `nil`。
    private func endpointURL(for endpoint: V2PushDeviceEndpoint) -> URL? {
        let host: String
        switch endpoint.environment {
        case .development: host = "https://api.sandbox.push.apple.com"
        case .production: host = "https://api.push.apple.com"
        }
        return URL(string: "\(host)/3/device/\(endpoint.token)")
    }

    /// 校验 APNs 设备令牌格式。
    ///
    /// - Parameter token: 设备令牌。
    /// - Returns: 恰好 64 位十六进制字符时为 `true`。
    private func validAPNSToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }
    }

    /// 判断响应是否表示设备令牌终态失效。
    ///
    /// 仅当状态码为 400 或 410 且原因属于设备令牌相关错误时为 `true`。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 响应体。
    /// - Returns: 属于终态失效时为 `true`。
    private func isTerminalEndpointRejection(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 400 || statusCode == 410,
              let response = try? JSONDecoder().decode(APNSErrorBody.self, from: body)
        else { return false }
        return ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].contains(response.reason)
    }
}

private struct APNSErrorBody: Decodable {
    let reason: String
}

/// 用键序稳定的 JSON 序列化后编码为 URL 安全 Base64。
///
/// - Parameter object: 待序列化对象。
/// - Returns: 无填充的 URL 安全 Base64 字符串。
/// - Throws: 序列化失败时抛出。
private func jsonBase64URL(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return base64URL(data)
}

/// 编码为无填充的 URL 安全 Base64。
///
/// - Parameter data: 待编码数据。
/// - Returns: 把 `+`、`/` 替换为 `-`、`_` 并去掉 `=` 的字符串。
private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
