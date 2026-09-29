import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporGroupInvitationOperationRoutes: Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let coordinator:any V2GroupInvitationOperationHandling
    public init(authenticator:any V2GatewayAuthenticator,coordinator:any V2GroupInvitationOperationHandling) { self.authenticator=authenticator;self.coordinator=coordinator }
    public func register(on routes:RoutesBuilder) {
        routes.get("v2","rooms",":roomID","invitation-operations","baseline") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            guard let raw=request.parameters.get("roomID"),let id=UUID(uuidString:raw) else { throw Abort(.badRequest) }
            do { return try encoded(await coordinator.operationBaseline(roomID:.init(uuid:id),actorUserID:actor.userID,deadline:deadline())) }
            catch V2GroupInvitationServiceError.permissionDenied { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","invitation-operations","admissions",maxBodySize:"8kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupInvitationAdmissionRequest=try await decode(request)
            try authorize(request,actor:actor.userID,intent:input.intent)
            do { return try encoded(await coordinator.admitOperation(input,deadline:deadline())) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","invitation-operations","submit",maxBodySize:"8kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupInvitationSubmission=try await decode(request)
            try authorize(request,actor:actor.userID,intent:input.command.intent)
            return try await respond { try await coordinator.submitOperation(input,deadline:deadline()) }
        }
        routes.on(.post,"v2","rooms",":roomID","invitation-operations","operations","recover",maxBodySize:"8kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupInvitationRecoveryRequest=try await decode(request)
            try authorize(request,actor:actor.userID,intent:input.intent)
            return try await respond { try await coordinator.recoverOperation(input,deadline:deadline()) }
        }
    }
    private func deadline() -> ContinuousClock.Instant { ContinuousClock.now.advanced(by:.seconds(15)) }
    private func authorize(_ request:Request,actor:UserID,intent:V2GroupInvitationOperationIntent) throws {
        guard let raw=request.parameters.get("roomID"),let id=UUID(uuidString:raw),intent.roomID == RoomID(uuid:id),actor == intent.identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
    private func decode<T:Decodable>(_ request:Request) async throws -> T {
        do { return try await request.content.decode(T.self,using:JSONDecoder()) } catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
    }
    private func encoded<T:Encodable>(_ value:T,status:HTTPResponse.Status = .ok,headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"]) throws -> Response {
        .init(status:status,headers:headers,body:.init(data:try JSONEncoder().encode(value)))
    }
    private func respond(_ body:() async throws -> V2GroupInvitationOperationRecoveryResult) async throws -> Response {
        do {
            let result=try await body();var headers:HTTPFields=[.cacheControl:"no-store",.contentType:"application/json"];var status:HTTPResponse.Status = .ok
            if case .deferred(let hint)=result { status=hint.reason == .rateLimited ? .tooManyRequests:.serviceUnavailable;if let delay=hint.retryAfterMilliseconds { headers[.retryAfter]=String((delay+999)/1000) } }
            return try encoded(result,status:status,headers:headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
    }
}
