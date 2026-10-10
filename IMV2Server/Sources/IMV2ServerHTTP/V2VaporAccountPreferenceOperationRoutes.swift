import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporAccountPreferenceOperationRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let store:any V2AccountPreferenceOperationHandling
    private let now:@Sendable ()->Date
    public init(authenticator:any V2GatewayAuthenticator,store:any V2AccountPreferenceOperationHandling,now:@escaping @Sendable ()->Date=Date.init) { self.authenticator=authenticator;self.store=store;self.now=now }
    public func register(on routes:RoutesBuilder) {
        routes.get("v2","account-preferences",":kind","baseline") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            guard let raw=request.parameters.get("kind"),let kind=V2OperationKind(rawValue:raw),[.strangerMessagePreference,.userAddPreference,.readReceiptPreference,.liveActivityPreference].contains(kind) else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do { return try v2EncodedOperationResponse(await store.loadAccountPreferenceSnapshot(ownerUserID:actor.userID,kind:kind)) }
            catch V2HTTPOperationError.actorInactive { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","account-preferences","operations","submit",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2AccountPreferenceCommand=try await v2DecodeOperationInput(request)
            guard actor.userID==command.identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await v2RespondOperation { try await store.submit(command,now:now()) }
        }
        routes.on(.post,"v2","account-preferences","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let recovery:V2AccountPreferenceRecoveryRequest=try await v2DecodeOperationInput(request)
            guard actor.userID==recovery.identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await v2RespondOperation { try await store.recover(recovery,now:now()) }
        }
    }
}
