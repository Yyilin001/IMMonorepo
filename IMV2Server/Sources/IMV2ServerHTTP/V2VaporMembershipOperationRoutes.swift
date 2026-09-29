import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporMembershipOperationRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let rooms:any V2MembershipOperationHandling
    public init(authenticator:any V2GatewayAuthenticator,rooms:any V2MembershipOperationHandling) { self.authenticator=authenticator;self.rooms=rooms }
    public func register(on routes:RoutesBuilder) {
        routes.on(.post,"v2","rooms",":roomID","membership","admissions",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MembershipIntent=try await decode(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            guard input.targetUserID.uuidValue != nil else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do { return try encoded(await rooms.admitMembershipOperation(input),status:.ok) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","membership","submit",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MembershipOperationCommand=try await decode(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            guard input.intent.targetUserID.uuidValue != nil else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            return try await respond { try await rooms.submitMembershipOperation(input) }
        }
        routes.on(.post,"v2","rooms",":roomID","membership","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MembershipRecoveryRequest=try await decode(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            return try await respond { try await rooms.recoverMembershipOperation(input) }
        }
    }
    private func decode<T:Decodable>(_ request:Request) async throws -> T {
        do { return try await request.content.decode(T.self,using:JSONDecoder()) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
    }
    private func authorize(_ request:Request,actor:UserID,identity:V2OperationIdentity) throws {
        guard let raw=request.parameters.get("roomID"),let uuid=UUID(uuidString:raw),case .room(let room)=identity.scope,
            room==RoomID(uuid:uuid),actor==identity.accountID,UUID(uuidString:identity.operation.rawOperationID) != nil else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
    private func encoded<T:Encodable>(_ value:T,status:HTTPResponse.Status,headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]) throws -> Response {
        .init(status:status,headers:headers,body:.init(data:try JSONEncoder().encode(value)))
    }
    private func respond(_ operation:@Sendable () async throws -> V2MembershipRecoveryResult) async throws -> Response {
        do {
            let result=try await operation()
            var headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]
            var status:HTTPResponse.Status = .ok
            if case .deferred(let hint)=result {
                status=hint.reason == .rateLimited ? .tooManyRequests : .serviceUnavailable
                if let milliseconds=hint.retryAfterMilliseconds { headers[.retryAfter]=String((milliseconds+999)/1000) }
            }
            return try encoded(result,status:status,headers:headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
    }
}
