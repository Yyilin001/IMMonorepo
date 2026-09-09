import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension V2HTTPPushEndpointClient {
    /// Bind Push operations, including their HTTP failures, to one account
    /// lifetime. Logout creates a separate client for its cleanup epoch.
    public init(endpoint: URL, session: V2AuthSession, epoch: V2AuthSessionEpoch,
                transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()) throws {
        let authorization = V2SessionHTTPAuthorization(
            session: session, epoch: epoch, transport: V2PushAuthorizationTransport(base: transport)
        )
        try self.init(endpoint: endpoint, credentials: authorization, transport: authorization)
    }
}

private struct V2PushAuthorizationTransport: V2AuthHTTPTransport {
    let base: any V2ClientPushEndpointHTTPTransport
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await base.data(for: request)
    }
}
