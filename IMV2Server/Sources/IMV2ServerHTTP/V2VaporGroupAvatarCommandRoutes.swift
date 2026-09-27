import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import Vapor

public struct V2VaporGroupAvatarCommandRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let service: V2ResourceGroupAvatarCommandService
    public init(authenticator: any V2GatewayAuthenticator, service: V2ResourceGroupAvatarCommandService) {
        self.authenticator = authenticator; self.service = service
    }
    public func register(on routes: RoutesBuilder) {
        routes.on(.post, "v2", "rooms", ":roomID", "avatar", maxBodySize: "8kb") { request async throws -> Response in
            let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            guard let raw = request.parameters.get("roomID"), let room = UUID(uuidString: raw) else { throw Abort(.badRequest) }
            // Middleware/test transports can have collected the body under a larger
            // limit already. Enforce this endpoint's bound on that path as well.
            guard let bytes = try await request.body.collect() else { throw Abort(.badRequest) }
            guard bytes.count <= 8 * 1_024 else { throw Abort(.contentTooLarge) }
            let command: V2GroupAvatarCommand
            do { command = try await request.content.decode(V2GroupAvatarCommand.self, using: JSONDecoder()) }
            catch let error as any AbortError where error.status == .contentTooLarge { throw error }
            catch { throw Abort(.badRequest) }
            guard command.roomID.uuidValue == room else { throw Abort(.badRequest) }
            var headers = HTTPFields()
            headers[.contentType] = "application/json"; headers[.cacheControl] = "no-store"
            do {
                let value = try await service.execute(command, actorUserID: identity.userID, deviceID: identity.deviceID)
                let status: HTTPResponse.Status
                switch value.outcome {
                case .committed: status = .ok
                case .revisionConflict, .idempotencyConflict: status = .conflict
                case .resourceUnavailable: status = .unprocessableContent
                case .forbidden: status = .forbidden
                }
                return .init(status: status, headers: headers, body: .init(data: try JSONEncoder().encode(value)))
            } catch V2GroupCapabilitiesStoreError.operationClosed { throw Abort(.gone, headers: headers)
            } catch V2MediaStoreError.uploadNotAuthorized { throw Abort(.forbidden, headers: headers)
            } catch V2ResourceProviderError.throttled(let retryAfter) {
                headers[.retryAfter] = String(Int(min(60, max(1, retryAfter.isFinite ? retryAfter : 1)).rounded(.up)))
                throw Abort(.tooManyRequests, headers: headers)
            } catch { throw Abort(.serviceUnavailable, headers: headers) }
        }
    }
}
