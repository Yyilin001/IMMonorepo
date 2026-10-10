import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporGroupCapabilityRoutes: Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let rooms:any V2GroupCapabilityOperationHandling
    public init(authenticator:any V2GatewayAuthenticator,rooms:any V2GroupCapabilityOperationHandling) { self.authenticator=authenticator;self.rooms=rooms }
    public func register(on routes:RoutesBuilder) {
        routes.on(.post,"v2","rooms",":roomID","group-capability-operations","admissions",maxBodySize:"32kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupCapabilityIntent=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            do { return try v2EncodedOperationResponse(await rooms.admitGroupCapability(input)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","group-capability-operations","submit",maxBodySize:"32kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupCapabilityCommand=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            return try await v2RespondOperation { try await rooms.submitGroupCapability(input) }
        }
        routes.on(.post,"v2","rooms",":roomID","group-capability-operations","operations","recover",maxBodySize:"32kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupCapabilityRecoveryRequest=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            return try await v2RespondOperation { try await rooms.recoverGroupCapability(input) }
        }
        routes.get("v2","rooms",":roomID","messages",":messageID","pin-baseline") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            guard let rawRoom=request.parameters.get("roomID"),let room=UUID(uuidString:rawRoom),let rawMessage=request.parameters.get("messageID"),let message=UUID(uuidString:rawMessage) else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do { return try v2EncodedOperationResponse(await rooms.pinnedBaseline(actorUserID:actor.userID,roomID:.init(uuid:room),messageID:.init(uuid:message))) }
            catch V2GroupCapabilitiesStoreError.actorNotAuthorized { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch V2GroupCapabilitiesStoreError.actorNotMember { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch V2GroupCapabilitiesStoreError.messageWithdrawn { throw Abort(.gone,headers:[.cacheControl:"no-store"]) }
            catch V2GroupCapabilitiesStoreError.messageNotFound { throw Abort(.notFound,headers:[.cacheControl:"no-store"]) }
            catch V2GroupCapabilitiesStoreError.roomNotFound { throw Abort(.notFound,headers:[.cacheControl:"no-store"]) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
    }
    private func authorize(_ request:Request,actor:UserID,identity:V2OperationIdentity) throws {
        let scoped:RoomID
        switch identity.scope { case .room(let room),.message(let room,_):scoped=room;default:throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
        guard let raw=request.parameters.get("roomID"),let uuid=UUID(uuidString:raw),scoped==RoomID(uuid:uuid),actor==identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
}
