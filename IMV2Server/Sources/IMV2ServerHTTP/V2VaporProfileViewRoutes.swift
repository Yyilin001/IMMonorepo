import IMV2Server
import Vapor
import HTTPTypes

/// Retires the legacy content-only endpoint. Current clients use
/// /v2/profile-presentations/batch and consume its bounded access leases.
/// Keep an explicit terminal response so a missing resource assembly cannot
/// silently reactivate a second, unbudgeted profile-reading path.
public struct V2VaporProfileViewRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator

    public init(authenticator: any V2GatewayAuthenticator) {
        self.authenticator = authenticator
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "profile-views", "batch") { request async throws -> Response in
            _ = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            var headers = HTTPFields()
            headers[.cacheControl] = "no-store"
            headers[.v2Pragma] = "no-cache"
            return .init(status: .gone, headers: headers)
        }
    }
}
