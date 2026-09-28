import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import Vapor

public struct V2VaporMessageReactionOperationRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let messages:V2RoomRefMessagingClient
    public init(authenticator:any V2GatewayAuthenticator,messages:V2RoomRefMessagingClient) { self.authenticator=authenticator;self.messages=messages }
    public func register(on routes:RoutesBuilder) {
        routes.on(.post,"v2","rooms",":roomID","message-reactions","change",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2MessageReactionOperationCommand=try await decode(request)
            try authorize(request,actor:actor.userID,identity:command.identity)
            return try await respond { try await messages.reactionOperation(command) }
        }
        routes.on(.post,"v2","rooms",":roomID","message-reactions","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MessageReactionRecoveryRequest=try await decode(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            return try await respond { try await messages.recoverReaction(input) }
        }
        routes.on(.get,"v2","rooms",":roomID","message-reactions",":message") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            guard let roomRaw=request.parameters.get("roomID"),let room=UUID(uuidString:roomRaw),
                  let messageRaw=request.parameters.get("message"),let message=UUID(uuidString:messageRaw),
                  let reaction=try? request.query.get(String.self,at:"reaction"),reaction.utf8.count<=64 else { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
            do {
                let value=try await messages.reactionSnapshot(roomID:.init(uuid:room),actorUserID:actor.userID,messageID:.init(uuid:message),reaction:reaction)
                return .init(status:.ok,headers:[.cacheControl:"no-store",.contentType:"application/json"],body:.init(data:try JSONEncoder().encode(value)))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as V2MessageReactionStoreError {
                // Only a domain denial revokes access. A failed read does not.
                let status: HTTPResponse.Status
                switch error {
                case .roomNotFound, .messageNotFound, .actorNotMember, .messageWithdrawn, .reactionLimitReached:
                    status = .forbidden
                case .corruptPersistenceState:
                    status = .serviceUnavailable
                }
                throw Abort(status,headers:[.cacheControl:"no-store"])
            } catch is V2MessageReactionValidationError {
                throw Abort(.badRequest,headers:[.cacheControl:"no-store"])
            } catch {
                throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"])
            }
        }
    }
    private func decode<T:Decodable>(_ request:Request) async throws -> T {
        do { return try await request.content.decode(T.self,using:JSONDecoder()) }
        catch { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
    }
    private func authorize(_ request:Request,actor:UserID,identity:V2OperationIdentity) throws {
        guard let raw=request.parameters.get("roomID"),let uuid=UUID(uuidString:raw),
            case .message(let room,_)=identity.scope,room==RoomID(uuid:uuid),actor==identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
    private func respond(_ operation:@Sendable () async throws -> V2MessageReactionRecoveryResult) async throws -> Response {
        do { return try response(await operation()) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
    }
    private func response(_ result:V2MessageReactionRecoveryResult) throws -> Response {
        var headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]
        let status:HTTPResponse.Status
        if case .deferred(let hint)=result {
            status=hint.reason == .rateLimited ? .tooManyRequests : .serviceUnavailable
            if let milliseconds=hint.retryAfterMilliseconds { headers[.retryAfter]=String((milliseconds+999)/1000) }
        } else { status = .ok }
        return .init(status:status,headers:headers,body:.init(data:try JSONEncoder().encode(result)))
    }
}
