import Foundation
import IMV2Core

/// These identities refer to existing execution journals. There is no second
/// writable task table or UI-owned recovery state.
public enum V2ManagedResourceTransferID: Hashable, Sendable {
    case upload(UUID), download(UUID), serverImport(UUID)
    var kind: String { switch self { case .upload: "upload"; case .download: "download"; case .serverImport: "import" } }
    var value: UUID { switch self { case .upload(let id), .download(let id), .serverImport(let id): id } }
}

public enum V2ResourceTransferGroup: String, CaseIterable, Sendable { case active, attention, finished }
/// Local scheduling intent, independent of a provider's authoritative state.
public enum V2ResourceTransferControl: String, Sendable { case run, pause }
public enum V2ManagedResourceTransferAction: String, Sendable { case retry, retryCancellation, pause, resume, cancel, cancelUnbound }
public enum V2ResourceTransferFailure: Equatable, Sendable { case automaticDownloadRestricted, network, integrity, space, sourceUnavailable, rejected, expired, needsAttention, cancellationUnconfirmed }
public enum V2ManagedResourceTransferPhase: Equatable, Sendable {
    case queued, resolvingMetadata, preparing, transferring, confirming, verifying, processing, pausing, paused, cancelling
    case waitingRetry(Date), requiresAttention(V2ResourceTransferFailure)
    case completed, cancelled, failed(V2ResourceTransferFailure)
}
public enum V2ResourceTransferPurpose: Equatable, Sendable { case attachment, personalAvatar, groupAvatar, download, serverImport }

public struct V2ManagedResourceTransfer: Equatable, Identifiable, Sendable {
    public let id: V2ManagedResourceTransferID
    public let displayName: V2ResourceDisplayName?
    public let purpose: V2ResourceTransferPurpose
    public let mediaID: MediaID
    public let resource: V2ResourceKey?
    public let createdAt: Date
    public let group: V2ResourceTransferGroup
    public internal(set) var phase: V2ManagedResourceTransferPhase
    /// Nil means no authoritative byte count is available. Confirmed bytes
    /// are provider receipts, never a fabricated timer-based percentage.
    public let totalBytes: Int64?
    public let confirmedBytes: Int64?
    public internal(set) var attemptProgress: V2ResourceTransferAttemptProgress? = nil
    public internal(set) var waitingReason: V2ResourceTransferWaitingReason? = nil
    public let actions: [V2ManagedResourceTransferAction]
    public let cancellableMessageCount: Int?
    public let hasBusinessOwners: Bool
}

public struct V2ResourceTransferCursor: Equatable, Sendable {
    public let createdAt: Date
    public let id: V2ManagedResourceTransferID
}
public struct V2ResourceTransferQuery: Equatable, Sendable {
    public let group: V2ResourceTransferGroup?
    public let before: V2ResourceTransferCursor?
    public let limit: Int
    public init(group: V2ResourceTransferGroup? = nil, before: V2ResourceTransferCursor? = nil, limit: Int = 50) throws {
        guard (1...100).contains(limit) else { throw V2ResourceStorageError.invalidRecord }
        self.group = group; self.before = before; self.limit = limit
    }
}
public struct V2ResourceTransferPage: Equatable, Sendable {
    public let entries: [V2ManagedResourceTransfer]
    public let nextCursor: V2ResourceTransferCursor?
}
public enum V2ResourceTransferSnapshot: Equatable, Sendable {
    case available(V2ResourceTransferPage), unavailable
}
public enum V2ResourceTransferManagementError: Error, Equatable, Sendable { case actionUnavailable }
