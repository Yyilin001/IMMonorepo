import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes

public struct V2VaporResourceRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let service: V2ResourceService
    public init(authenticator: any V2GatewayAuthenticator, service: V2ResourceService) {
        self.authenticator = authenticator; self.service = service
    }
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "resource-capabilities") { request async throws -> Response in
            _ = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            var headers = HTTPFields()
            headers[.contentType] = "application/json"; headers[.cacheControl] = "no-store"
            return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(service.capabilities())))
        }
        routes.post("v2", "resource-uploads") { request async throws -> Response in
            try await respond(request, V2ResourceUploadRequest.self) { input, identity in
                try await service.create(input, actor: identity.userID, device: identity.deviceID)
            }
        }
        routes.post("v2", "resource-uploads", "status") { request async throws -> Response in
            try await respond(request, V2ResourceUploadLocator.self) { input, identity in
                try await service.status(input, actor: identity.userID, device: identity.deviceID)
            }
        }
        routes.post("v2", "resource-uploads", "targets") { request async throws -> Response in
            try await respond(request, V2ResourceUploadTargetsRequest.self) { input, identity in
                try await service.targets(input, actor: identity.userID, device: identity.deviceID)
            }
        }
        routes.post("v2", "resource-uploads", "finalize") { request async throws -> Response in
            try await respond(request, V2ResourceUploadFinalizeRequest.self) { input, identity in
                try await service.finalize(input, actor: identity.userID, device: identity.deviceID)
            }
        }
        routes.post("v2", "resource-uploads", "cancel") { request async throws -> Response in
            try await respond(request, V2ResourceUploadCancelRequest.self) { input, identity in
                try await service.cancel(input, actor: identity.userID, device: identity.deviceID)
            }
        }
    }
    private func respond<Input: Decodable & Sendable, Output: Encodable & Sendable>(_ request: Request, _ type: Input.Type,
        body: @Sendable (Input, V2AuthenticatedConnection) async throws -> Output) async throws -> Response {
        let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
        do {
            let input = try await request.content.decode(Input.self, using: JSONDecoder())
            let result = try await body(input, identity)
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[.cacheControl] = "no-store"
            headers[.v2Pragma] = "no-cache"
            return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(result)))
        } catch is DecodingError { throw Abort(.badRequest)
        } catch is V2ResourceValidationError { throw Abort(.badRequest)
        } catch V2MediaStoreError.idempotencyConflict { throw Abort(.conflict)
        } catch is V2MediaStoreError { throw Abort(.notFound)
        } catch V2ResourceProviderError.preconditionFailed { throw Abort(.conflict)
        } catch V2ResourceProviderError.integrityMismatch { throw Abort(.unprocessableContent)
        } catch V2ResourceProviderError.unsupportedCapability { throw Abort(.unprocessableContent)
        } catch V2ResourceProviderError.throttled { throw Abort(.tooManyRequests)
        } catch { throw Abort(.serviceUnavailable) }
    }
}
