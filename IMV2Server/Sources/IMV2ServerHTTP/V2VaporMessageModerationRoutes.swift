import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporMessageModerationRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let rooms:any V2MessageModerationOperationHandling
    public init(authenticator:any V2GatewayAuthenticator,rooms:any V2MessageModerationOperationHandling) { self.authenticator=authenticator;self.rooms=rooms }
    public func register(on routes:RoutesBuilder) {
        routes.get("v2","rooms",":roomID","messages",":messageID","moderation-baseline") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            guard let raw=request.parameters.get("roomID"),let room=UUID(uuidString:raw),let messageRaw=request.parameters.get("messageID"),let message=UUID(uuidString:messageRaw) else {throw Abort(.badRequest,headers:[.cacheControl:"no-store"])}
            do {return try v2EncodedOperationResponse(await rooms.messageModerationBaseline(.init(roomID:.init(uuid:room),actorUserID:actor.userID,messageID:.init(uuid:message))),status:.ok)}
            catch V2ModerationStoreError.actorNotAuthorized {throw Abort(.forbidden,headers:[.cacheControl:"no-store"])}
            catch is CancellationError { throw CancellationError() }
            catch {throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"])}
        }

        routes.on(.post,"v2","rooms",":roomID","message-moderation-operations","admissions",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MessageModerationIntent=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:try input.identity)
            guard input.messageID.uuidValue != nil else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do { return try v2EncodedOperationResponse(await rooms.admitMessageModeration(input),status:.ok) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","message-moderation-operations","submit",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MessageModerationCommand=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:try input.identity)
            guard input.intent.messageID.uuidValue != nil else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            return try await v2RespondOperation { try await rooms.submitMessageModeration(input) }
        }
        routes.on(.post,"v2","rooms",":roomID","message-moderation-operations","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MessageModerationRecoveryRequest=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:try input.intent.identity)
            return try await v2RespondOperation { try await rooms.recoverMessageModeration(input) }
        }
    }
    private func authorize(_ request:Request,actor:UserID,identity:V2OperationIdentity) throws {
        guard let raw=request.parameters.get("roomID"),let uuid=UUID(uuidString:raw),case .room(let room)=identity.scope,
            room==RoomID(uuid:uuid),actor==identity.accountID,UUID(uuidString:identity.operation.rawOperationID) != nil else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
}
