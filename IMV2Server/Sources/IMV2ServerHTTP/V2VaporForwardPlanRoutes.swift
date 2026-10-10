import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporForwardPlanRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let service:V2ForwardPlanService
    public init(authenticator:any V2GatewayAuthenticator,service:V2ForwardPlanService) { self.authenticator=authenticator;self.service=service }
    public func register(on routes:RoutesBuilder) {
        routes.on(.post,"v2","forward-plans","submit",maxBodySize:"64kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2ForwardPlanOperationCommand=try await v2DecodeOperationInput(request)
            guard actor.userID==command.actorUserID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await v2RespondOperation { try await service.submit(command) }
        }
        routes.on(.post,"v2","forward-plans","operations","recover",maxBodySize:"64kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2ForwardPlanRecoveryRequest=try await v2DecodeOperationInput(request)
            guard actor.userID==input.command.actorUserID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await v2RespondOperation { try await service.recover(input) }
        }
    }
}
