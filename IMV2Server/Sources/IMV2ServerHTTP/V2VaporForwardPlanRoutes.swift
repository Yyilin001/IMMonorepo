import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import Vapor

public struct V2VaporForwardPlanRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let service:V2ForwardPlanService
    public init(authenticator:any V2GatewayAuthenticator,service:V2ForwardPlanService) { self.authenticator=authenticator;self.service=service }
    public func register(on routes:RoutesBuilder) {
        routes.on(.post,"v2","forward-plans","submit",maxBodySize:"64kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2ForwardPlanOperationCommand=try await decode(request)
            guard actor.userID==command.actorUserID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await respond { try await service.submit(command) }
        }
        routes.on(.post,"v2","forward-plans","operations","recover",maxBodySize:"64kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2ForwardPlanRecoveryRequest=try await decode(request)
            guard actor.userID==input.command.actorUserID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            return try await respond { try await service.recover(input) }
        }
    }
    private func decode<T:Decodable>(_ request:Request) async throws -> T {
        do { return try await request.content.decode(T.self,using:JSONDecoder()) }
        catch { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
    }
    private func respond(_ operation:@Sendable () async throws -> V2ForwardPlanRecoveryResult) async throws -> Response {
        do {
            let result=try await operation()
            var headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]
            var status:HTTPResponse.Status = .ok
            if case .deferred(let hint)=result {
                status=hint.reason == .rateLimited ? .tooManyRequests:.serviceUnavailable
                if let ms=hint.retryAfterMilliseconds { headers[.retryAfter]=String((ms+999)/1000) }
            }
            return .init(status:status,headers:headers,body:.init(data:try JSONEncoder().encode(result)))
        } catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
    }
}
