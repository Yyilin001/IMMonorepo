import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OSLog)
import OSLog
#endif
import IMV2Core

/// 将 HTTP 执行与认证请求、响应校验分离的传输边界。
///
/// 允许测试注入确定性响应；实现接触敏感请求体，应避免向日志或其他观察者暴露凭证。
public protocol V2AuthHTTPTransport: Sendable {
    /// 执行请求并返回原始响应体及 HTTP 响应；失败通过错误传播，不在协议层解释业务状态码。
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 使用注入 URLSession 执行认证 HTTP 请求的适配器，不在此解释业务状态码或解析响应体。
public actor V2URLSessionAuthHTTPTransport: V2AuthHTTPTransport {
    /// 执行请求的会话，默认使用账户服务共享的隔离会话。
    private let session: URLSession

    #if canImport(OSLog)
    /// 认证传输诊断日志，仅记录 URL 错误数字码，不记录 URL 或请求内容。
    private static let logger = Logger(subsystem: "com.stskcxfz.imapp", category: "v2.http-auth")
    #endif

    /// 注入 HTTP 会话；默认使用 V2SecureURLSession.account，自定义会话的配置由注入方负责。
    public init(session: URLSession = V2SecureURLSession.account) {
        self.session = session
    }

    /// 开始前检查取消，执行 URLSession 请求并要求响应为 HTTPURLResponse。
    ///
    /// - Parameter request: 调用方构造的完整 HTTP 请求。
    /// - Returns: 原始数据与 HTTP 响应，包含非成功状态码。
    /// - Throws: 取消、原始 URLSession 错误，或非 HTTP 响应对应的 invalidResponse。
    ///
    /// URL 错误只记录数字码后原样抛出；不记录端点、请求体或响应体。
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            #if canImport(OSLog)
            // URLSession's numeric code is enough to distinguish trust,
            // connection and timeout failures without logging a URL or payload.
            Self.logger.error("Auth HTTP transport failed with URL error code \(error.code.rawValue, privacy: .public)")
            #endif
            throw error
        }
        guard let response = response as? HTTPURLResponse else {
            throw V2HTTPAuthTransportError.invalidResponse
        }
        return (data, response)
    }
}

/// 设备凭证轮换的 HTTPS 适配器，使用会话已持久化的稳定操作身份。
///
/// 响应丢失后复用身份，使服务端能够重放已完成轮换。持久化与共享刷新由 V2AuthSession 负责，此适配器每次只发送一次请求。
public struct V2HTTPDeviceCredentialAuthTransport: V2AuthTransport, Sendable {
    /// 完整刷新地址，发送时不追加路径或查询参数。
    private let refreshEndpoint: URL
    /// 执行刷新 HTTP 请求的可注入传输。
    private let transport: any V2AuthHTTPTransport

    /// 保存刷新端点与传输，要求 scheme 为 HTTPS 且 host 非 nil。
    ///
    /// - Parameters:
    ///   - refreshEndpoint: 服务端完整刷新地址。
    ///   - transport: 默认使用账户服务的 URLSession 适配器。
    /// - Throws: 不符合上述端点条件时抛出 invalidEndpoint。
    ///
    /// 当前校验没有额外排除 URL 用户信息、查询或片段，调用方应提供预期的固定端点。
    public init(
        refreshEndpoint: URL,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()
    ) throws {
        guard refreshEndpoint.scheme?.lowercased() == "https", refreshEndpoint.host != nil else {
            throw V2HTTPAuthTransportError.invalidEndpoint
        }
        self.refreshEndpoint = refreshEndpoint
        self.transport = transport
    }

    /// 通过 JSON POST 请求轮换设备凭证，设置 15 秒超时及禁止缓存的请求策略。
    ///
    /// - Parameter request: 包含用户、设备、刷新及撤销凭证和稳定操作身份的完整请求。
    /// - Returns: 从服务端 JSON 构造的新凭证；两个期限均按 Unix 毫秒转换为 Date。
    /// - Throws: 请求编码、网络、状态或响应格式错误；401 与 403 映射为 terminalRejection，取消保持取消语义。
    ///
    /// 200 必须满足 JSON 内容类型判断。其他状态以 serverStatus 报告，不解析重试等待。
    /// 返回值与原请求的用户、设备及撤销身份一致性由会话层检查；此方法不判断新令牌是否已经到期。
    public func refresh(_ request: V2RefreshRequest) async throws -> V2AuthCredentials {
        try Task.checkCancellation()
        var urlRequest = URLRequest(
            url: refreshEndpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
        do {
            urlRequest.httpBody = try JSONEncoder().encode(V2DeviceCredentialRefreshHTTPBody(request: request))
        } catch {
            throw V2HTTPAuthTransportError.invalidRequest
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as V2HTTPAuthTransportError {
            throw error
        } catch {
            throw V2HTTPAuthTransportError.networkFailure
        }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2HTTPAuthTransportError.invalidResponse
        case 401, 403: throw V2AuthTransportError.terminalRejection
        default: throw V2HTTPAuthTransportError.serverStatus(response.statusCode)
        }

        do {
            let body = try JSONDecoder().decode(V2DeviceCredentialRefreshHTTPResponse.self, from: data)
            return try .init(
                userID: .init(body.userID),
                deviceID: .init(body.deviceID),
                accessToken: body.accessToken,
                accessTokenExpiresAt: Date(timeIntervalSince1970: Double(body.accessTokenExpiresAtMilliseconds) / 1_000),
                refreshCredential: body.refreshCredential,
                revocationCredential: body.revocationCredential,
                revocationCredentialExpiresAt: Date(timeIntervalSince1970: Double(body.revocationCredentialExpiresAtMilliseconds) / 1_000)
            )
        } catch let error as V2AuthSessionError {
            throw error
        } catch {
            throw V2HTTPAuthTransportError.invalidResponse
        }
    }
}

/// 认证 HTTP 适配器错误，与明确终止会话的认证拒绝分开处理。
public enum V2HTTPAuthTransportError: Error, Equatable, Sendable {
    /// 端点不满足该适配器要求的 HTTPS 与主机条件。
    case invalidEndpoint
    /// 请求体无法编码为约定格式。
    case invalidRequest
    /// 响应不是 HTTP、内容类型不符合约定，或响应体无法转换为所需模型。
    case invalidResponse
    /// 未单独映射的 HTTP 状态码；此错误本身不等同于认证失效。
    case serverStatus(Int)
    /// 其他传输失败的统一分类，不包含原始请求或凭证。
    case networkFailure
}

/// 刷新请求的 JSON 表示，保留服务端幂等轮换所需的全部身份。
private struct V2DeviceCredentialRefreshHTTPBody: Encodable {
    /// 用户标识原始字符串。
    let userID: String
    /// 设备标识原始字符串。
    let deviceID: String
    /// 用于本次轮换的敏感刷新凭证。
    let refreshCredential: String
    /// 与设备会话绑定的撤销凭证。
    let revocationCredential: V2DeviceRevocationCredential
    /// 已持久化并在重试间复用的操作 UUID。
    let operationID: UUID

    /// 从领域请求提取传输字段，不生成新的操作身份或改变凭证。
    init(request: V2RefreshRequest) {
        userID = request.userID.rawValue
        deviceID = request.deviceID.rawValue
        refreshCredential = request.refreshCredential
        revocationCredential = request.revocationCredential
        operationID = request.operationID
    }
}

/// 刷新成功响应的 JSON 表示，凭证期限使用 Int64 Unix 毫秒。
private struct V2DeviceCredentialRefreshHTTPResponse: Decodable {
    /// 响应声明的用户标识。
    let userID: String
    /// 响应声明的设备标识。
    let deviceID: String
    /// 轮换后的访问令牌。
    let accessToken: String
    /// 访问令牌期限，单位为 Unix 毫秒。
    let accessTokenExpiresAtMilliseconds: Int64
    /// 轮换后的刷新凭证。
    let refreshCredential: String
    /// 响应携带的设备撤销凭证，由会话层校验一致性。
    let revocationCredential: V2DeviceRevocationCredential
    /// 撤销凭证期限，单位为 Unix 毫秒。
    let revocationCredentialExpiresAtMilliseconds: Int64
}
