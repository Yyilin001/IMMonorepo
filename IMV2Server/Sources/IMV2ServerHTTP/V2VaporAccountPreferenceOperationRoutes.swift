import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import Vapor

public struct V2VaporAccountPreferenceOperationRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let store:PostgresV2AccountPreferenceOperationStore
    private let now:@Sendable ()->Date
    public init(authenticator:any V2GatewayAuthenticator,store:PostgresV2AccountPreferenceOperationStore,now:@escaping @Sendable ()->Date=Date.init) { self.authenticator=authenticator;self.store=store;self.now=now }
    public func register(on routes:RoutesBuilder) {
        routes.get("v2","account-preferences",":kind","baseline") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            guard let raw=request.parameters.get("kind"),let kind=V2OperationKind(rawValue:raw),[.strangerMessagePreference,.userAddPreference,.readReceiptPreference,.liveActivityPreference].contains(kind) else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do { return try encoded(await store.snapshot(ownerUserID:actor.userID,kind:kind)) }
            catch V2SocialRelationshipStoreError.actorInactive { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","account-preferences","operations","submit",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2AccountPreferenceCommand=try await decode(request)
            guard actor.userID==command.identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await respond { try await store.submit(command,now:now()) }
        }
        routes.on(.post,"v2","account-preferences","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let recovery:V2AccountPreferenceRecoveryRequest=try await decode(request)
            guard actor.userID==recovery.identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await respond { try await store.recover(recovery,now:now()) }
        }
    }
    private func decode<T:Decodable>(_ request:Request) async throws -> T {
        do { return try await request.content.decode(T.self,using:JSONDecoder()) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
    }
    private func encoded<T:Encodable>(_ value:T,status:HTTPResponse.Status = .ok,headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]) throws -> Response {
        .init(status:status,headers:headers,body:.init(data:try JSONEncoder().encode(value)))
    }
    private func respond(_ operation:@Sendable () async throws -> V2AccountPreferenceRecoveryResult) async throws -> Response {
        do {
            let result=try await operation()
            var headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]
            var status:HTTPResponse.Status = .ok
            if case .deferred(let hint)=result {
                status=hint.reason == .rateLimited ? .tooManyRequests:.serviceUnavailable
                if let ms=hint.retryAfterMilliseconds { headers[.retryAfter]=String((ms+999)/1000) }
            }
            return try encoded(result,status:status,headers:headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
    }
}
