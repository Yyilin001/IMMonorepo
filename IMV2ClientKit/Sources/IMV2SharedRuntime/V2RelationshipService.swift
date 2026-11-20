import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Typed business operations participating in their owning directory's account lifetime.
public struct V2RelationshipService: Sendable {
    private let service: V2SocialOperationService
    private let lifetime: V2DirectoryLifetime
    public init(service: V2SocialOperationService) { self.init(service: service, lifetime: V2DirectoryLifetime()) }
    init(service: V2SocialOperationService, lifetime: V2DirectoryLifetime) { self.service = service; self.lifetime = lifetime }
    public func updates() async -> AsyncThrowingStream<[V2SocialOperationPending],any Error> {
        await lifetime.observe { [service] in await service.updates() }
    }
    public func proposalUpdates() async -> AsyncThrowingStream<[V2SocialOperationProposal],any Error> {
        await lifetime.observe { [service] in await service.proposalUpdates() }
    }
    public func saveProposal(action:V2SocialOperationAction,target:UserID) async throws -> UUID {
        try await lifetime.run { [service] in try await service.saveProposal(action: action, target: target) }
    }
    public func discardProposal(id:UUID) async throws {
        try await lifetime.run { [service] in try await service.discardProposal(id: id) }
    }
    public func confirmProposal(id:UUID,snapshot:V2SocialOperationSnapshot) async throws {
        try await lifetime.run { [service] in try await service.confirmProposal(id: id, snapshot: snapshot) }
    }
    public func baseline(targetUserID:UserID) async throws -> V2SocialOperationSnapshot {
        try await lifetime.run { [service] in try await service.baseline(targetUserID: targetUserID) }
    }
    @discardableResult public func enqueue(action:V2SocialOperationAction,targetUserID:UserID) async throws -> UUID {
        try await lifetime.run { [service] in try await service.enqueue(action: action, targetUserID: targetUserID) }
    }
    @discardableResult public func enqueue(action:V2SocialOperationAction,snapshot:V2SocialOperationSnapshot,proposalID:UUID?=nil,confirmedAt:Date=Date(),monotonicDeadline:ContinuousClock.Instant?=nil) async throws -> UUID {
        try await lifetime.run { [service] in try await service.enqueue(action: action, snapshot: snapshot, proposalID: proposalID, confirmedAt: confirmedAt, monotonicDeadline: monotonicDeadline) }
    }
    public func resumeConfirmation(workID:UUID) async throws {
        try await lifetime.run { [service] in try await service.resumeConfirmation(workID: workID) }
    }
    func execute(_ claim:V2OperationWorkClaim) async throws {
        try await lifetime.run { [service] in try await service.execute(claim) }
    }
}
