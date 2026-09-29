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
            do {return try encoded(await rooms.messageModerationBaseline(.init(roomID:.init(uuid:room),actorUserID:actor.userID,messageID:.init(uuid:message))),status:.ok)}
            catch V2ModerationStoreError.actorNotAuthorized {throw Abort(.forbidden,headers:[.cacheControl:"no-store"])}
            catch is CancellationError { throw CancellationError() }
            catch {throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"])}
        }

        routes.on(.post,"v2","rooms",":roomID","message-moderation-operations","admissions",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MessageModerationIntent=try await decode(request)
            try authorize(request,actor:actor.userID,identity:try input.identity)
            guard input.messageID.uuidValue != nil else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do { return try encoded(await rooms.admitMessageModeration(input),status:.ok) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","message-moderation-operations","submit",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MessageModerationCommand=try await decode(request)
            try authorize(request,actor:actor.userID,identity:try input.identity)
            guard input.intent.messageID.uuidValue != nil else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            return try await respond { try await rooms.submitMessageModeration(input) }
        }
        routes.on(.post,"v2","rooms",":roomID","message-moderation-operations","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MessageModerationRecoveryRequest=try await decode(request)
            try authorize(request,actor:actor.userID,identity:try input.intent.identity)
            return try await respond { try await rooms.recoverMessageModeration(input) }
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
    private func respond(_ operation:@Sendable () async throws -> V2MessageModerationRecoveryResult) async throws -> Response {
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
