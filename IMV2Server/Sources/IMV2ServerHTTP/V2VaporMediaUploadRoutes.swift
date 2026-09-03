import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2MediaUploadTargetHTTPRequest: Content, Sendable {
    public let operationID: String
    public let mediaID: String
    public let contentType: String
    public let byteCount: Int64

    public init(operationID: String, mediaID: String, contentType: String, byteCount: Int64) {
        self.operationID = operationID
        self.mediaID = mediaID
        self.contentType = contentType
        self.byteCount = byteCount
    }
}

/// Vapor transport adapter for the authenticated upload media edge. Deploy it
/// on the dedicated media listener with endpoint-specific rate limits; it
/// accepts no provider target from a client and returns a target only in an
/// ephemeral no-store response.
public struct V2VaporMediaUploadRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let handler: V2MediaEdgeUploadHTTPHandler

    public init(authenticator: any V2GatewayAuthenticator, handler: V2MediaEdgeUploadHTTPHandler) {
        self.authenticator = authenticator
        self.handler = handler
    }

    /// Registers `POST /v2/media/uploads` and
    /// `POST /v2/media/{mediaID}/complete`, and
    /// `GET /v2/media/{mediaID}/upload-status`.
    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "media", "uploads") { request async throws -> Response in
            let identity = try await authenticate(request)
            let input = try request.content.decode(V2MediaUploadTargetHTTPRequest.self)
            let target: V2MediaUploadTargetEnvelope
            do {
                target = try await handler.uploadTarget(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    rawOperationID: input.operationID,
                    rawMediaID: input.mediaID,
                    contentType: input.contentType,
                    byteCount: input.byteCount
                )
            } catch let error as V2MediaEdgeUploadHTTPHandlerError {
                switch error {
                case .invalidIdentifier: throw Abort(.badRequest)
                case .invalidProviderTarget: throw Abort(.serviceUnavailable)
                }
            } catch is V2MediaValidationError {
                throw Abort(.badRequest)
            } catch V2MediaStoreError.idempotencyConflict {
                throw Abort(.conflict)
            } catch is V2MediaStoreError {
                throw Abort(.forbidden)
            } catch is V2MediaUploadSessionStoreError {
                throw Abort(.conflict)
            } catch is V2MediaUploadProviderSessionError {
                throw Abort(.serviceUnavailable)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            return try noStoreJSONResponse(target)
        }

        routes.post("v2", "media", ":mediaID", "complete") { request async throws -> Response in
            let identity = try await authenticate(request)
            guard let rawMediaID = request.parameters.get("mediaID") else { throw Abort(.badRequest) }
            do {
                try await handler.uploadCompleted(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    rawMediaID: rawMediaID
                )
            } catch let error as V2MediaEdgeUploadHTTPHandlerError {
                switch error {
                case .invalidIdentifier: throw Abort(.badRequest)
                case .invalidProviderTarget: throw Abort(.serviceUnavailable)
                }
            } catch is V2MediaStoreError {
                // Do not reveal whether the caller named a real object or a
                // session belonging to a different account/device.
                throw Abort(.notFound)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            return .init(status: .noContent, headers: headers)
        }

        routes.get("v2", "media", ":mediaID", "upload-status") { request async throws -> Response in
            let identity = try await authenticate(request)
            guard let rawMediaID = request.parameters.get("mediaID") else { throw Abort(.badRequest) }
            let status: V2MediaUploadStatusEnvelope
            do {
                status = try await handler.uploadStatus(
                    actorUserID: identity.userID,
                    deviceID: identity.deviceID,
                    rawMediaID: rawMediaID
                )
            } catch V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier {
                throw Abort(.badRequest)
            } catch is V2MediaStoreError {
                throw Abort(.notFound)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            return try noStoreJSONResponse(status)
        }
    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    private func noStoreJSONResponse<Payload: Encodable>(_ payload: Payload) throws -> Response {
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}
