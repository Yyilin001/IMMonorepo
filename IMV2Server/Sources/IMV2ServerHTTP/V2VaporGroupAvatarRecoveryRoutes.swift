import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporGroupAvatarRecoveryRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let service: V2ResourceGroupAvatarCommandService
    public init(authenticator: any V2GatewayAuthenticator, service: V2ResourceGroupAvatarCommandService) {
        self.authenticator = authenticator; self.service = service
    }
    public func register(on routes: RoutesBuilder) {
        routes.on(.post, "v2", "rooms", ":roomID", "avatar", "recovery", maxBodySize: "8kb") { request async throws -> Response in
            let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            guard let raw = request.parameters.get("roomID"), let room = UUID(uuidString: raw),
                  let bytes = try await request.body.collect() else { throw Abort(.badRequest) }
            guard bytes.count <= 8 * 1_024 else { throw Abort(.contentTooLarge) }
            let value: V2GroupAvatarRecoveryRequest
            do { value = try await request.content.decode(V2GroupAvatarRecoveryRequest.self, using: JSONDecoder()) }
            catch { throw Abort(.badRequest) }
            guard value.command.roomID.uuidValue == room else { throw Abort(.badRequest) }
            var headers: HTTPFields = [.contentType: "application/json", .cacheControl: "no-store"]
            do {
                let response = try await service.recover(value, actorUserID: identity.userID, deviceID: identity.deviceID)
                return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(response)))
            } catch V2MediaStoreError.uploadNotAuthorized { throw Abort(.forbidden, headers: headers)
            } catch V2ResourceProviderError.throttled(let retryAfter) {
                headers[.retryAfter] = String(Int(min(60, max(1, retryAfter.isFinite ? retryAfter : 1)).rounded(.up)))
                throw Abort(.tooManyRequests, headers: headers)
            } catch { throw Abort(.serviceUnavailable, headers: headers) }
        }
    }
}
