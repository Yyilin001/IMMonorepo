import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Typed business operations participating in their owning directory's account lifetime.
public struct V2GroupCreationService: Sendable {
    private let service: V2GroupCreationOperationService
    private let lifetime: V2DirectoryLifetime
    public init(service: V2GroupCreationOperationService) { self.init(service: service, lifetime: V2DirectoryLifetime()) }
    init(service: V2GroupCreationOperationService, lifetime: V2DirectoryLifetime) { self.service = service; self.lifetime = lifetime }
    public func enqueue(title:String,members:[UserID]) async throws -> UUID {
        try await lifetime.run { [service] in try await service.enqueue(title: title, members: members) }
    }
    public func updates() async -> AsyncThrowingStream<Void,any Error> {
        await lifetime.observe { [service] in await service.updates() }
    }
    public func latest() async throws -> V2GroupCreationPending? {
        try await lifetime.run { [service] in try await service.latest() }
    }
    public func pending(id:UUID) async throws -> V2GroupCreationPending {
        try await lifetime.run { [service] in try await service.pending(id: id) }
    }
    public func requestCancellation(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.requestCancellation(id: id) }
    }
    public func resume(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.resume(id: id) }
    }
    func execute(_ claim:V2OperationWorkClaim) async throws {
        try await lifetime.run { [service] in try await service.execute(claim) }
    }
}
