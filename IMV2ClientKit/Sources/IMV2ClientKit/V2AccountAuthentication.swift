import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 账户因子验证后取得的一次性断言，直接交给设备凭证签发流程。
///
/// 不得写入 Keychain、数据库或诊断信息；此值类型仅校验字符串形式，不验证签发者、有效期或是否已使用。
public struct V2AccountAssertion: Equatable, Sendable {
    /// 未经裁剪的敏感断言原始值。
    public let value: String

    /// 构造非空且不含 ASCII 控制字符的账户断言。
    ///
    /// - Parameter value: 保留原样的服务端断言字符串。
    /// - Throws: 去除首尾空白后为空，或包含小于 U+0020 的字符及 U+007F 时抛出 invalidAssertion。
    ///
    /// 只用裁剪结果判断是否为空，不改变保存的原始值。
    public init(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2AccountAuthenticationError.invalidAssertion }
        self.value = value
    }
}

/// 账户密码因子适配器的输入、传输及服务端响应错误。
public enum V2AccountAuthenticationError: Error, Equatable, Sendable {
    /// 账户注册或断言端点不满足 HTTPS 与主机条件。
    case invalidEndpoint
    /// 登录账户名不符合本地长度与字符集限制。
    case invalidAccountHandle
    /// 公开账号标识无效；一次性注册提供者缺少公开标识或显示名时也使用此错误。
    case invalidPublicHandle
    /// 注册公开身份校验未通过，被映射为显示名错误。
    case invalidDisplayName
    /// 密码 UTF-8 长度不在 12 到 1024 字节之间。
    case invalidPassword
    /// 断言为空白或包含不允许的 ASCII 控制字符。
    case invalidAssertion
    /// 成功响应的内容类型或响应体格式不符合约定。
    case invalidResponse
    /// 服务端拒绝密码认证，或一次性密码已被取用。
    case authenticationRejected
    /// 服务端返回 409，映射为账户已存在。
    case accountAlreadyExists
    /// 除 CancellationError 外的传输失败，不携带密码或请求体。
    case networkFailure
    /// 未单独处理的 HTTP 状态码。
    case serverStatus(Int)
}

/// 使用短期密码参数完成账户注册或认证并取得一次性断言的边界。
///
/// 调用方不应将密码持久化到偏好设置、日志或 Keychain，也不应在可观察应用状态中长期保留它。
public protocol V2PasswordAccountAuthenticating: Sendable {
    /// 注册账户并返回绑定设备的一次性断言。
    ///
    /// - Parameters:
    ///   - accountHandle: 登录账户名。
    ///   - password: 仅用于本次请求的密码。
    ///   - publicHandle: 对外展示与查找使用的账号标识。
    ///   - displayName: 公开显示名。
    ///   - deviceID: 本次注册绑定的设备。
    /// - Returns: 供设备凭证签发使用的账户断言。
    /// - Throws: 输入校验、服务端业务或传输错误。
    func register(accountHandle: String, password: String, publicHandle: String, displayName: String, deviceID: DeviceID) async throws -> V2AccountAssertion
    /// 验证已有账户的密码并返回绑定设备的一次性断言。
    ///
    /// - Parameters:
    ///   - accountHandle: 登录账户名。
    ///   - password: 仅用于本次请求的密码。
    ///   - deviceID: 断言绑定的设备。
    /// - Returns: 供设备凭证签发使用的账户断言。
    /// - Throws: 输入、认证或传输错误。
    func authenticate(accountHandle: String, password: String, deviceID: DeviceID) async throws -> V2AccountAssertion
}

/// 供密码登录后备流程使用的一次性密码交接所有者。
///
/// 调用时先清除 actor 中的密码，再执行参数检查与网络认证。失败或取消后也不能复用，重试需要新的显式用户操作。
/// Swift String 不保证即时内存清零，此设计约束的是持有时间与持久化，而非内存擦除。
public actor V2OneTimePasswordAccountAssertionProvider: V2DeviceBoundAccountAssertionProvider {
    /// 本次密码交接用于注册新账户还是认证已有账户。
    public enum Mode: Sendable { case register, authenticate }

    /// 用户输入的登录账户名，由认证器执行格式校验。
    private let accountHandle: String
    /// 实际完成密码因子请求的可注入认证器。
    private let authenticator: any V2PasswordAccountAuthenticating
    /// 一次性交接执行的账户操作类型。
    private let mode: Mode
    /// 注册所需的公开账号标识，认证模式可省略。
    private let publicHandle: String?
    /// 注册所需的显示名，认证模式可省略。
    private let displayName: String?
    /// 仅允许取用一次的密码，首次请求前置为 nil。
    private var password: String?

    /// 保存一次性密码交接所需输入，不立即校验或发起认证。
    ///
    /// - Parameters:
    ///   - accountHandle: 登录账户名。
    ///   - password: 首次取用后从 actor 属性清除的密码。
    ///   - mode: 默认为认证已有账户。
    ///   - publicHandle: 注册时必需的公开标识。
    ///   - displayName: 注册时必需的显示名。
    ///   - authenticator: 负责实际账户请求的认证器。
    public init(
        accountHandle: String,
        password: String,
        mode: Mode = .authenticate,
        publicHandle: String? = nil,
        displayName: String? = nil,
        authenticator: any V2PasswordAccountAuthenticating
    ) {
        self.accountHandle = accountHandle
        self.password = password
        self.mode = mode
        self.publicHandle = publicHandle
        self.displayName = displayName
        self.authenticator = authenticator
    }

    /// 取走并清除暂存密码，为指定设备请求账户断言。
    ///
    /// - Parameter deviceID: 本次账户因子结果绑定的设备身份。
    /// - Returns: 认证器返回的一次性断言原始值。
    /// - Throws: 密码已取用时报告 authenticationRejected；注册缺少公开标识或显示名时报告 invalidPublicHandle；其余认证错误传播。
    ///
    /// 即使参数检查或网络请求失败，密码也不会放回，不能在同一提供者上自动重试。
    public func accountAssertion(for deviceID: DeviceID) async throws -> String {
        guard let password else { throw V2AccountAuthenticationError.authenticationRejected }
        self.password = nil
        switch mode {
        case .register:
            guard let publicHandle, let displayName else { throw V2AccountAuthenticationError.invalidPublicHandle }
            return try await authenticator.register(accountHandle: accountHandle, password: password, publicHandle: publicHandle, displayName: displayName, deviceID: deviceID).value
        case .authenticate:
            return try await authenticator.authenticate(accountHandle: accountHandle, password: password, deviceID: deviceID).value
        }
    }
}

/// 密码后备认证因子的 HTTPS 适配器，不决定界面是否提供密码登录。
///
/// 注册与登录各发送一次 JSON 请求，不保存密码、断言或设备凭证，不执行自动重试。
public struct V2HTTPPasswordAccountAuthenticator: V2PasswordAccountAuthenticating, Sendable {
    /// 账户注册请求的完整端点。
    private let registrationEndpoint: URL
    /// 已有账户密码认证的完整断言端点。
    private let assertionEndpoint: URL
    /// 可注入的账户 HTTP 传输。
    private let transport: any V2AuthHTTPTransport

    /// 校验注册与认证端点并保存传输依赖。
    ///
    /// - Parameters:
    ///   - registrationEndpoint: HTTPS 注册地址，要求 host 非 nil。
    ///   - assertionEndpoint: HTTPS 断言地址，要求 host 非 nil。
    ///   - transport: 默认使用账户服务的隔离 URLSession 适配器。
    /// - Throws: 任一端点不符合条件时抛出 invalidEndpoint。
    public init(
        registrationEndpoint: URL,
        assertionEndpoint: URL,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()
    ) throws {
        guard Self.isHTTPS(registrationEndpoint), Self.isHTTPS(assertionEndpoint) else {
            throw V2AccountAuthenticationError.invalidEndpoint
        }
        self.registrationEndpoint = registrationEndpoint
        self.assertionEndpoint = assertionEndpoint
        self.transport = transport
    }

    /// 校验公开标识和公开身份模型后向注册端点提交账户资料。
    ///
    /// - Parameters:
    ///   - accountHandle: 3 到 64 位 ASCII 字母、数字、下划线或连字符。
    ///   - password: 12 到 1024 个 UTF-8 字节的密码。
    ///   - publicHandle: 须通过 V2PublicHandle 构造校验的公开标识。
    ///   - displayName: 须通过 V2PublicIdentity 校验的显示名。
    ///   - deviceID: 本次注册设备身份。
    /// - Returns: 注册成功后的账户断言。
    /// - Throws: 公开标识、公开身份、账户输入、传输或响应错误。
    ///
    /// 本地公开身份校验暂以 deviceID 原始值构造用户标识；该值不作为用户身份提交，实际身份由服务端决定。
    public func register(accountHandle: String, password: String, publicHandle: String, displayName: String, deviceID: DeviceID) async throws -> V2AccountAssertion {
        guard (try? V2PublicHandle(publicHandle)) != nil else { throw V2AccountAuthenticationError.invalidPublicHandle }
        guard (try? V2PublicIdentity(userID: try .init(deviceID.rawValue), handle: .init(publicHandle), displayName: displayName, accountKind: .regular)) != nil else { throw V2AccountAuthenticationError.invalidDisplayName }
        return try await send(accountHandle: accountHandle, password: password, deviceID: deviceID, publicHandle: publicHandle, displayName: displayName, to: registrationEndpoint)
    }

    /// 向断言端点提交已有账户的密码认证请求，不附带注册公开资料。
    ///
    /// - Parameters:
    ///   - accountHandle: 符合本地字符集及长度限制的登录账户名。
    ///   - password: 12 到 1024 个 UTF-8 字节的密码。
    ///   - deviceID: 本次断言绑定的设备。
    /// - Returns: 可交给设备凭证签发流程的账户断言。
    /// - Throws: 输入、认证拒绝、传输或响应错误。
    public func authenticate(accountHandle: String, password: String, deviceID: DeviceID) async throws -> V2AccountAssertion {
        try await send(accountHandle: accountHandle, password: password, deviceID: deviceID, publicHandle: nil, displayName: nil, to: assertionEndpoint)
    }

    /// 校验账户名与密码长度后发送 JSON POST，设置 15 秒超时及禁止缓存的请求策略。
    ///
    /// 200 需通过 JSON 内容类型判断，再解析账户断言；401 映射为认证拒绝，409 映射为账户已存在，其余保留状态码。
    /// CancellationError 原样传播，其他传输错误统一为 networkFailure，包括未转换的 URLError.cancelled。
    /// 不裁剪或规范化输入，也不在成功后检查任务取消；调用所有者负责后续生命周期校验。
    private func send(accountHandle: String, password: String, deviceID: DeviceID, publicHandle: String?, displayName: String?, to endpoint: URL) async throws -> V2AccountAssertion {
        guard Self.isValidAccountHandle(accountHandle) else { throw V2AccountAuthenticationError.invalidAccountHandle }
        guard password.utf8.count >= 12, password.utf8.count <= 1_024 else { throw V2AccountAuthenticationError.invalidPassword }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(PasswordRequest(accountHandle: accountHandle, password: password, deviceID: deviceID.rawValue, publicHandle: publicHandle, displayName: displayName))
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2AccountAuthenticationError.networkFailure
        }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2AccountAuthenticationError.invalidResponse
        case 401: throw V2AccountAuthenticationError.authenticationRejected
        case 409: throw V2AccountAuthenticationError.accountAlreadyExists
        default: throw V2AccountAuthenticationError.serverStatus(response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(AssertionResponse.self, from: data) else {
            throw V2AccountAuthenticationError.invalidResponse
        }
        return try V2AccountAssertion(body.accountAssertion)
    }

    /// 仅检查 scheme 为 HTTPS 且 host 非 nil，不额外排除 URL 用户信息、查询或片段。
    private static func isHTTPS(_ endpoint: URL) -> Bool {
        endpoint.scheme?.lowercased() == "https" && endpoint.host != nil
    }

    /// 要求账户名包含 3 到 64 个 Unicode 标量，且每个字符均为 ASCII 字母、数字、下划线或连字符。
    private static func isValidAccountHandle(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return (3 ... 64).contains(scalars.count) && scalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) ||
            ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) ||
            $0 == "_" || $0 == "-"
        }
    }
}

/// 密码注册与认证共用的 JSON 请求体，注册时包含公开标识及显示名。
private struct PasswordRequest: Encodable {
    /// 未经规范化的登录账户名。
    let accountHandle: String
    /// 仅用于请求编码和发送的敏感密码。
    let password: String
    /// 断言绑定设备的原始标识。
    let deviceID: String
    /// 可选注册公开标识，登录认证时省略。
    let publicHandle: String?
    /// 可选注册显示名，登录认证时省略。
    let displayName: String?
}

/// 成功响应的最小 JSON 模型，只提取账户断言。
private struct AssertionResponse: Decodable {
    /// 待进一步进行断言字符串校验的敏感原始值。
    let accountAssertion: String
}
