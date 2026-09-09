import IMV2Server
import Vapor

/// All account routes remain loopback-only and require an additional secret
/// injected by the HTTPS edge. The edge replaces caller-controlled forwarding
/// headers before it adds this proof, so account code cannot treat a direct
/// local request as a trusted proxy request.
///
/// 所有账户边缘路由保持 loopback-only，并通过 HTTPS 边缘注入额外签名头。
/// 边缘会先清理调用方可控转发头，再补充该签名。
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
