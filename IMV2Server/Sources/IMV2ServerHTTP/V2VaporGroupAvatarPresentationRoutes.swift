import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporGroupAvatarPresentationRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let service: V2ResourceGroupAvatarPresentationService
    public init(authenticator: any V2GatewayAuthenticator, service: V2ResourceGroupAvatarPresentationService) {
        self.authenticator = authenticator; self.service = service
    }
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "rooms", ":roomID", "avatar") { request async throws -> Response in
            let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            guard let raw = request.parameters.get("roomID"), let uuid = UUID(uuidString: raw) else { throw Abort(.badRequest) }
            do {
                let value = try await service.read(roomID: .init(uuid: uuid), actorUserID: identity.userID, deviceID: identity.deviceID)
                var headers = HTTPFields()
                headers[.contentType] = "application/json"; headers[.cacheControl] = "no-store"
                return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(value)))
            } catch V2MediaStoreError.downloadNotAuthorized { throw Abort(.forbidden)
            } catch V2ResourceProviderError.throttled {
                var headers = HTTPFields(); headers[.retryAfter] = "1"; headers[.cacheControl] = "no-store"
                throw Abort(.tooManyRequests, headers: headers)
            } catch { throw Abort(.serviceUnavailable) }
        }
    }
}
