import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporMessageMutationOperationRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let messages:any V2MessageMutationOperationHandling
    public init(authenticator:any V2GatewayAuthenticator,messages:any V2MessageMutationOperationHandling) { self.authenticator=authenticator;self.messages=messages }
    public func register(on routes:RoutesBuilder) {
        routes.on(.post,"v2","rooms",":roomID","message-mutations","edit",maxBodySize:"1mb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2MessageEditOperationCommand=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:command.identity)
            return try await v2RespondOperation { try await messages.editOperation(command) }
        }
        routes.on(.post,"v2","rooms",":roomID","message-mutations","withdraw",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2MessageWithdrawalOperationCommand=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:command.identity)
            return try await v2RespondOperation { try await messages.withdrawOperation(command) }
        }
        routes.on(.post,"v2","rooms",":roomID","message-mutations","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MessageMutationRecoveryRequest=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            return try await v2RespondOperation { try await messages.recoverMutation(input) }
        }
    }
    private func authorize(_ request:Request,actor:UserID,identity:V2OperationIdentity) throws {
        guard let raw=request.parameters.get("roomID"),let uuid=UUID(uuidString:raw),
            case .message(let room,_)=identity.scope,room==RoomID(uuid:uuid),actor==identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
}
