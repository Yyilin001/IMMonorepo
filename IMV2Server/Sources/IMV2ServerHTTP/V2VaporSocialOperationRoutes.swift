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
            do { return try encoded(await store.loadSocialOperationSnapshot(actorUserID:actor.userID,targetUserID:.init(uuid:uuid))) }
            catch V2HTTPOperationError.actorInactive { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","social","operations","submit",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2SocialOperationCommand=try await decode(request)
            guard actor.userID==command.actorUserID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await respond { try await store.submitSocialOperation(command,now:now()) }
        }
        routes.on(.post,"v2","social","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let recovery:V2SocialOperationRecoveryRequest=try await decode(request)
            guard actor.userID==recovery.identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await respond { try await store.recoverSocialOperation(recovery,now:now()) }
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
    private func respond(_ operation:@Sendable () async throws -> V2SocialOperationRecoveryResult) async throws -> Response {
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
