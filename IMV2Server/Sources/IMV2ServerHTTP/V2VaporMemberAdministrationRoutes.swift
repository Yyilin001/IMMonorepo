import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporMemberAdministrationRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let rooms:any V2MemberAdministrationOperationHandling
    public init(authenticator:any V2GatewayAuthenticator,rooms:any V2MemberAdministrationOperationHandling) { self.authenticator=authenticator;self.rooms=rooms }
    public func register(on routes:RoutesBuilder) {
        routes.on(.post,"v2","rooms",":roomID","member-administration","admissions",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MemberAdministrationIntent=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            guard input.targetUserID.uuidValue != nil else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do { return try v2EncodedOperationResponse(await rooms.admitMemberAdministration(input),status:.ok) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","member-administration","submit",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MemberAdministrationCommand=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            guard input.intent.targetUserID.uuidValue != nil else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            return try await v2RespondOperation { try await rooms.submitMemberAdministration(input) }
        }
        routes.on(.post,"v2","rooms",":roomID","member-administration","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MemberAdministrationRecoveryRequest=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            return try await v2RespondOperation { try await rooms.recoverMemberAdministration(input) }
        }
    }
    private func authorize(_ request:Request,actor:UserID,identity:V2OperationIdentity) throws {
        guard let raw=request.parameters.get("roomID"),let uuid=UUID(uuidString:raw),case .room(let room)=identity.scope,
            room==RoomID(uuid:uuid),actor==identity.accountID,UUID(uuidString:identity.operation.rawOperationID) != nil else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
}
