import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import Vapor

public struct V2VaporProfilePresentationBatchRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let service: V2ResourceProfilePresentationService
    public init(authenticator: any V2GatewayAuthenticator, service: V2ResourceProfilePresentationService) {
        self.authenticator = authenticator; self.service = service
    }
    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "profile-presentations", "batch") { request async throws -> Response in
            let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            do {
                let input = try await request.content.decode(V2ProfilePresentationBatchRequest.self, using: JSONDecoder())
                let value = try await service.read(input, actorUserID: identity.userID, deviceID: identity.deviceID)
                var headers = HTTPFields()
                headers[.contentType] = "application/json"; headers[.cacheControl] = "no-store"
                return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(value)))
            } catch is DecodingError { throw Abort(.badRequest)
            } catch is V2ResourceValidationError { throw Abort(.badRequest)
            } catch V2ProfileViewReadError.invalidRequest { throw Abort(.badRequest)
            } catch V2MediaStoreError.downloadNotAuthorized { throw Abort(.forbidden)
            } catch V2ResourceProviderError.throttled {
                var headers = HTTPFields(); headers[.retryAfter] = "1"
                throw Abort(.tooManyRequests, headers: headers)
            } catch { throw Abort(.serviceUnavailable) }
        }
    }
}
