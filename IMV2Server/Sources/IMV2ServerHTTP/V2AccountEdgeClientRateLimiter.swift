import IMV2Server
import Vapor

/// Runs after `V2AccountEdgeAuthenticationMiddleware`. A route cannot reach
/// bcrypt, token parsing, or database business logic unless Caddy both proves
/// itself and supplies one syntactically valid client address.
public struct V2AccountEdgeClientRateLimitMiddleware: AsyncMiddleware, Sendable {
    private let limiter: any V2AccountEdgeClientRateLimiting
    private let limitedPaths: Set<String>?

    /// `nil` preserves an all-route policy for focused tests or deployments.
    /// Production supplies only unauthenticated credential-issuance paths.
    public init(limiter: any V2AccountEdgeClientRateLimiting, limitedPaths: Set<String>? = nil) {
        self.limiter = limiter
        self.limitedPaths = limitedPaths
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if let limitedPaths, !limitedPaths.contains(request.url.path) {
            return try await next.respond(to: request)
        }
        guard let address = request.storage[V2AccountEdgeClientAddressStorageKey.self] else {
            throw Abort(.forbidden)
        }
        let result: V2AccountEdgeClientRateLimitResult
        do {
            result = try await limiter.consume(address: address)
        } catch is V2AccountEdgeClientRateLimitError {
            throw Abort(.serviceUnavailable)
        } catch {
            throw Abort(.serviceUnavailable)
        }
        switch result {
        case .allowed:
            // Deliberately outside the persistence-error mapping: a route's
            // public 4xx/5xx contract must retain its original status.
            return try await next.respond(to: request)
        case .rateLimited(let retryAfterSeconds):
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            headers.replaceOrAdd(name: "Retry-After", value: String(retryAfterSeconds))
            return .init(status: .tooManyRequests, headers: headers)
        }
    }
}

struct V2AccountEdgeClientAddressStorageKey: StorageKey {
    typealias Value = V2AccountEdgeClientAddress
}
