import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Typed business operations participating in their owning directory's account lifetime.
public struct V2GroupInvitationService: Sendable {
    private let service: V2InvitationOperationService
    private let lifetime: V2DirectoryLifetime
    public init(service: V2InvitationOperationService) { self.init(service: service, lifetime: V2DirectoryLifetime()) }
    init(service: V2InvitationOperationService, lifetime: V2DirectoryLifetime) { self.service = service; self.lifetime = lifetime }
    public func baseline(roomID:RoomID) async throws -> V2GroupInvitationOperationBaseline {
        try await lifetime.run { [service] in try await service.baseline(roomID: roomID) }
    }
    public func confirmation(roomID:RoomID,action:V2GroupInvitationOperationAction,operationID:UUID=UUID()) async throws -> V2InvitationConfirmationWindow {
        try await lifetime.run { [service] in try await service.confirmation(roomID: roomID, action: action, operationID: operationID) }
    }
    @discardableResult public func enqueue(_ confirmation:V2InvitationConfirmationWindow,authorization:V2GroupInvitationSecretAuthorization?=nil) async throws -> UUID {
        try await lifetime.run { [service] in try await service.enqueue(confirmation, authorization: authorization) }
    }
    public func updates(roomID:RoomID) async -> AsyncThrowingStream<[V2InvitationPending],any Error> {
        await lifetime.observe { [service] in await service.updates(roomID: roomID) }
    }
    public func discard(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.discard(id: id) }
    }
    public func resume(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.resume(id: id) }
    }
    public func closeOriginal(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.closeOriginal(id: id) }
    }
    public func reconfirm(id:UUID,confirmation:V2InvitationConfirmationWindow) async throws -> UUID {
        try await lifetime.run { [service] in try await service.reconfirm(id: id, confirmation: confirmation) }
    }
    public func runPreparation() async throws {
        try await lifetime.run { [service] in try await service.runPreparation() }
    }
    func execute(_ claim:V2OperationWorkClaim) async throws {
        try await lifetime.run { [service] in try await service.execute(claim) }
    }
    public func releaseProtectedSecrets() async throws {
        try await lifetime.run { [service] in try await service.releaseProtectedSecrets() }
    }
}
