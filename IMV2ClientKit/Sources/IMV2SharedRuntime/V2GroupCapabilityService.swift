import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Typed business operations participating in their owning directory's account lifetime.
public struct V2GroupCapabilityService: Sendable {
    private let service: V2GroupCapabilityOperationService
    private let lifetime: V2DirectoryLifetime
    public init(service: V2GroupCapabilityOperationService) { self.init(service: service, lifetime: V2DirectoryLifetime()) }
    init(service: V2GroupCapabilityOperationService, lifetime: V2DirectoryLifetime) { self.service = service; self.lifetime = lifetime }
    public func confirmationWindow(roomID:RoomID,action:V2GroupCapabilityAction) throws -> V2GroupCapabilityConfirmationWindow {
        try service.confirmationWindow(roomID: roomID, action: action)
    }
    public func pinBaseline(roomID:RoomID,messageID:MessageID) async throws -> V2PinnedMessageBaseline {
        try await lifetime.run { [service] in try await service.pinBaseline(roomID: roomID, messageID: messageID) }
    }
    @discardableResult public func enqueue(confirmation:V2GroupCapabilityConfirmationWindow) async throws -> UUID {
        try await lifetime.run { [service] in try await service.enqueue(confirmation: confirmation) }
    }
    public func updates(roomID:RoomID) async -> AsyncThrowingStream<[V2GroupCapabilityPending],any Error> {
        await lifetime.observe { [service] in await service.updates(roomID: roomID) }
    }
    public func discardDraft(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.discardDraft(id: id) }
    }
    public func resumeConfirmation(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.resumeConfirmation(id: id) }
    }
    public func reconfirmDraft(id:UUID,confirmation:V2GroupCapabilityConfirmationWindow) async throws -> UUID {
        try await lifetime.run { [service] in try await service.reconfirmDraft(id: id, confirmation: confirmation) }
    }
    public func runPreparation() async throws {
        try await lifetime.run { [service] in try await service.runPreparation() }
    }
    func execute(_ claim:V2OperationWorkClaim) async throws {
        try await lifetime.run { [service] in try await service.execute(claim) }
    }
}
