import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import Vapor
import HTTPTypes

public struct V2VaporResourceImportRoutes:Sendable {
    let authenticator:any V2GatewayAuthenticator
    let service:V2ResourceImportService
    public init(authenticator:any V2GatewayAuthenticator,service:V2ResourceImportService) {self.authenticator=authenticator;self.service=service}
    public func register(on routes:RoutesBuilder) {
        routes.post("v2","resource-imports") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let value=try await request.content.decode(V2ResourceImportRequest.self,using:JSONDecoder())
            return try await respond { try await service.create(value,actor:actor.userID,device:actor.deviceID) }
        }
        routes.post("v2","resource-imports","status") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let value=try await request.content.decode(V2ResourceImportLocator.self,using:JSONDecoder())
            return try await respond { try await service.status(value,actor:actor.userID,device:actor.deviceID) }
        }
        routes.post("v2","resource-imports","cancel") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let value=try await request.content.decode(V2ResourceImportLocator.self,using:JSONDecoder())
            return try await respond { try await service.cancel(value,actor:actor.userID,device:actor.deviceID) }
        }
    }
    private func respond(_ body:@Sendable () async throws -> V2ResourceImportStatus) async throws -> Response {
        do {
            let value=try await body();var headers=HTTPFields()
            headers[.contentType]="application/json";headers[.cacheControl]="no-store";headers[.v2Pragma]="no-cache"
            return .init(status:.ok,headers:headers,body:.init(data:try JSONEncoder().encode(value)))
        } catch V2MediaStoreError.idempotencyConflict {throw Abort(.conflict)
        } catch is V2MediaStoreError {throw Abort(.notFound)
        } catch V2ResourceProviderError.preconditionFailed {throw Abort(.conflict)
        } catch V2ResourceProviderError.notFound {throw Abort(.notFound)
        } catch {throw Abort(.serviceUnavailable)}
    }
}
