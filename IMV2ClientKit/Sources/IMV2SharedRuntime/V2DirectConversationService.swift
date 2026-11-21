import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Typed business operations participating in their owning directory's account lifetime.
public struct V2DirectConversationService: Sendable {
    private let service: V2DirectRoomOperationService
    private let lifetime: V2DirectoryLifetime
    public init(service: V2DirectRoomOperationService) { self.init(service: service, lifetime: V2DirectoryLifetime()) }
    init(service: V2DirectRoomOperationService, lifetime: V2DirectoryLifetime) { self.service = service; self.lifetime = lifetime }
    public func enqueue(publicIdentity:V2PublicIdentity) async throws -> UUID {
        try await lifetime.run { [service] in try await service.enqueue(publicIdentity: publicIdentity) }
    }
    public func updates() async -> AsyncThrowingStream<[V2DirectRoomPending],any Error> {
        await lifetime.observe { [service] in await service.updates() }
    }
    public func resume(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.resume(id: id) }
    }
    public func resumeIfNeeded(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.resumeIfNeeded(id: id) }
    }
    public func receipt(id:UUID) async throws -> V2DirectRoomOperationReceipt? {
        try await lifetime.run { [service] in try await service.receipt(id: id) }
    }
    public func existingLocalRoom(with userID: UserID) async throws -> RoomID? {
        try await lifetime.run { [service] in try await service.existingLocalRoom(with: userID) }
    }
    public func enqueueLocalMessage(text: String, workID: UUID) async throws {
        try await lifetime.run { [service] in try await service.enqueueLocalMessage(text: text, workID: workID) }
    }
    public func localMessages(workID: UUID) async throws -> [V2LocalDirectMessage] {
        try await lifetime.run { [service] in try await service.localMessages(workID: workID) }
    }
    public func messageUpdates() async -> AsyncThrowingStream<[V2LocalDirectMessage], any Error> {
        await lifetime.observe { [service] in await service.messageUpdates() }
    }
    public func prepareLocalMessages() async throws {
        try await lifetime.run { [service] in try await service.prepareLocalMessages() }
    }
    public func runLocalMessagePreparation() async throws {
        try await lifetime.run { [service] in try await service.runLocalMessagePreparation() }
    }
    func execute(_ claim:V2OperationWorkClaim) async throws {
        try await lifetime.run { [service] in try await service.execute(claim) }
    }
}
