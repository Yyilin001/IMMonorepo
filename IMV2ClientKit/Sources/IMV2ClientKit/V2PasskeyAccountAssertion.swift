import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 一次性的通行密钥挑战。
///
/// 挑战由服务端创建，并把其不透明标识与账号认证流程关联起来；
/// 界面层无需解读原始挑战字节。
public struct V2PasskeyAssertionRequest: Equatable, Sendable {
    /// 服务端挑战标识。
    public let challengeID: String
    /// 原始挑战字节。
    public let challenge: Data
    /// 依赖方标识，需非空且不含 `/`。
    public let relyingPartyID: String
    /// 允许使用的凭据标识列表。
    public let allowedCredentialIDs: [Data]

    /// 校验并保存断言请求。
    ///
    /// - Parameters:
    ///   - challengeID: 挑战标识，需非空。
    ///   - challenge: 挑战字节，需非空。
    ///   - relyingPartyID: 依赖方标识，需非空且不含 `/`。
    ///   - allowedCredentialIDs: 允许的凭据标识列表。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2PasskeyAccountAssertionError/invalidRequest``。
    public init(challengeID: String, challenge: Data, relyingPartyID: String, allowedCredentialIDs: [Data]) throws {
        guard !challengeID.isEmpty, !challenge.isEmpty,
              !relyingPartyID.isEmpty, !relyingPartyID.contains("/")
        else { throw V2PasskeyAccountAssertionError.invalidRequest }
        self.challengeID = challengeID
        self.challenge = challenge
        self.relyingPartyID = relyingPartyID
        self.allowedCredentialIDs = allowedCredentialIDs
    }
}

/// 通行密钥断言结果。
public struct V2PasskeyAssertionResult: Equatable, Sendable {
    /// 凭据标识。
    public let credentialID: Data
    /// 客户端数据 JSON。
    public let clientDataJSON: Data
    /// 认证器数据。
    public let authenticatorData: Data
    /// 断言签名。
    public let signature: Data
    /// 用户句柄；可为空。
    public let userHandle: Data?

    /// 校验并保存断言结果。
    ///
    /// - Parameters:
    ///   - credentialID: 凭据标识，需非空。
    ///   - clientDataJSON: 客户端数据，需非空。
    ///   - authenticatorData: 认证器数据，需非空。
    ///   - signature: 签名，需非空。
    ///   - userHandle: 用户句柄。
    /// - Throws: 任一必需字段为空时抛出
    ///   ``V2PasskeyAccountAssertionError/invalidResult``。
    public init(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?) throws {
        guard !credentialID.isEmpty, !clientDataJSON.isEmpty, !authenticatorData.isEmpty, !signature.isEmpty else {
            throw V2PasskeyAccountAssertionError.invalidResult
        }
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
    }
}

/// 通行密钥账号断言错误。
public enum V2PasskeyAccountAssertionError: Error, Equatable, Sendable {
    /// 端点不是合法的 HTTPS 地址。
    case invalidEndpoint
    /// 请求参数不满足约束。
    case invalidRequest
    /// 断言结果不满足约束。
    case invalidResult
    /// 响应结构不合法。
    case invalidResponse
    /// 服务端拒绝该次认证。
    case authenticationRejected
    /// 认证能力当前不可用。
    case unavailable
    /// 网络请求失败。
    case networkFailure
    /// 服务端返回非预期状态码。
    case serverStatus(Int)
}

/// 断言请求获取能力。
public protocol V2PasskeyAssertionRequestProviding: Sendable {
    /// 获取一次断言请求。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识；为空表示使用设备已知账号。
    ///   - deviceID: 目标设备。
    /// - Returns: 服务端下发的断言请求。
    /// - Throws: 认证、网络或响应解析失败时抛出。
    func assertionRequest(accountHandle: String?, deviceID: DeviceID) async throws -> V2PasskeyAssertionRequest
}

/// 平台通行密钥授权能力。
public protocol V2PasskeyAuthorizing: Sendable {
    /// 请求系统完成一次断言。
    ///
    /// - Parameter request: 断言请求。
    /// - Returns: 断言结果。
    /// - Throws: 用户取消或平台认证失败时抛出。
    func authorize(_ request: V2PasskeyAssertionRequest) async throws -> V2PasskeyAssertionResult
}

/// 断言结果提交能力。
public protocol V2PasskeyAssertionSubmitting: Sendable {
    /// 提交断言结果并换取账号断言。
    ///
    /// - Parameters:
    ///   - result: 断言结果。
    ///   - request: 对应的断言请求。
    /// - Returns: 服务端签发的账号断言。
    /// - Throws: 认证被拒、网络或响应解析失败时抛出。
    func submit(_ result: V2PasskeyAssertionResult, for request: V2PasskeyAssertionRequest) async throws -> V2AccountAssertion
}

/// 首选账号认证因子适配器。
///
/// 每次设备凭据注册尝试都会获取一次全新的通行密钥断言，
/// 并刻意不保留 WebAuthn 响应与随后得到的账号断言。
public struct V2PasskeyAccountAssertionProvider: V2DeviceBoundAccountAssertionProvider, Sendable {
    private let accountHandle: String?
    private let requestProvider: any V2PasskeyAssertionRequestProviding
    private let authorizer: any V2PasskeyAuthorizing
    private let submitter: any V2PasskeyAssertionSubmitting

    /// 组合账号标识与三个协作实现。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识。
    ///   - requestProvider: 断言请求获取实现。
    ///   - authorizer: 平台授权实现。
    ///   - submitter: 结果提交实现。
    public init(
        accountHandle: String? = nil,
        requestProvider: any V2PasskeyAssertionRequestProviding,
        authorizer: any V2PasskeyAuthorizing,
        submitter: any V2PasskeyAssertionSubmitting
    ) {
        self.accountHandle = accountHandle
        self.requestProvider = requestProvider
        self.authorizer = authorizer
        self.submitter = submitter
    }

    /// 为指定设备获取一次账号断言。
    ///
    /// 流程为：获取挑战、请求平台断言、提交结果并返回服务端签发的断言值。
    ///
    /// - Parameter deviceID: 目标设备。
    /// - Returns: 账号断言值。
    /// - Throws: 三个协作实现抛出的错误。
    public func accountAssertion(for deviceID: DeviceID) async throws -> String {
        let request = try await requestProvider.assertionRequest(accountHandle: accountHandle, deviceID: deviceID)
        let result = try await authorizer.authorize(request)
        let assertion = try await submitter.submit(result, for: request)
        return assertion.value
    }
}

/// WebAuthn 断言流程的 HTTP 部分。
///
/// 挑战生命周期、依赖方标识校验、签名验证、计数器与短时 V2 账号断言的签发
/// 全部由服务端独占负责。
public struct V2HTTPPasskeyAssertionService: V2PasskeyAssertionRequestProviding, V2PasskeyAssertionSubmitting, Sendable {
    private let optionsEndpoint: URL
    private let completionEndpoint: URL
    private let transport: any V2AuthHTTPTransport

    /// 校验并保存两个端点与传输实现。
    ///
    /// - Parameters:
    ///   - optionsEndpoint: 获取断言挑战的端点，需为带主机名的 HTTPS 地址。
    ///   - completionEndpoint: 提交断言结果的端点，需为带主机名的 HTTPS 地址。
    ///   - transport: HTTP 传输实现。
    /// - Throws: 任一端点不是合法 HTTPS 地址时抛出
    ///   ``V2PasskeyAccountAssertionError/invalidEndpoint``。
    public init(
        optionsEndpoint: URL,
        completionEndpoint: URL,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()
    ) throws {
        guard Self.isHTTPS(optionsEndpoint), Self.isHTTPS(completionEndpoint) else {
            throw V2PasskeyAccountAssertionError.invalidEndpoint
        }
        self.optionsEndpoint = optionsEndpoint
        self.completionEndpoint = completionEndpoint
        self.transport = transport
    }

    /// 获取一次断言挑战。
    ///
    /// 响应必须给出可解码的挑战、依赖方标识与凭据列表，任一字段无法解码都视为响应不合法。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识。
    ///   - deviceID: 目标设备。
    /// - Returns: 断言请求。
    /// - Throws: 响应不合法时抛出
    ///   ``V2PasskeyAccountAssertionError/invalidResponse``；其余失败同请求执行路径。
    public func assertionRequest(accountHandle: String?, deviceID: DeviceID) async throws -> V2PasskeyAssertionRequest {
        var request = try request(url: optionsEndpoint, body: PasskeyOptionsRequest(accountHandle: accountHandle, deviceID: deviceID.rawValue))
        request.httpMethod = "POST"
        let data = try await execute(request)
        guard let body = try? JSONDecoder().decode(PasskeyOptionsResponse.self, from: data),
              let challenge = Self.decodeBase64URL(body.challenge),
              let allowed = body.allowedCredentialIDs.map({ values in values.compactMap(Self.decodeBase64URL) }),
              allowed.count == body.allowedCredentialIDs?.count
        else { throw V2PasskeyAccountAssertionError.invalidResponse }
        return try .init(challengeID: body.challengeID, challenge: challenge, relyingPartyID: body.relyingPartyID, allowedCredentialIDs: allowed)
    }

    /// 提交断言结果并解析服务端签发的账号断言。
    ///
    /// - Parameters:
    ///   - result: 断言结果，各字段以 URL 安全 Base64 编码传输。
    ///   - request: 对应的断言请求。
    /// - Returns: 账号断言。
    /// - Throws: 响应不合法时抛出
    ///   ``V2PasskeyAccountAssertionError/invalidResponse``；其余失败同请求执行路径。
    public func submit(_ result: V2PasskeyAssertionResult, for request: V2PasskeyAssertionRequest) async throws -> V2AccountAssertion {
        var httpRequest = try self.request(
            url: completionEndpoint,
            body: PasskeyCompletionRequest(
                challengeID: request.challengeID,
                credentialID: Self.base64URL(result.credentialID),
                clientDataJSON: Self.base64URL(result.clientDataJSON),
                authenticatorData: Self.base64URL(result.authenticatorData),
                signature: Self.base64URL(result.signature),
                userHandle: result.userHandle.map(Self.base64URL)
            )
        )
        httpRequest.httpMethod = "POST"
        let data = try await execute(httpRequest)
        guard let body = try? JSONDecoder().decode(PasskeyCompletionResponse.self, from: data) else {
            throw V2PasskeyAccountAssertionError.invalidResponse
        }
        return try V2AccountAssertion(body.accountAssertion)
    }

    /// 构造禁用缓存的 JSON 请求。
    ///
    /// - Parameters:
    ///   - url: 目标地址。
    ///   - body: 请求体。
    /// - Returns: 可发送请求。
    /// - Throws: 请求体编码失败时抛出。
    private func request<Body: Encodable>(url: URL, body: Body) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// 执行请求并按状态码映射错误。
    ///
    /// - Parameter request: 待发送请求。
    /// - Returns: 响应体。
    /// - Throws: 网络失败抛出 ``V2PasskeyAccountAssertionError/networkFailure``；
    ///   非 JSON 的 200 抛出 ``V2PasskeyAccountAssertionError/invalidResponse``；
    ///   401 与 403 抛出 ``V2PasskeyAccountAssertionError/authenticationRejected``；
    ///   其余状态码抛出 ``V2PasskeyAccountAssertionError/serverStatus(_:)``。
    private func execute(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as V2HTTPFailure { throw failure }
        catch let error as V2AuthSessionError { throw error }
        catch {
            throw V2PasskeyAccountAssertionError.networkFailure
        }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): return data
        case 200: throw V2PasskeyAccountAssertionError.invalidResponse
        case 401, 403: throw V2PasskeyAccountAssertionError.authenticationRejected
        default: throw V2PasskeyAccountAssertionError.serverStatus(response.statusCode)
        }
    }

    private static func isHTTPS(_ endpoint: URL) -> Bool {
        endpoint.scheme?.lowercased() == "https" && endpoint.host != nil
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private struct PasskeyOptionsRequest: Encodable { let accountHandle: String?; let deviceID: String }
private struct PasskeyOptionsResponse: Decodable {
    let challengeID: String
    let challenge: String
    let relyingPartyID: String
    let allowedCredentialIDs: [String]?
}
private struct PasskeyCompletionRequest: Encodable {
    let challengeID: String
    let credentialID: String
    let clientDataJSON: String
    let authenticatorData: String
    let signature: String
    let userHandle: String?
}
private struct PasskeyCompletionResponse: Decodable { let accountAssertion: String }
