import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 由应用选择的账户因子提供短期、绑定设备的断言；ClientKit 不解释或持久化断言内容。
public protocol V2DeviceBoundAccountAssertionProvider: Sendable {
    /// 为指定设备取得短期账户断言，失败通过账户因子错误或取消报告。
    func accountAssertion(for deviceID: DeviceID) async throws -> String
}

/// 提供应用设备注册层拥有的稳定设备身份，与账户因子验证方式分离。
public protocol V2DeviceIdentityProvider: Sendable {
    /// 读取稳定设备身份；不能为了重试账户断言而任意更换设备身份。
    func deviceID() async throws -> DeviceID
}

/// 仅用于所有者设备列表展示的设备名称与平台标签，平台信息发现由应用负责。
public struct V2ClientDeviceRegistrationMetadata: Equatable, Sendable {
    /// 供账户所有者识别设备的名称，不应包含凭证。
    public let deviceName: String
    /// 设备平台展示标签，不作为认证权限依据。
    public let platform: String

    /// 保存设备名称与平台标签，不执行长度校验或平台探测。
    public init(deviceName: String, platform: String) {
        self.deviceName = deviceName
        self.platform = platform
    }

    /// 没有平台元数据时使用的占位值，名称为 This device，平台为 Unknown。
    public static let unknown = Self(deviceName: "This device", platform: "Unknown")
}

/// 签发请求前必须持久化的待注册操作及目的受限的取消证明。
///
/// 即使整个签发响应丢失，取消材料仍需可用；重试相同设备操作时复用该记录，不随请求重新生成证明。
public struct V2PendingDeviceCredentialRegistration: Codable, Equatable, Sendable {
    /// 绑定设备、操作身份及签发截止时间的取消材料。
    public let cancellation: V2DeviceRegistrationCancellation
    /// 从取消材料读取本次注册设备。
    public var deviceID: DeviceID { cancellation.deviceID }
    /// 从取消材料读取跨重试稳定的操作 UUID。
    public var operationID: UUID { cancellation.operationID }

    /// 包装已校验的取消材料，不生成新证明或写入存储。
    public init(cancellation: V2DeviceRegistrationCancellation) { self.cancellation = cancellation }

    /// 为设备注册生成取消证明，并设置当前时间十分钟后的签发截止时间。
    ///
    /// - Parameters:
    ///   - deviceID: 待注册的稳定设备身份。
    ///   - operationID: 本次操作稳定 UUID。
    ///   - now: 构造截止时间使用的墙上时钟。
    /// - Returns: 尚待持久化的完整注册操作。
    /// - Throws: 截止时间不能精确转换为 Int64 时报告 malformedRecord；取消材料自身校验失败继续抛出。
    ///
    /// 先将 now 加 600 秒再转为 Unix 毫秒并向下取整，实际期限受毫秒精度影响。
    public static func prepare(deviceID: DeviceID, operationID: UUID, now: Date = Date()) throws -> Self {
        guard let cutoff = Int64(exactly: (now.addingTimeInterval(600).timeIntervalSince1970 * 1_000).rounded(.down)) else {
            throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord
        }
        return try .init(cancellation: .init(deviceID: deviceID, operationID: operationID,
            proof: .generate(), issueBeforeMilliseconds: cutoff))
    }
}

/// 待注册操作持久化的访问、格式、失效与容量错误分类。
public enum V2DeviceCredentialRegistrationOperationStoreError: Error, Equatable, Sendable {
    /// 待注册记录当前不可访问，不能据此判断操作不存在。
    case unavailable
    /// 记录或必要取消材料格式不合法，或构造的时间不能表示。
    case malformedRecord
    /// 底层存储材料已永久失效，需要显式恢复。
    case permanentlyInvalidated
    /// 存储达到实现定义的容量上限。
    case capacityExceeded
    /// 未分类的底层存储状态码。
    case unexpectedStatus(Int32)
}

/// 保存完整待注册操作的边界，签发前持久化、接纳或撤销交接完成后删除。
public protocol V2DeviceCredentialRegistrationOperationStore: Sendable {
    /// 读取完整待注册操作，不存在时返回 nil，读取失败不能伪装成不存在。
    func load() async throws -> V2PendingDeviceCredentialRegistration?
    /// 持久化完整待注册操作，成功后才允许提交签发请求。
    func save(_ registration: V2PendingDeviceCredentialRegistration) async throws
    /// 删除待注册操作，不自行决定凭证接纳或远端取消。
    func delete() async throws
}

/// 账户断言换取设备凭证流程的输入、恢复和签发一致性错误。
public enum V2AccountAssertionCredentialProviderError: Error, Equatable, Sendable {
    /// 账户因子提供者未能给出断言，且错误没有更具体的保留分类。
    case assertionUnavailable
    /// 断言为空白或包含不允许的 ASCII 控制字符。
    case invalidAssertion
    /// 读取稳定设备身份失败。
    case deviceIdentityUnavailable
    /// 读取、准备或保存待注册操作失败，或确认签发时无法删除操作。
    case registrationOperationUnavailable
    /// 签发服务返回 401 或 403，拒绝账户断言。
    case assertionRejected
    /// 签发服务返回 409，注册操作存在冲突。
    case registrationConflict
    /// 持久化操作的签发截止时间不再严格晚于当前时钟。
    case registrationExpired
    /// 签发成功响应无法解码或构造有效凭证。
    case unexpectedResponse
    /// 签发设备或服务端确认的取消材料与待注册操作不一致。
    case issuedCredentialMismatch
    /// 没有与输入凭证完全匹配的内存签发记录可供接纳或放弃。
    case noIssuedCredentialToFinalize
}

/// 通过账户断言换取设备凭证的 HTTPS 签发适配器。
///
/// 应用注入账户因子和设备身份提供者；请求前保存幂等操作与取消证明，响应后先保存撤销恢复收据再返回凭证。
/// 会话引导层将凭证持久化后调用确认方法，放弃结果则先交接撤销；actor 不提供整个跨挂起签发流程的互斥，调用方应串行协调生命周期。
public actor V2HTTPAccountAssertionDeviceCredentialProvider: V2AccountDeviceCredentialProvider, V2AccountDeviceCredentialIssueFinalizer {
    /// 完整设备凭证签发端点。
    private let issueEndpoint: URL
    /// 应用选择的设备绑定账户因子。
    private let assertionProvider: any V2DeviceBoundAccountAssertionProvider
    /// 稳定设备身份的独立所有者。
    private let deviceIdentityProvider: any V2DeviceIdentityProvider
    /// 签发前保存操作及取消证明的持久化边界。
    private let operationStore: any V2DeviceCredentialRegistrationOperationStore
    /// 响应后保存目的受限撤销能力的恢复边界。
    private let recovery: any V2IssuedCredentialRecovering
    /// 随请求发送的设备展示资料。
    private let registrationMetadata: V2ClientDeviceRegistrationMetadata
    /// 执行一次签发 HTTP 请求的传输。
    private let transport: any V2AuthHTTPTransport
    /// 创建新待注册操作身份的可注入工厂。
    private let makeUUID: @Sendable () -> UUID
    /// 准备及检查签发截止时间的可注入时钟。
    private let now: @Sendable () -> Date
    /// 最近收到且尚未确认接纳或放弃的完整签发记录。
    private var issuedRegistration: IssuedRegistration?

    /// 校验签发地址并保存账户因子、设备身份、持久化和传输依赖。
    ///
    /// - Parameters:
    ///   - issueEndpoint: HTTPS 地址，要求 host 非 nil；不额外排除用户信息、查询或片段。
    ///   - assertionProvider: 提供设备绑定的短期账户断言。
    ///   - deviceIdentityProvider: 提供稳定设备身份。
    ///   - operationStore: 签发请求前持久化待注册操作。
    ///   - recovery: 保存已收到凭证的撤销恢复收据。
    ///   - registrationMetadata: 默认使用未知设备展示标签。
    ///   - transport: 默认使用账户服务的隔离 URLSession 传输。
    ///   - makeUUID: 新操作 UUID 工厂。
    ///   - now: 墙上时钟。
    /// - Throws: 地址不符合条件时抛出 invalidEndpoint。
    ///
    /// 初始化不读取设备或凭证，也不发送请求。
    public init(
        issueEndpoint: URL,
        assertionProvider: any V2DeviceBoundAccountAssertionProvider,
        deviceIdentityProvider: any V2DeviceIdentityProvider,
        operationStore: any V2DeviceCredentialRegistrationOperationStore,
        recovery: any V2IssuedCredentialRecovering,
        registrationMetadata: V2ClientDeviceRegistrationMetadata = .unknown,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport(),
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard issueEndpoint.scheme?.lowercased() == "https", issueEndpoint.host != nil else {
            throw V2HTTPAuthTransportError.invalidEndpoint
        }
        self.issueEndpoint = issueEndpoint
        self.assertionProvider = assertionProvider
        self.deviceIdentityProvider = deviceIdentityProvider
        self.operationStore = operationStore
        self.recovery = recovery
        self.registrationMetadata = registrationMetadata
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 获取设备身份及账户断言，复用或保存待注册操作后发送一次签发请求。
    ///
    /// - Returns: 已记录撤销恢复收据的完整设备凭证，尚未写入认证会话。
    /// - Throws: 因子、设备、存储、截止时间、HTTP 或签发一致性错误；明确取消保持取消语义。
    ///
    /// 200 必须为 JSON，401/403 表示断言被拒绝，409 表示注册冲突。响应设备必须匹配，取消确认必须与请求完全相同。
    /// 收到成功响应后即使调用者已取消，也先记录恢复权限；取消确认不匹配时先放弃凭证再报告不匹配，避免丢失已签发权限的清理路径。
    public func issueDeviceCredentials() async throws -> V2AuthCredentials {
        try Task.checkCancellation()
        let deviceID: DeviceID
        do { deviceID = try await deviceIdentityProvider.deviceID() }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2AccountAssertionCredentialProviderError.deviceIdentityUnavailable }
        try Task.checkCancellation()

        let assertion: String
        do { assertion = try await assertionProvider.accountAssertion(for: deviceID) }
        catch is CancellationError { throw CancellationError() }
        // Password/passkey factors can report actionable account errors before
        // any device credential is requested. Preserve those errors for the
        // app instead of presenting a misleading generic assertion failure.
        catch let error as V2AccountAuthenticationError { throw error }
        catch let error as V2DeviceCredentialRegistrationOperationStoreError { throw error }
        catch { throw V2AccountAssertionCredentialProviderError.assertionUnavailable }
        try Task.checkCancellation()
        guard isValidAssertion(assertion) else { throw V2AccountAssertionCredentialProviderError.invalidAssertion }

        let pending = try await pendingRegistration(for: deviceID)
        try Task.checkCancellation()
        guard pending.cancellation.issueBefore > now() else { throw V2AccountAssertionCredentialProviderError.registrationExpired }
        let request = try makeRequest(assertion: assertion, pending: pending)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as V2HTTPAuthTransportError {
            throw error
        } catch let failure as V2HTTPFailure { throw failure }
        catch let error as V2AuthSessionError { throw error }
        catch {
            throw V2HTTPAuthTransportError.networkFailure
        }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2HTTPAuthTransportError.invalidResponse
        case 401, 403: throw V2AccountAssertionCredentialProviderError.assertionRejected
        case 409: throw V2AccountAssertionCredentialProviderError.registrationConflict
        default: throw V2HTTPAuthTransportError.serverStatus(response.statusCode)
        }

        let credentials: V2AuthCredentials
        let confirmedCancellation: V2DeviceRegistrationCancellation?
        do {
            let body = try JSONDecoder().decode(IssueResponse.self, from: data)
            confirmedCancellation = (try? JSONDecoder().decode(CancellationConfirmation.self, from: data))?.registrationCancellation
            credentials = try .init(
                userID: .init(body.userID),
                deviceID: .init(body.deviceID),
                accessToken: body.accessToken,
                accessTokenExpiresAt: Date(timeIntervalSince1970: Double(body.accessTokenExpiresAtMilliseconds) / 1_000),
                refreshCredential: body.refreshCredential,
                revocationCredential: body.revocationCredential,
                revocationCredentialExpiresAt: Date(timeIntervalSince1970: Double(body.revocationCredentialExpiresAtMilliseconds) / 1_000)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2AccountAssertionCredentialProviderError.unexpectedResponse
        }
        guard credentials.deviceID == deviceID else {
            throw V2AccountAssertionCredentialProviderError.issuedCredentialMismatch
        }
        // Persist purpose-limited authority before returning, including when
        // a transport delivers a successful response after cancellation.
        let receipt = try await recovery.receive(credentials, operationID: pending.operationID)
        issuedRegistration = .init(pending: pending, credentials: credentials, receipt: receipt)
        guard confirmedCancellation == pending.cancellation else {
            // A stale/mismatched server response is still received authority.
            // Relinquish it durably before rejecting the unsupported binding.
            try await discardIssuedDeviceCredentials(credentials)
            throw V2AccountAssertionCredentialProviderError.issuedCredentialMismatch
        }
        return credentials
    }

    /// 在调用方持久化接纳凭证后，删除待注册操作并确认恢复收据，最后清空内存签发记录。
    ///
    /// - Parameter credentials: 必须与最近签发记录完全相同的凭证。
    /// - Throws: 无匹配记录、操作删除错误或收据确认错误。
    ///
    /// 两项持久化操作不是同一事务：若删除成功但确认失败，恢复收据保留供冷启动按账户归属处理。
    public func finalizeIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws {
        guard let issuedRegistration, issuedRegistration.credentials == credentials else {
            throw V2AccountAssertionCredentialProviderError.noIssuedCredentialToFinalize
        }
        do {
            try await operationStore.delete()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2AccountAssertionCredentialProviderError.registrationOperationUnavailable
        }
        try await recovery.adopt(issuedRegistration.receipt)
        self.issuedRegistration = nil
    }

    /// 将匹配凭证的恢复收据标记放弃并交接撤销，再删除待注册操作和内存签发记录。
    ///
    /// - Parameter credentials: 必须与当前签发记录完全相同的凭证。
    /// - Throws: 无匹配记录、撤销交接或操作删除错误。
    ///
    /// 成功只表示完成本地交接，不表示远端撤销已经执行；失败时不提前清空内存签发记录。
    public func discardIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws {
        guard let issuedRegistration, issuedRegistration.credentials == credentials else {
            throw V2AccountAssertionCredentialProviderError.noIssuedCredentialToFinalize
        }
        try await recovery.abandon(issuedRegistration.receipt)
        try await operationStore.delete()
        self.issuedRegistration = nil
    }

    /// 读取并复用相同设备的待注册记录，否则创建并保存新的操作与取消证明。
    ///
    /// 已有记录属于其他设备时直接用新记录替换，不在此交接旧操作；调用方的设备身份与恢复生命周期应保持一致。
    /// 过期判断由签发主流程执行，本方法不会自动重置相同设备的过期操作。
    private func pendingRegistration(for deviceID: DeviceID) async throws -> V2PendingDeviceCredentialRegistration {
        do {
            let existing = try await operationStore.load()
            try Task.checkCancellation()
            if let existing, existing.deviceID == deviceID {
                return existing
            }
            let pending = try V2PendingDeviceCredentialRegistration.prepare(deviceID: deviceID, operationID: makeUUID(), now: now())
            try await operationStore.save(pending)
            return pending
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2AccountAssertionCredentialProviderError.registrationOperationUnavailable
        }
    }

    /// 将断言、设备、稳定操作身份、取消材料及展示资料编码为 JSON POST。
    ///
    /// 请求设置 15 秒超时、JSON 内容类型与接收类型，并声明禁止缓存；编码失败映射为 invalidRequest。
    private func makeRequest(assertion: String, pending: V2PendingDeviceCredentialRegistration) throws -> URLRequest {
        var request = URLRequest(
            url: issueEndpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        do {
            request.httpBody = try JSONEncoder().encode(IssueRequest(
                accountAssertion: assertion,
                deviceID: pending.deviceID.rawValue,
                operationID: pending.operationID,
                cancellation: pending.cancellation,
                deviceName: registrationMetadata.deviceName,
                platform: registrationMetadata.platform
            ))
        } catch {
            throw V2HTTPAuthTransportError.invalidRequest
        }
        return request
    }

    /// 判断断言裁剪后非空且不含小于 U+0020 的字符及 U+007F，不解释或改变断言内容。
    private func isValidAssertion(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

/// 暂存在签发器中的待注册操作、完整凭证与持久化恢复收据的一致组合。
private struct IssuedRegistration: Equatable, Sendable {
    /// 签发前持久化的操作及取消材料。
    let pending: V2PendingDeviceCredentialRegistration
    /// 签发响应的完整敏感凭证。
    let credentials: V2AuthCredentials
    /// 已保存的撤销恢复收据。
    let receipt: V2DeviceRevocationIntent
}

/// 设备签发请求的 JSON 字段，与稳定取消材料一同提交账户断言。
private struct IssueRequest: Encodable {
    /// 短期敏感账户断言。
    let accountAssertion: String
    /// 待注册设备的原始标识。
    let deviceID: String
    /// 跨签发重试稳定的 UUID。
    let operationID: UUID
    /// 签发前已持久化的取消材料。
    let cancellation: V2DeviceRegistrationCancellation
    /// 设备展示名称。
    let deviceName: String
    /// 平台展示标签。
    let platform: String
}

/// 签发成功的凭证 JSON 模型，期限以 Int64 Unix 毫秒表示。
private struct IssueResponse: Decodable {
    /// 服务端签发的用户标识。
    let userID: String
    /// 服务端绑定的设备标识，需要与请求核对。
    let deviceID: String
    /// 敏感访问令牌。
    let accessToken: String
    /// 访问期限，Unix 毫秒。
    let accessTokenExpiresAtMilliseconds: Int64
    /// 敏感刷新凭证。
    let refreshCredential: String
    /// 用于独立撤销的设备能力。
    let revocationCredential: V2DeviceRevocationCredential
    /// 撤销期限，Unix 毫秒。
    let revocationCredentialExpiresAtMilliseconds: Int64
}

/// 从同一响应独立解码的取消绑定确认；缺失或格式无效会被视为不匹配。
private struct CancellationConfirmation: Decodable {
    /// 服务端回显的完整取消材料，必须与持久化请求完全一致。
    let registrationCancellation: V2DeviceRegistrationCancellation
}
