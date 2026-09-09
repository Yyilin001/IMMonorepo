import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// Vapor transport adapter for the independently authenticated media edge.
/// It deliberately delegates all content authorization to the V2 service and
/// returns the same opaque 404 for unavailable and unauthorized media.
public struct V2VaporMediaEdgeRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let handler: V2MediaEdgeHTTPHandler

    public init(authenticator: any V2GatewayAuthenticator, handler: V2MediaEdgeHTTPHandler) {
        self.authenticator = authenticator
        self.handler = handler
    }

    /// Registers `GET /v2/media/{mediaID}`. Deployment must mount this on the
    /// dedicated media-edge listener, rather than the realtime TLS port.
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "media", ":mediaID") { request async throws -> Response in
            let identity = try await authenticate(request)
            guard let rawMediaID = request.parameters.get("mediaID") else {
                throw Abort(.badRequest)
            }
            let target: V2MediaDownloadTargetEnvelope
            do {
                target = try await handler.downloadTarget(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    rawMediaID: rawMediaID,
                    rawRoomID: request.query[String.self, at: "room_id"],
                    rawMessageID: request.query[String.self, at: "message_id"]
                )
            } catch let error as V2MediaEdgeHTTPHandlerError {
                switch error {
                case .invalidMediaID, .invalidMessageLocation:
                    throw Abort(.badRequest)
                case .invalidProviderTarget, .messageOwnerUnavailable:
                    throw Abort(.serviceUnavailable)
                }
            } catch is V2MediaStoreError {
                // Do not distinguish a non-existent object from one this
                // authenticated caller may no longer access.
                throw Abort(.notFound)
            } catch is V2MediaDownloadSessionStoreError {
                throw Abort(.notFound)
            } catch is V2MediaProviderSessionError {
                throw Abort(.serviceUnavailable)
            } catch {
                // Provider and database implementation failures must not
                // surface their detail or object identifiers to clients.
                throw Abort(.serviceUnavailable)
            }
            return try makeNoStoreJSONResponse(target)
        }
    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    private func makeNoStoreJSONResponse(_ target: V2MediaDownloadTargetEnvelope) throws -> Response {
        let data = try JSONEncoder().encode(target)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}
