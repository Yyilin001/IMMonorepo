import Foundation
import IMV2Core
import IMV2ClientRuntime

public struct V2OwnProfileService: Sendable, V2ProfileIntentManaging {
    private let service: V2ProfileIntentService
    private let lifetime: V2DirectoryLifetime
    public init(service: V2ProfileIntentService) { self.init(service: service, lifetime: V2DirectoryLifetime()) }
    init(service: V2ProfileIntentService, lifetime: V2DirectoryLifetime) { self.service = service; self.lifetime = lifetime }
    public func pendingIntent() async throws -> V2ProfileIntent? {
        try await lifetime.run { [service] in try await service.pendingIntent() }
    }
    public func localProfile() async throws -> V2ProfileView? {
        try await lifetime.run { [service] in try await service.localProfile() }
    }
    public func currentProfile() async throws -> V2ProfileView {
        try await lifetime.run { [service] in try await service.currentProfile() }
    }
    public func refreshProfile() async throws -> V2ProfileView {
        try await lifetime.run { [service] in try await service.refreshProfile() }
    }
    public func enqueue(expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, avatarUpload: V2ProfileAvatarUpload? = nil) async throws -> V2ProfileIntent {
        try await lifetime.run { [service] in try await service.enqueue(expectedRevision: expectedRevision, patch: patch, avatarUpload: avatarUpload) }
    }
    public func enqueueImportedAvatar(expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, source: V2ProfileAvatarImport) async throws -> V2ProfileIntent {
        try await lifetime.run { [service] in try await service.enqueueImportedAvatar(expectedRevision: expectedRevision, patch: patch, source: source) }
    }
    public func resumeOrReapply(intentID: UUID) async throws -> V2ProfileIntent {
        try await lifetime.run { [service] in try await service.resumeOrReapply(intentID: intentID) }
    }
    public func discard(intentID: UUID) async throws {
        try await lifetime.run { [service] in try await service.discard(intentID: intentID) }
    }
    public func observe(intentID: UUID) async -> AsyncThrowingStream<V2ProfileIntentStatus, Error> {
        await lifetime.observe { [service] in await service.observe(intentID: intentID) }
    }
    public func runPreparation() async throws {
        try await lifetime.run { [service] in try await service.runPreparation() }
    }
    func execute(_ claim: V2OperationWorkClaim) async throws {
        try await lifetime.run { [service] in try await service.execute(claim) }
    }
    public func handlers() -> [V2OperationWorkDispatcher.Handler] {
        [.init(kind: .profileUpdate) { try await execute($0) }]
    }
}
