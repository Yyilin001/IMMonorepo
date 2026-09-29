import IMV2ServerContracts
import Foundation
import IMV2Core

/// The upload facts required by orchestration. Persistence encoding stays in the adapter.
public enum V2ResourceUploadPhase: Equatable, Sendable {
    case created, uploading, finalizing, completed, cancelled, expired, failed
}

public enum V2ResourceMediaPhase: Equatable, Sendable {
    case pendingUpload, scanning, available, expired, failed
}

public struct V2ResourceUploadSnapshot: Sendable {
    public let sessionID: UUID
    public let mediaID: UUID
    public let generation: Int64
    public let phase: V2ResourceUploadPhase
    public let mediaPhase: V2ResourceMediaPhase
    public let request: V2ResourceUploadRequest
    public let placement: V2StoredObjectReference
    public let expiresAt: Date
    public let claimToken: UUID?
    public init(sessionID: UUID, mediaID: UUID, generation: Int64, phase: V2ResourceUploadPhase,
                mediaPhase: V2ResourceMediaPhase, request: V2ResourceUploadRequest,
                placement: V2StoredObjectReference, expiresAt: Date, claimToken: UUID?) {
        self.sessionID = sessionID; self.mediaID = mediaID; self.generation = generation
        self.phase = phase; self.mediaPhase = mediaPhase; self.request = request
        self.placement = placement; self.expiresAt = expiresAt; self.claimToken = claimToken
    }
}

public protocol V2ResourceLifecyclePort: Sendable {
    var authorizationExpiresAt: Date? { get }
    var backgroundDelegationExpiresAt: Date? { get }
    func create(request: V2ResourceUploadRequest, home: V2ResourceHome, actor: UserID, device: DeviceID,
                allocate: @escaping @Sendable () throws -> V2StoredObjectReference,
                expiresAt: Date, now: Date) async throws -> V2ResourceUploadSnapshot
    func upload(session: UUID, actor: UUID, device: UUID) async throws -> V2ResourceUploadSnapshot
    func claimUploadFinalize(session: UUID, generation: Int64, actor: UUID, device: UUID, now: Date) async throws -> V2ResourceUploadSnapshot
    func publishUpload(_ claim: V2ResourceUploadSnapshot, facts: V2StoredObjectFacts, actor: UUID, device: UUID, now: Date) async throws
    func cancelUpload(session: UUID, generation: Int64, actor: UUID, device: UUID, now: Date) async throws -> V2ResourceUploadSnapshot
}

public typealias V2ResourceStoreResolving = @Sendable (V2ResourceHome, V2ResourceUsage?, UserID, DeviceID) async throws -> any V2ResourceLifecyclePort
