import Foundation
import IMV2Core
import IMV2ClientRuntime

public struct V2ProfileNameService: Sendable {
    private let service: V2NameOperationService
    private let lifetime: V2DirectoryLifetime
    public init(service: V2NameOperationService) { self.init(service: service, lifetime: V2DirectoryLifetime()) }
    init(service: V2NameOperationService, lifetime: V2DirectoryLifetime) { self.service = service; self.lifetime = lifetime }
    public func cached(_ target: V2NameTarget) async throws -> V2NameSnapshot? {
        try await lifetime.run { [service] in try await service.cached(target) }
    }
    public func refresh(_ target: V2NameTarget) async throws -> V2NameSnapshot {
        try await lifetime.run { [service] in try await service.refresh(target) }
    }
    @discardableResult public func save(_ target: V2NameTarget, name: String?, expectedRevision: V2ProfileRevision?) async throws -> UUID {
        try await lifetime.run { [service] in try await service.save(target, name: name, expectedRevision: expectedRevision) }
    }
    public func updates(_ target: V2NameTarget) async -> AsyncThrowingStream<V2NameIntentSnapshot?, any Error> {
        await lifetime.observe { [service] in await service.updates(target) }
    }
    public func baselineUpdates(_ target: V2NameTarget) async -> AsyncThrowingStream<V2NameSnapshot?, any Error> {
        await lifetime.observe { [service] in await service.baselineUpdates(target) }
    }
    public func continueConfirmation(id: UUID) async throws {
        try await lifetime.run { [service] in try await service.continueConfirmation(id: id) }
    }
    public func discard(id: UUID) async throws {
        try await lifetime.run { [service] in try await service.discard(id: id) }
    }
    func execute(_ claim: V2OperationWorkClaim) async throws {
        try await lifetime.run { [service] in try await service.execute(claim) }
    }
    public func handlers() -> [V2OperationWorkDispatcher.Handler] {
        [.init(kind: .contactAlias) { try await execute($0) }, .init(kind: .groupNickname) { try await execute($0) }]
    }
}
