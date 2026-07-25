import IMV2Server
import Vapor

/// All account routes remain loopback-only and require an additional secret
/// injected by the HTTPS edge. The edge replaces caller-controlled forwarding
/// headers before it adds this proof, so account code cannot treat a direct
/// local request as a trusted proxy request.
public struct V2AccountEdgeAuthenticationMiddleware: AsyncMiddleware, Sendable {
    public static let headerName = "X-IM-V2-Account-Edge-Authorization"

    private let secret: V2AccountEdgeAuthorizationSecret

    public init(secret: V2AccountEdgeAuthorizationSecret) {
        self.secret = secret
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let values = request.headers[Self.headerName]
        guard values.count == 1, secret.matches(base64EncodedCandidate: values[0]) else {
            throw Abort(.forbidden)
        }
        return try await next.respond(to: request)
    }
}
