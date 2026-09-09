import Foundation
import IMV2Core
import IMV2Server
import Vapor

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

/// Mount behind trusted-edge validation and address rate limits, outside
/// ordinary account authentication. Proof possession cannot obtain credentials.
public struct V2VaporDeviceRegistrationCancellationRoutes: Sendable {
    public static let path = "/v2/device-credentials/cancel-registration"
    private let service: any V2DeviceRegistrationCancelling

    public init(service: any V2DeviceRegistrationCancelling) { self.service = service }

    public func register(on routes: any RoutesBuilder) {
        routes.on(.POST, "v2", "device-credentials", "cancel-registration", body: .collect(maxSize: "1kb")) { request async -> Response in
            guard (request.body.data?.readableBytes ?? 0) <= 1_024 else { return Self.response(.payloadTooLarge) }
            guard request.headers.contentType?.type == "application", request.headers.contentType?.subType == "json" else {
                return Self.response(.badRequest)
            }
            let input: V2DeviceRegistrationCancellationHTTPRequest
            do { input = try request.content.decode(V2DeviceRegistrationCancellationHTTPRequest.self) }
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

    private static func response(_ status: HTTPResponseStatus) -> Response {
        .init(status: status, headers: ["Cache-Control": "no-store", "Pragma": "no-cache"])
    }
}
