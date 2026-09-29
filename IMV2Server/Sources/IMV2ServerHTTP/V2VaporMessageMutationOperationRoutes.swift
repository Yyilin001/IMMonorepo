import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporMessageMutationOperationRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let messages:any V2MessageMutationOperationHandling
    public init(authenticator:any V2GatewayAuthenticator,messages:any V2MessageMutationOperationHandling) { self.authenticator=authenticator;self.messages=messages }
    public func register(on routes:RoutesBuilder) {
        routes.on(.post,"v2","rooms",":roomID","message-mutations","edit",maxBodySize:"1mb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2MessageEditOperationCommand=try await decode(request)
            try authorize(request,actor:actor.userID,identity:command.identity)
            return try await respond { try await messages.editOperation(command) }
        }
        routes.on(.post,"v2","rooms",":roomID","message-mutations","withdraw",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let command:V2MessageWithdrawalOperationCommand=try await decode(request)
            try authorize(request,actor:actor.userID,identity:command.identity)
            return try await respond { try await messages.withdrawOperation(command) }
        }
        routes.on(.post,"v2","rooms",":roomID","message-mutations","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2MessageMutationRecoveryRequest=try await decode(request)
            try authorize(request,actor:actor.userID,identity:input.identity)
            return try await respond { try await messages.recoverMutation(input) }
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
    private func respond(_ operation:@Sendable () async throws -> V2MessageMutationRecoveryResult) async throws -> Response {
        do { return try response(await operation()) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
    }
    private func response(_ result:V2MessageMutationRecoveryResult) throws -> Response {
        var headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]
        let status:HTTPResponse.Status
        if case .deferred(let hint)=result {
            status=hint.reason == .rateLimited ? .tooManyRequests : .serviceUnavailable
            if let milliseconds=hint.retryAfterMilliseconds { headers[.retryAfter]=String((milliseconds+999)/1000) }
        } else { status = .ok }
        return .init(status:status,headers:headers,body:.init(data:try JSONEncoder().encode(result)))
    }
}
