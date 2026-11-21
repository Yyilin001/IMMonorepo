import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Typed business operations participating in their owning directory's account lifetime.
public struct V2GroupAdministrationService: Sendable {
    private let service: V2MemberAdministrationOperationService
    private let lifetime: V2DirectoryLifetime
    public init(service: V2MemberAdministrationOperationService) { self.init(service: service, lifetime: V2DirectoryLifetime()) }
    init(service: V2MemberAdministrationOperationService, lifetime: V2DirectoryLifetime) { self.service = service; self.lifetime = lifetime }
    @discardableResult public func enqueue(roomID:RoomID,targetUserID:UserID,action:V2MemberAdministrationAction,reasonCode:V2ModerationReasonCode,expectedMembershipRevision:UInt64) async throws -> UUID {
        try await lifetime.run { [service] in try await service.enqueue(roomID: roomID, targetUserID: targetUserID, action: action, reasonCode: reasonCode, expectedMembershipRevision: expectedMembershipRevision) }
    }
    public func updates(roomID:RoomID) async -> AsyncThrowingStream<[V2MemberAdministrationPending],any Error> {
        await lifetime.observe { [service] in await service.updates(roomID: roomID) }
    }
    public func discardDraft(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.discardDraft(id: id) }
    }
    public func resumeConfirmation(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.resumeConfirmation(id: id) }
    }
    public func reconfirmDraft(id:UUID,expectedMembershipRevision:UInt64) async throws -> UUID {
        try await lifetime.run { [service] in try await service.reconfirmDraft(id: id, expectedMembershipRevision: expectedMembershipRevision) }
    }
    public func runPreparation() async throws {
        try await lifetime.run { [service] in try await service.runPreparation() }
    }
    func execute(_ claim:V2OperationWorkClaim) async throws {
        try await lifetime.run { [service] in try await service.execute(claim) }
    }
}
