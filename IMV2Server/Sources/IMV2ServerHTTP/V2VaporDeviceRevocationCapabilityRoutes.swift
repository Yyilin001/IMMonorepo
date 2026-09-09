import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 设备撤销能力请求体。
///
/// - Parameters:
///   - credential: 撤销凭据。
///   - operationID: 幂等操作 ID。
public struct V2DeviceRevocationCapabilityHTTPRequest: Content, Sendable {
    public let credential: V2DeviceRevocationCredential
    public let operationID: UUID

    public init(credential: V2DeviceRevocationCredential, operationID: UUID) {
        self.credential = credential
        self.operationID = operationID
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: RequestKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == Set(["credential", "operationID"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid revocation request"))
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        credential = try fields.decode(V2DeviceRevocationCredential.self, forKey: .credential)
        operationID = try fields.decode(UUID.self, forKey: .operationID)
    }

    private enum CodingKeys: String, CodingKey { case credential, operationID }
    private struct RequestKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// 设备能力注销路由。
///
/// 本接口不走普通 account-edge 鉴权，目标场景是旧凭证过期或已注销状态下
/// 依然能安全完成能力吊销。
/// 请求体通过签名凭证驱动，不回传具体撤销原因。
public struct V2VaporDeviceRevocationCapabilityRoutes: Sendable {
    public static let path = "/v2/device-credentials/revoke"
    private let service: any V2DeviceRevocationCapabilityRedeeming

    /// 初始化。
    ///
    /// - Parameter service: 能力撤销服务。
    public init(service: any V2DeviceRevocationCapabilityRedeeming) { self.service = service }

    /// 挂载 `POST /v2/device-credentials/revoke`。
    public func register(on routes: any RoutesBuilder) {
        routes.on(.POST, "v2", "device-credentials", "revoke", body: .collect(maxSize: "1kb")) { request async -> Response in
            guard (request.body.data?.readableBytes ?? 0) <= 1_024 else {
                return Self.response(.payloadTooLarge)
            }
            guard request.headers.contentType?.type == "application",
                  request.headers.contentType?.subType == "json" else {
                return Self.response(.badRequest)
            }
            let input: V2DeviceRevocationCapabilityHTTPRequest
            do { input = try request.content.decode(V2DeviceRevocationCapabilityHTTPRequest.self) }
            catch { return Self.response(.badRequest) }
            do {
                switch try await service.redeem(input.credential, operationID: input.operationID) {
                case .applied, .idempotent: return Self.response(.noContent)
                case .invalidCredential: return Self.response(.unauthorized)
                case .expired: return Self.response(.gone)
                case .operationConflict: return Self.response(.conflict)
                }
            } catch {
                return Self.response(.serviceUnavailable)
            }
        }
    }

    /// 统一构造 no-store 空体响应。
    private static func response(_ status: HTTPResponseStatus) -> Response {
        .init(status: status, headers: ["Cache-Control": "no-store", "Pragma": "no-cache"])
    }
}
