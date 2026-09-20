import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 旧版本设备注册注销请求体。
///
/// - Parameters:
///   - accountAssertion: 账户断言。
///   - assertionDeviceID: 发起注销的旧设备 ID。
///   - targetDeviceID: 目标设备 ID。
///   - operationID: 幂等 ID。
public struct V2LegacyDeviceRegistrationCancellationHTTPRequest: Content, Sendable {
    public let accountAssertion: String
    public let assertionDeviceID: String
    public let targetDeviceID: String
    public let operationID: UUID

    public init(accountAssertion: String, assertionDeviceID: String, targetDeviceID: String, operationID: UUID) {
        self.accountAssertion = accountAssertion
        self.assertionDeviceID = assertionDeviceID
        self.targetDeviceID = targetDeviceID
        self.operationID = operationID
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: RequestKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == Set(["accountAssertion", "assertionDeviceID", "targetDeviceID", "operationID"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid legacy registration cancellation request"))
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        accountAssertion = try fields.decode(String.self, forKey: .accountAssertion)
        assertionDeviceID = try fields.decode(String.self, forKey: .assertionDeviceID)
        targetDeviceID = try fields.decode(String.self, forKey: .targetDeviceID)
        operationID = try fields.decode(UUID.self, forKey: .operationID)
    }

    private enum CodingKeys: String, CodingKey { case accountAssertion, assertionDeviceID, targetDeviceID, operationID }
    private struct RequestKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// 兼容旧客户端的设备注册注销路由。
///
/// 接口要求通过边缘 proof 鉴权+速率限制并验证账户断言。
/// 只允许对同一账户下的旧设备凭证进行清理，不支持跨账号操作。
public struct V2VaporLegacyDeviceRegistrationCancellationRoutes: Sendable {
    public static let path = "/v2/device-credentials/cancel-legacy-registration"
    private let assertionVerifier: any V2DeviceBoundAccountAssertionVerifier
    private let service: any V2LegacyDeviceRegistrationCancelling

    /// 初始化。
    ///
    /// - Parameters:
    ///   - assertionVerifier: 账户断言校验器。
    ///   - service: 撤销服务。
    public init(assertionVerifier: any V2DeviceBoundAccountAssertionVerifier, service: any V2LegacyDeviceRegistrationCancelling) {
        self.assertionVerifier = assertionVerifier
        self.service = service
    }

    /// 挂载 `POST /v2/device-credentials/cancel-legacy-registration`。
    public func register(on routes: any RoutesBuilder) {
        routes.on(.POST, "v2", "device-credentials", "cancel-legacy-registration", body: .collect(maxSize: "8kb")) { request async -> Response in
            guard (request.body.data?.readableBytes ?? 0) <= 8_192 else { return Self.response(.payloadTooLarge) }
            guard request.headers.contentType?.type == "application", request.headers.contentType?.subType == "json" else { return Self.response(.badRequest) }
            let input: V2LegacyDeviceRegistrationCancellationHTTPRequest
            do { input = try request.content.decode(V2LegacyDeviceRegistrationCancellationHTTPRequest.self) }
            catch { return Self.response(.badRequest) }
            guard !input.accountAssertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  input.accountAssertion.utf8.count <= 4_096,
                  let assertionDevice = UUID(uuidString: input.assertionDeviceID),
                  let targetDevice = UUID(uuidString: input.targetDeviceID),
                  assertionDevice != targetDevice else { return Self.response(.badRequest) }
            let user: UserID
            let revision: Int64?
            do {
                user = try await assertionVerifier.verifiedUserID(for: input.accountAssertion, deviceID: .init(uuid: assertionDevice))
                revision = try await assertionVerifier.credentialRevision(for: input.accountAssertion, deviceID: .init(uuid: assertionDevice))
            } catch V2AccountAssertionError.invalidAssertion {
                return Self.response(.unauthorized)
            } catch {
                return Self.response(.serviceUnavailable)
            }
            do {
                let trusted = try V2TrustedLegacyDeviceRegistrationCancellation(userID: user,
                    assertionDeviceID: .init(uuid: assertionDevice), targetDeviceID: .init(uuid: targetDevice), operationID: input.operationID, credentialRevision: revision)
                switch try await service.cancel(trusted) {
                case .applied, .idempotent: return Self.response(.noContent)
                case .accountUnavailable: return Self.response(.forbidden)
                case .targetUnavailable: return Self.response(.notFound)
                case .conflict: return Self.response(.conflict)
                case .capacityExceeded: return Self.response(.insufficientStorage)
                }
            } catch {
                return Self.response(.serviceUnavailable)
            }
        }
    }

    /// 统一构造 no-store 响应头。
    private static func response(_ status: HTTPResponseStatus) -> Response {
        .init(status: status, headers: ["Cache-Control": "no-store", "Pragma": "no-cache"])
    }
}
