import IMV2ServerApplication
import IMV2ServerContracts
import Vapor
import HTTPTypes

/// 账户边缘客户端速率限制中间件。
///
/// 在 `V2AccountEdgeAuthenticationMiddleware` 之后执行。
/// 未携带由边缘注入且合法的客户端地址时会被拒绝。
public struct V2AccountEdgeClientRateLimitMiddleware: Middleware, Sendable {
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
    public func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        if let limitedPaths, !limitedPaths.contains(request.url.path) {
            return try await next.respond(to: request)
        }
        guard let address = request.auth.get(V2AccountEdgeAuthenticatedAddress.self)?.address else {
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
            // 此处有意置于持久化错误映射之外：路由公开的 4xx／5xx 契约
            // 必须保留原始状态码。
            return try await next.respond(to: request)
        case .rateLimited(let retryAfterSeconds):
            var headers = HTTPFields()
            headers[.cacheControl] = "no-store"
            headers[.v2Pragma] = "no-cache"
            headers[.retryAfter] = String(retryAfterSeconds)
            return .init(status: .tooManyRequests, headers: headers)
        }
    }
}

struct V2AccountEdgeAuthenticatedAddress: Authenticatable {
    let address: V2AccountEdgeClientAddress
}
