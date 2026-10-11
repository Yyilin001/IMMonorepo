import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporSocialOperationRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let store:any V2SocialOperationHandling
    private let now:@Sendable ()->Date
    public init(authenticator:any V2GatewayAuthenticator,store:any V2SocialOperationHandling,now:@escaping @Sendable ()->Date=Date.init) { self.authenticator=authenticator;self.store=store;self.now=now }
    public func register(on routes:RoutesBuilder) {
        routes.get("v2","social","targets",":targetUserID","baseline") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            guard let raw=request.parameters.get("targetUserID"),let uuid=UUID(uuidString:raw),actor.userID != UserID(uuid:uuid) else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do { return try v2EncodedOperationResponse(await store.loadSocialOperationSnapshot(actorUserID:actor.userID,targetUserID:.init(uuid:uuid))) }
            catch V2HTTPOperationError.actorInactive { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","social","operations","submit",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2SocialOperationCommand=try await v2DecodeOperationInput(request)
            guard actor.userID==command.actorUserID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await v2RespondOperation { try await store.submitSocialOperation(command) }
        }
        routes.on(.post,"v2","social","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let recovery:V2SocialOperationRecoveryRequest=try await v2DecodeOperationInput(request)
            guard actor.userID==recovery.identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await v2RespondOperation { try await store.recoverSocialOperation(recovery,now:now()) }
        }
    }
}
