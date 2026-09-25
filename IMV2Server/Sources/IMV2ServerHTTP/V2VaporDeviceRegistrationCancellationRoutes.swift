import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes

/// 设备注册注销请求体。
///
/// - Parameters:
///   - cancellation: 注销命令内容。
public struct V2DeviceRegistrationCancellationHTTPRequest: Content, Sendable {
    public let cancellation: V2DeviceRegistrationCancellation
    public init(_ cancellation: V2DeviceRegistrationCancellation) { self.cancellation = cancellation }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: RequestKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == Set(["deviceID", "operationID", "proof", "issueBeforeMilliseconds"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid registration cancellation request"))
        }
        cancellation = try V2DeviceRegistrationCancellation(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws { try cancellation.encode(to: encoder) }
    private struct RequestKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// 设备注册注销路由。
///
/// 该接口必须运行在可信边缘链路后，并受请求体大小和速率控制。
/// 该端点不会通过持有某一证明直接获得任何会话凭证，所有权限由服务端凭证逻辑处理。
public struct V2VaporDeviceRegistrationCancellationRoutes: Sendable {
    public static let path = "/v2/device-credentials/cancel-registration"
    private let service: any V2DeviceRegistrationCancelling

    /// 初始化。
    ///
    /// - Parameter service: 设备注销服务。
    public init(service: any V2DeviceRegistrationCancelling) { self.service = service }

    /// 挂载 `POST /v2/device-credentials/cancel-registration`。
    ///
    /// - 请求体大小上限 1KB；非法媒体类型返回 400。
    /// - 成功返回 204；幂等/过期/不可重放分别返回 204/410。
    public func register(on routes: any RoutesBuilder) {
        routes.on(.post, "v2", "device-credentials", "cancel-registration", maxBodySize: "1kb") { request async -> Response in
            // Vapor 的收集大小限制只适用于实时流；内存中的请求正文已经收集完毕，
            // 返回时不会再次检查大小。两种情况都要执行相同的 1 KB 限制。
            do {
                let body = try await request.body.collect()
                guard (body?.count ?? 0) <= 1_024 else { return Self.response(.contentTooLarge) }
            }
            catch let abort as Abort where abort.status == .contentTooLarge { return Self.response(.contentTooLarge) }
            catch { return Self.response(.badRequest) }
            guard request.headers.contentType?.type == "application", request.headers.contentType?.subType == "json" else {
                return Self.response(.badRequest)
            }
            let input: V2DeviceRegistrationCancellationHTTPRequest
            do { input = try await request.content.decode(V2DeviceRegistrationCancellationHTTPRequest.self) }
            catch let abort as Abort where abort.status == .contentTooLarge { return Self.response(.contentTooLarge) }
            catch { return Self.response(.badRequest) }
            do {
                switch try await service.cancel(input.cancellation) {
                case .applied, .idempotent: return Self.response(.noContent)
                case .expired: return Self.response(.gone)
                }
            } catch V2DeviceSessionServiceError.invalidRequest {
                return Self.response(.badRequest)
            } catch {
                return Self.response(.serviceUnavailable)
            }
        }
    }

    /// 统一构造仅包含 no-store 的轻量响应。
    private static func response(_ status: HTTPResponse.Status) -> Response {
        .init(status: status, headers: [.cacheControl: "no-store", .v2Pragma: "no-cache"])
    }
}
