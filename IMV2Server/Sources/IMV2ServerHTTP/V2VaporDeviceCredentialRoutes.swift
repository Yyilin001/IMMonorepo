import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// `POST /v2/device-credentials` 使用的设备注册与凭证签发请求体。
///
/// 解码要求四个必填字段，并拒绝未声明字段。设备标识、操作标识与取消材料的对应关系
/// 由路由层校验；账号归属通过绑定目标设备的账号断言确定，不能由请求直接指定用户 ID。
/// 直接初始化仅保存输入，不执行解码或业务校验。
public struct V2DeviceCredentialIssueHTTPRequest: Content, Sendable {
    /// 账号断言 token。
    public let accountAssertion: String
    /// 目标设备 ID。
    public let deviceID: String
    /// 幂等 ID。
    public let operationID: UUID
    /// 设备注销/替换凭据信息。
    public let cancellation: V2DeviceRegistrationCancellation
    /// 设备名称，便于展示与回溯。
    public let deviceName: String?
    /// 设备平台信息。
    public let platform: String?

    /// 构造设备注册请求数据，不在初始化时校验断言或字段之间的对应关系。
    ///
    /// - Parameters:
    ///   - accountAssertion: 待验证的账号断言，须绑定目标设备。
    ///   - deviceID: 目标设备的字符串标识。
    ///   - operationID: 本次注册的幂等操作标识，须与取消材料中的操作标识相同。
    ///   - cancellation: 与目标设备和操作绑定的注册取消材料。
    ///   - deviceName: 可选设备展示名称，格式与长度由注册元数据校验负责。
    ///   - platform: 可选设备平台说明，格式与长度由注册元数据校验负责。
    public init(accountAssertion: String, deviceID: String, operationID: UUID, cancellation: V2DeviceRegistrationCancellation, deviceName: String? = nil, platform: String? = nil) {
        self.accountAssertion = accountAssertion
        self.deviceID = deviceID
        self.operationID = operationID
        self.cancellation = cancellation
        self.deviceName = deviceName
        self.platform = platform
    }

    /// 解码时进行字段完整性校验。
    ///
    /// - Parameter decoder: 提供请求键值容器的解码器。
    /// - Throws: 缺失必填字段、出现未知字段、字段类型不匹配或嵌套取消材料无效时抛出 `DecodingError`。
    ///
    /// 允许省略或显式传入 `null` 的字段仅有 `deviceName` 与 `platform`；业务授权在解码后执行。
    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: RequestKey.self)
        let required = Set(["accountAssertion", "deviceID", "operationID", "cancellation"])
        let actual = Set(keys.allKeys.map(\.stringValue))
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(["deviceName", "platform"])) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid credential issue request"))
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        accountAssertion = try fields.decode(String.self, forKey: .accountAssertion)
        deviceID = try fields.decode(String.self, forKey: .deviceID)
        operationID = try fields.decode(UUID.self, forKey: .operationID)
        cancellation = try fields.decode(V2DeviceRegistrationCancellationHTTPRequest.self, forKey: .cancellation).cancellation
        deviceName = try fields.decodeIfPresent(String.self, forKey: .deviceName)
        platform = try fields.decodeIfPresent(String.self, forKey: .platform)
    }

    private enum CodingKeys: String, CodingKey {
        case accountAssertion, deviceID, operationID, cancellation, deviceName, platform
    }

    /// 自定义解码键集合，用于严格校验未知字段。
    private struct RequestKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// 设备凭证签发响应。
///
/// 时间字段统一为毫秒时间戳（Epoch 毫秒）。
public struct V2DeviceCredentialIssueHTTPResponse: Content, Sendable {
    /// 用户 ID。
    public let userID: String
    /// 设备 ID。
    public let deviceID: String
    /// 新的访问令牌。
    public let accessToken: String
    /// 访问令牌过期时间（毫秒）。
    public let accessTokenExpiresAtMilliseconds: Int64
    /// 刷新凭证。
    public let refreshCredential: String
    /// 撤销凭证。
    public let revocationCredential: V2DeviceRevocationCredential
    /// 撤销凭证过期时间（毫秒）。
    public let revocationCredentialExpiresAtMilliseconds: Int64
    /// 可选的注销信息回显。
    public let registrationCancellation: V2DeviceRegistrationCancellation?

    /// 将领域层已签发凭证转换为 HTTP 响应，并验证两个到期时间的表示范围。
    ///
    /// 两个日期均以 Unix 毫秒向零截断，允许可表示的负值；此转换不判断凭证是否仍然有效。
    ///
    /// - Parameters:
    ///   - credentials: 签发或刷新服务返回的凭证与到期时间。
    ///   - registrationCancellation: 注册成功时回显的取消材料；刷新响应默认不提供。
    /// - Throws: 任一到期时间非有限或超出 `Int64` 毫秒范围时，抛出
    ///   `V2DeviceCredentialServiceError.malformedPersistence`。
    init(credentials: V2IssuedDeviceCredentials, registrationCancellation: V2DeviceRegistrationCancellation? = nil) throws {
        let milliseconds = credentials.accessTokenExpiresAt.timeIntervalSince1970 * 1_000
        guard let signedMilliseconds = Int64(exactly: milliseconds.rounded(.towardZero)),
              let revocationMilliseconds = Int64(exactly: (credentials.revocationCredentialExpiresAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
            throw V2DeviceCredentialServiceError.malformedPersistence
        }
        userID = credentials.userID.rawValue
        deviceID = credentials.deviceID.rawValue
        accessToken = credentials.accessToken
        accessTokenExpiresAtMilliseconds = signedMilliseconds
        refreshCredential = credentials.refreshCredential
        revocationCredential = credentials.revocationCredential
        revocationCredentialExpiresAtMilliseconds = revocationMilliseconds
        self.registrationCancellation = registrationCancellation
    }
}

/// 刷新凭证请求。
public struct V2DeviceCredentialRefreshHTTPRequest: Content, Sendable {
    /// 用户 ID。
    public let userID: String
    /// 设备 ID。
    public let deviceID: String
    /// 刷新凭证。
    public let refreshCredential: String
    /// 撤销凭证。
    public let revocationCredential: V2DeviceRevocationCredential
    /// 幂等 ID。
    public let operationID: UUID

    /// 构造刷新请求；字符串标识和凭证组合由路由及刷新服务后续验证。
    ///
    /// - Parameters:
    ///   - userID: 凭证所属用户的字符串标识。
    ///   - deviceID: 凭证所属设备的字符串标识。
    ///   - refreshCredential: 待轮换的刷新凭证。
    ///   - revocationCredential: 与刷新请求一起交给领域层验证的撤销凭证。
    ///   - operationID: 本次刷新操作的幂等标识。
    public init(userID: String, deviceID: String, refreshCredential: String, revocationCredential: V2DeviceRevocationCredential, operationID: UUID) {
        self.userID = userID
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
        self.revocationCredential = revocationCredential
        self.operationID = operationID
    }
}

/// 将设备注册、凭证签发和刷新业务暴露为 Vapor HTTP 接口。
///
/// 注册入口先验证设备绑定账号断言，再将注册与取消材料交给 `V2DeviceCredentialIssuing`；
/// 刷新入口将凭证组合交给同一服务。路由负责输入转换、结果状态码与禁止缓存的成功响应。
/// 调用方负责提供适用的断言验证器，并在部署入口配置 TLS 与所需的请求限流策略。
public struct V2VaporDeviceCredentialRoutes: Sendable {
    private let assertionVerifier: any V2DeviceBoundAccountAssertionVerifier
    private let issuer: any V2DeviceCredentialIssuing

    /// 初始化路由依赖。
    ///
    /// - Parameters:
    ///   - assertionVerifier: 账号断言校验器。
    ///   - issuer: 设备凭证签发/刷新服务。
    public init(assertionVerifier: any V2DeviceBoundAccountAssertionVerifier, issuer: any V2DeviceCredentialIssuing) {
        self.assertionVerifier = assertionVerifier
        self.issuer = issuer
    }

    /// 注册 HTTP 接口。
    ///
    /// - `POST /v2/device-credentials`：签发新凭证；包含断言验证、取消操作校验、metadata 校验。
    /// - `POST /v2/device-credentials/refresh`：按 refreshCredential 与 revocationCredential 刷新。
    ///
    /// 注册请求显式限制为 16 KB 的 JSON 请求体。注册服务报告限流时返回 `429`，
    /// 并携带至少一秒的 `Retry-After`；额外的入口限流由部署层负责。
    /// 注册幂等冲突或设备数量达到上限返回 `409`，设备不可用返回 `403`；
    /// 断言校验失败返回 `401`，断言时钟无效返回 `503`，刷新终止拒绝返回 `401`。
    /// 签发和刷新成功均返回 `200`，并设置 `Cache-Control: no-store` 与 `Pragma: no-cache`。
    ///
    /// - Parameter routes: 接收这两个接口的路由集合；调用方选择挂载它们的服务实例。
    public func register(on routes: RoutesBuilder) {
        routes.on(.POST, "v2", "device-credentials", body: .collect(maxSize: "16kb")) { request async throws -> Response in
            guard request.headers.contentType?.type == "application", request.headers.contentType?.subType == "json" else { throw Abort(.badRequest) }
            let input: V2DeviceCredentialIssueHTTPRequest
            do { input = try request.content.decode(V2DeviceCredentialIssueHTTPRequest.self) }
            catch { throw Abort(.badRequest) }
            guard !input.accountAssertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let deviceID = try? DeviceID(input.deviceID),
                  UUID(uuidString: deviceID.rawValue) == UUID(uuidString: input.cancellation.deviceID.rawValue),
                  input.operationID == input.cancellation.operationID,
                  let metadata = try? V2DeviceRegistrationMetadata.validated(
                      displayName: input.deviceName,
                      platform: input.platform
                  )
            else { throw Abort(.badRequest) }

            let userID: UserID
            do {
                userID = try await assertionVerifier.verifiedUserID(
                    for: input.accountAssertion,
                    deviceID: deviceID
                )
            } catch V2AccountAssertionError.invalidClock {
                return .init(status: .serviceUnavailable, headers: ["Cache-Control": "no-store", "Pragma": "no-cache"])
            } catch {
                throw Abort(.unauthorized)
            }

            let outcome: V2DeviceRegistrationOutcome
            do {
                outcome = try await issuer.register(V2CancellableDeviceRegistration(registration: .init(
                    userID: userID,
                    deviceID: deviceID,
                    operationID: input.operationID,
                    metadata: metadata
                ), cancellation: input.cancellation))
            } catch V2DeviceSessionServiceError.invalidRequest {
                throw Abort(.badRequest)
            } catch {
                throw Abort(.serviceUnavailable)
            }

            let credentials: V2IssuedDeviceCredentials
            switch outcome {
            case .issued(let value), .idempotent(let value): credentials = value
            case .idempotencyConflict: throw Abort(.conflict)
            case .deviceUnavailable: throw Abort(.forbidden)
            case .activeDeviceLimitReached: throw Abort(.conflict)
            case .rateLimited(let retryAfterSeconds):
                return noStoreRetryAfterResponse(seconds: retryAfterSeconds)
            }

            return try noStoreJSONResponse(.init(credentials: credentials, registrationCancellation: input.cancellation))
        }

        routes.post("v2", "device-credentials", "refresh") { request async throws -> Response in
            let input = try request.content.decode(V2DeviceCredentialRefreshHTTPRequest.self)
            guard let userID = try? UserID(input.userID),
                  let deviceID = try? DeviceID(input.deviceID),
                  let refresh = try? V2DeviceCredentialRefresh(userID: userID, deviceID: deviceID, refreshCredential: input.refreshCredential, revocationCredential: input.revocationCredential, operationID: input.operationID)
            else { throw Abort(.badRequest) }

            let outcome: V2DeviceCredentialRefreshOutcome
            do {
                outcome = try await issuer.refresh(refresh)
            } catch {
                throw Abort(.serviceUnavailable)
            }

            let credentials: V2IssuedDeviceCredentials
            switch outcome {
            case .rotated(let value), .idempotent(let value): credentials = value
            case .terminalRejection: throw Abort(.unauthorized)
            }

            return try noStoreJSONResponse(.init(credentials: credentials))
        }
    }

    /// no-store JSON 响应，防止凭证信息被缓存。
    private func noStoreJSONResponse(_ response: V2DeviceCredentialIssueHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(response)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }

    /// 限流或额度不足时返回 retry-after。
    private func noStoreRetryAfterResponse(seconds: Int) -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        headers.replaceOrAdd(name: "Retry-After", value: String(max(1, seconds)))
        return .init(status: .tooManyRequests, headers: headers)
    }
}
