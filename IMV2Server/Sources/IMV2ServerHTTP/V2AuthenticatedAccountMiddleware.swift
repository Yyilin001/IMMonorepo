import IMV2Core
import IMV2Server
import Vapor

private struct V2AuthenticatedAccountIdentityStorageKey: StorageKey {
    typealias Value = V2AuthenticatedConnection
}

public extension Request {
    /// Returns the identity established by the production middleware, while
    /// retaining a safe direct path for focused route tests.
    func v2AuthenticatedAccountIdentity(
        using authenticator: any V2GatewayAuthenticator
    ) async throws -> V2AuthenticatedConnection {
        if let identity = storage[V2AuthenticatedAccountIdentityStorageKey.self] {
            return identity
        }
        guard let accessToken = headers.bearerAuthorization?.token,
              let rawDeviceID = headers.first(name: "X-IM-Device-ID"),
              let deviceID = try? DeviceID(rawDeviceID)
        else { throw Abort(.unauthorized) }
        do {
            let authentication = try await authenticator.authenticateSession(
                accessToken: accessToken,
                deviceID: deviceID
            )
            return .init(
                userID: authentication.userID,
                deviceID: deviceID,
                capabilityProfile: "account-edge"
            )
        } catch V2GatewayAuthenticationError.unauthenticated {
            throw Abort(.unauthorized)
        } catch {
            // Dependency failure and corrupt persistence are not evidence that
            // a caller's credential is invalid.
            throw Abort(.serviceUnavailable)
        }
    }
}

public struct V2AuthenticatedAccountMiddleware: AsyncMiddleware, Sendable {
    private let authenticator: any V2GatewayAuthenticator

    public init(authenticator: any V2GatewayAuthenticator) {
        self.authenticator = authenticator
    }

    public func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
        request.storage[V2AuthenticatedAccountIdentityStorageKey.self] = identity
        return try await next.respond(to: request)
    }
}

/// Cross-replica device budget for authenticated account endpoints. Costs are
/// endpoint based so batch and mutation surfaces cannot be amplified as one
/// cheap request. Domain-level cardinality bounds remain authoritative.
public struct V2AuthenticatedAccountRateLimitMiddleware: AsyncMiddleware, Sendable {
    private let limiter: any V2AuthenticatedAccountRateLimiting

    public init(limiter: any V2AuthenticatedAccountRateLimiting) {
        self.limiter = limiter
    }

    public func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard let identity = request.storage[V2AuthenticatedAccountIdentityStorageKey.self] else {
            throw Abort(.serviceUnavailable)
        }
        // Exact-handle resolution owns a stricter per-user anti-enumeration
        // budget in its domain store. Charging the generic per-device budget
        // as well would serialize two PostgreSQL counters for one lookup.
        guard let budget = Self.budget(for: request) else {
            return try await next.respond(to: request)
        }
        let result: V2AccountEdgeClientRateLimitResult
        do {
            result = try await limiter.consume(
                identity: identity,
                scope: budget.scope,
                cost: budget.cost
            )
        } catch {
            throw Abort(.serviceUnavailable)
        }
        switch result {
        case .allowed:
            return try await next.respond(to: request)
        case .rateLimited(let retryAfterSeconds):
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            headers.replaceOrAdd(name: "Retry-After", value: String(max(1, retryAfterSeconds)))
            return .init(status: .tooManyRequests, headers: headers)
        }
    }

    private static func budget(for request: Request) -> (scope: String, cost: Int)? {
        let path = request.url.path
        if path == "/v2/profile-views/batch" { return ("profile-views", 5) }
        if path.hasPrefix("/v2/media/") || path == "/v2/media/uploads" { return ("media", 5) }
        if path.hasPrefix("/v2/profile-presentations/") {
            guard request.method == .GET else { return ("profile-presentations", 4) }
            let limit = min(500, max(1, request.query[Int.self, at: "limit"] ?? 200))
            return ("profile-presentations", 1 + ((limit + 99) / 100))
        }
        if path == "/v2/profile/me" { return ("profile", request.method == .GET ? 1 : 3) }
        if path.hasPrefix("/v2/devices") {
            guard request.method == .GET else { return ("devices", 3) }
            let pageSize = min(100, max(1, request.query[Int.self, at: "page_size"] ?? 50))
            return ("devices", (pageSize + 49) / 50)
        }
        if path == "/v2/push-endpoint" || path.hasPrefix("/v2/push-endpoint/") {
            return ("push", request.method == .GET ? 1 : 3)
        }
        if path == "/v2/public-identities/resolve" { return nil }
        if path.hasPrefix("/v2/public-identities/") { return ("public-identities", 1) }
        return ("account", 1)
    }
}
