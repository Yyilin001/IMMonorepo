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
            let input:V2GroupCapabilityIntent=try await decode(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            do { return try encoded(await rooms.admitGroupCapability(input)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","group-capability-operations","submit",maxBodySize:"32kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupCapabilityCommand=try await decode(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            return try await respond { try await rooms.submitGroupCapability(input) }
        }
        routes.on(.post,"v2","rooms",":roomID","group-capability-operations","operations","recover",maxBodySize:"32kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupCapabilityRecoveryRequest=try await decode(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            return try await respond { try await rooms.recoverGroupCapability(input) }
        }
        routes.get("v2","rooms",":roomID","messages",":messageID","pin-baseline") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            guard let rawRoom=request.parameters.get("roomID"),let room=UUID(uuidString:rawRoom),let rawMessage=request.parameters.get("messageID"),let message=UUID(uuidString:rawMessage) else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do { return try encoded(await rooms.pinnedBaseline(actorUserID:actor.userID,roomID:.init(uuid:room),messageID:.init(uuid:message))) }
            catch V2GroupCapabilitiesStoreError.actorNotAuthorized { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch V2GroupCapabilitiesStoreError.actorNotMember { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch V2GroupCapabilitiesStoreError.messageWithdrawn { throw Abort(.gone,headers:[.cacheControl:"no-store"]) }
            catch V2GroupCapabilitiesStoreError.messageNotFound { throw Abort(.notFound,headers:[.cacheControl:"no-store"]) }
            catch V2GroupCapabilitiesStoreError.roomNotFound { throw Abort(.notFound,headers:[.cacheControl:"no-store"]) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
    }
    private func decode<T:Decodable>(_ request:Request) async throws -> T {
        do { return try await request.content.decode(T.self,using:JSONDecoder()) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
    }
    private func authorize(_ request:Request,actor:UserID,identity:V2OperationIdentity) throws {
        let scoped:RoomID
        switch identity.scope { case .room(let room),.message(let room,_):scoped=room;default:throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
        guard let raw=request.parameters.get("roomID"),let uuid=UUID(uuidString:raw),scoped==RoomID(uuid:uuid),actor==identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
    private func encoded<T:Encodable>(_ value:T,status:HTTPResponse.Status = .ok,headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]) throws -> Response {
        .init(status:status,headers:headers,body:.init(data:try JSONEncoder().encode(value)))
    }
    private func respond(_ operation:() async throws -> V2GroupCapabilityRecoveryResult) async throws -> Response {
        do {
            let result=try await operation();var headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]
            var status:HTTPResponse.Status = .ok
            if case .deferred(let hint)=result {
                status=hint.reason == .rateLimited ? .tooManyRequests:.serviceUnavailable
                if let delay=hint.retryAfterMilliseconds { headers[.retryAfter]=String((delay+999)/1000) }
            }
            return try encoded(result,status:status,headers:headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
    }
}
