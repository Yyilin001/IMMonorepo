import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 设备凭证签发和刷新 HTTP 路由。
///
/// 挂载 `POST /v2/device-credentials` 与 `POST /v2/device-credentials/refresh`。
/// 与实时网关路径解耦，通常在账号服务实例上按网关边界单独挂载。
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
    /// - Throws: 当缺失必填字段或存在额外非法字段时抛 `DecodingError`。
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

    public init(userID: String, deviceID: String, refreshCredential: String, revocationCredential: V2DeviceRevocationCredential, operationID: UUID) {
        self.userID = userID
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
        self.revocationCredential = revocationCredential
        self.operationID = operationID
    }
}

/// `POST /v2/device-credentials` 的轻量路由适配层。
///
/// 路由层仅做输入校验与 HTTP 码映射，真正业务决策委托给 `V2DeviceCredentialIssuing`。
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
    /// 速率限制由外层网关承担，超限通常返回 `Retry-After`。
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
