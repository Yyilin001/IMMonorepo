import IMV2Server
import Vapor

/// 账户边缘客户端速率限制中间件。
///
/// 在 `V2AccountEdgeAuthenticationMiddleware` 之后执行。
/// 未携带由边缘注入且合法的客户端地址时会被拒绝。
public struct V2AccountEdgeClientRateLimitMiddleware: AsyncMiddleware, Sendable {
    private let limiter: any V2AccountEdgeClientRateLimiting
    private let limitedPaths: Set<String>?

    /// 初始化。
    ///
    /// - Parameters:
    ///   - limiter: 速率限制器。
    ///   - limitedPaths: 仅限制这些路径；传 `nil` 表示所有路径都限制。
    public init(limiter: any V2AccountEdgeClientRateLimiting, limitedPaths: Set<String>? = nil) {
        self.limiter = limiter
        self.limitedPaths = limitedPaths
    }

    /// 先执行速率预检，超限时返回 429 + Retry-After。
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
