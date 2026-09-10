import IMV2Server
import Vapor

/// 账号边缘鉴权中间件。
///
/// 所有账户边缘路由保持 loopback-only，并通过 HTTPS 边缘注入额外签名头。
/// 边缘会先替换调用方可控的转发头，再补充这一证明，
/// 因此账号代码不能把一次直接的本地请求当作可信代理请求。
public struct V2AccountEdgeAuthenticationMiddleware: AsyncMiddleware, Sendable {
    public static let headerName = "X-IM-V2-Account-Edge-Authorization"
    public static let clientAddressHeaderName = "X-IM-V2-Account-Client-Address"

    private let secret: V2AccountEdgeAuthorizationSecret

    /// 初始化。
    public init(secret: V2AccountEdgeAuthorizationSecret) {
        self.secret = secret
    }

    /// 鉴权请求是否携带有效签名与客户端地址。
    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let proofValues = request.headers[Self.headerName]
        let addressValues = request.headers[Self.clientAddressHeaderName]
        guard proofValues.count == 1,
              addressValues.count == 1,
              secret.matches(base64EncodedCandidate: proofValues[0]),
              let address = try? V2AccountEdgeClientAddress(addressValues[0])
        else {
            throw Abort(.forbidden)
        }
        request.storage[V2AccountEdgeClientAddressStorageKey.self] = address
        return try await next.respond(to: request)
    }
}
