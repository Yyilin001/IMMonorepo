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
            do { return try v2EncodedOperationResponse(await coordinator.operationBaseline(roomID:.init(uuid:id),actorUserID:actor.userID,deadline:deadline())) }
            catch V2GroupInvitationServiceError.permissionDenied { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","invitation-operations","admissions",maxBodySize:"8kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupInvitationAdmissionRequest=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,intent:input.intent)
            do { return try v2EncodedOperationResponse(await coordinator.admitOperation(input,deadline:deadline())) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
        }
        routes.on(.post,"v2","rooms",":roomID","invitation-operations","submit",maxBodySize:"8kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupInvitationSubmission=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,intent:input.command.intent)
            return try await v2RespondOperation { try await coordinator.submitOperation(input,deadline:deadline()) }
        }
        routes.on(.post,"v2","rooms",":roomID","invitation-operations","operations","recover",maxBodySize:"8kb") { request async throws -> Response in
            let actor=try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let input:V2GroupInvitationRecoveryRequest=try await v2DecodeOperationInput(request)
            try authorize(request,actor:actor.userID,intent:input.intent)
            return try await v2RespondOperation { try await coordinator.recoverOperation(input,deadline:deadline()) }
        }
    }
    private func deadline() -> ContinuousClock.Instant { ContinuousClock.now.advanced(by:.seconds(15)) }
    private func authorize(_ request:Request,actor:UserID,intent:V2GroupInvitationOperationIntent) throws {
        guard let raw=request.parameters.get("roomID"),let id=UUID(uuidString:raw),intent.roomID == RoomID(uuid:id),actor == intent.identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
}
