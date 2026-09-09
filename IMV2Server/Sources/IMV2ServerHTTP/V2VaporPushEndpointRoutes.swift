import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2PushEndpointHTTPRequest: Content, Sendable {
    public let provider: V2PushEndpointProvider
    public let environment: V2PushEndpointEnvironment
    public let token: String

    public init(provider: V2PushEndpointProvider, environment: V2PushEndpointEnvironment, token: String) {
        self.provider = provider
        self.environment = environment
        self.token = token
    }
}

/// Authenticated account-edge routes for device-owned Push endpoints. These
/// routes intentionally return no endpoint material and use no-store headers;
/// a client can register or delete only the endpoint bound to its bearer/device
/// pair.
public struct V2VaporPushEndpointRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let store: any V2PushDeviceEndpointStore
    private let now: @Sendable () -> Date

    public init(
        authenticator: any V2GatewayAuthenticator,
        store: any V2PushDeviceEndpointStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authenticator = authenticator
        self.store = store
        self.now = now
    }

    public func register(on routes: RoutesBuilder) {
        routes.put("v2", "push-endpoint") { request async throws -> Response in
            let identity = try await authenticate(request)
            let input = try request.content.decode(V2PushEndpointHTTPRequest.self)
            let endpoint: V2PushDeviceEndpointRegistration
            do {
                endpoint = try .init(provider: input.provider, environment: input.environment, token: input.token)
                try await store.register(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    endpoint: endpoint,
                    now: now()
                )
            } catch { return v2PushIntentErrorResponse(error) }
            return noStoreNoContent()
        }

        routes.delete("v2", "push-endpoint") { request async throws -> Response in
            let identity = try await authenticate(request)
            do {
                try await store.disableOwnedEndpoint(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    now: now()
                )
            } catch { return v2PushIntentErrorResponse(error) }
            return noStoreNoContent()
        }
    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    private func noStoreNoContent() -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .noContent, headers: headers)
    }
}
