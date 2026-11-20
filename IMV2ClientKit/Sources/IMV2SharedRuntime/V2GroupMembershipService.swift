import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Typed business operations participating in their owning directory's account lifetime.
public struct V2GroupMembershipService: Sendable {
    private let service: V2MembershipOperationService
    private let lifetime: V2DirectoryLifetime
    public init(service: V2MembershipOperationService) { self.init(service: service, lifetime: V2DirectoryLifetime()) }
    init(service: V2MembershipOperationService, lifetime: V2DirectoryLifetime) { self.service = service; self.lifetime = lifetime }
    public func confirmationWindow(roomID:RoomID,action:V2RoomMembershipAction,expectedMembershipRevision:UInt64) throws -> V2MembershipConfirmationWindow {
        try service.confirmationWindow(roomID: roomID, action: action, expectedMembershipRevision: expectedMembershipRevision)
    }
    @discardableResult public func enqueue(targetUserID:UserID,confirmation:V2MembershipConfirmationWindow) async throws -> UUID {
        try await lifetime.run { [service] in try await service.enqueue(targetUserID: targetUserID, confirmation: confirmation) }
    }
    public func updates(roomID:RoomID) async -> AsyncThrowingStream<[V2MembershipPending],any Error> {
        await lifetime.observe { [service] in await service.updates(roomID: roomID) }
    }
    public func discardDraft(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.discardDraft(id: id) }
    }
    public func resumeConfirmation(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.resumeConfirmation(id: id) }
    }
    public func reconfirmDraft(id:UUID,confirmation:V2MembershipConfirmationWindow) async throws -> UUID {
        try await lifetime.run { [service] in try await service.reconfirmDraft(id: id, confirmation: confirmation) }
    }
    public func runPreparation() async throws {
        try await lifetime.run { [service] in try await service.runPreparation() }
    }
    func execute(_ claim:V2OperationWorkClaim) async throws {
        try await lifetime.run { [service] in try await service.execute(claim) }
    }
}
