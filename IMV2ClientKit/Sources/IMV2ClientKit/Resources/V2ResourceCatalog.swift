import Foundation
import IMV2Core

public struct V2LocalResourceFileID: Hashable, Codable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}

/// Retention is not authorization. Even retained bytes require current access.
public enum V2ResourceFileRetention: String, Codable, CaseIterable, Sendable {
    case cache, retained, original
}

public enum V2ResourceFileStorage: String, Codable, CaseIterable, Sendable {
    case persistent, cache
}

struct V2ResourceFileRelocation: Equatable, Sendable {
    let fileID: V2LocalResourceFileID
    let source: V2ResourceFileStorage
    let target: V2ResourceFileStorage
}

public enum V2ResourceFileState: String, Codable, Sendable {
    case publishing, published, retiring, missing, invalid
}

public struct V2ResourceFileRecord: Equatable, Sendable {
    public let id: V2LocalResourceFileID
    public let checksum: V2ResourceChecksum
    public let byteCount: Int64
    public let allocatedBytes: Int64
    public let retention: V2ResourceFileRetention
    public let storage: V2ResourceFileStorage
    public let isPinned: Bool
    public let state: V2ResourceFileState
    public let lastAccessAt: Date
}

public enum V2ResourceStorageError: Error, Equatable, Sendable {
    case invalidRecord, unavailable, closed, capacityExceeded, fileInUse
    case integrityMismatch, unsafeFile, conflict, expiredCleanupPlan
}

public struct V2ResourceCleanupPlan: Equatable, Sendable {
    public let id: UUID
    public let fileIDs: [V2LocalResourceFileID]
    public let transferStagingIDs: [UUID]
    public let estimatedBytes: Int64
    public let skippedCount: Int
    public let expiresAt: Date
}

/// Selection is logical; the enclosed cleanup capability targets only its
/// published physical files, never the account-wide cache or staging area.
public struct V2ResourceSelectionCleanupPlan: Equatable, Sendable {
    public let plan: V2ResourceCleanupPlan
    public let resourceCount: Int
    public let unavailableResourceCount: Int
    public let absentResourceCount: Int
}

public struct V2ResourceCleanupResult: Equatable, Sendable {
    public let deletedCount: Int
    public let releasedBytes: Int64
    public let skippedCount: Int
    public let failedCount: Int
}

/// Paths are deliberately absent from directory snapshots.
public struct V2ResourceStorageSnapshot: Equatable, Sendable {
    public let files: [V2ResourceFileRecord]
    public let avatarOnlyCacheFileIDs: Set<V2LocalResourceFileID>
    /// Outstanding temporary capacity, including future publication credit;
    /// this is not the physical allocated-byte total below.
    public let transferReservedBytes: Int64
    public let transferAllocatedBytes: Int64
    public let backgroundReservedBytes: Int64
    public let backgroundAllocatedBytes: Int64
    public let quota: V2ResourceQuotaSnapshot
    public init(files: [V2ResourceFileRecord], avatarOnlyCacheFileIDs: Set<V2LocalResourceFileID>, transferReservedBytes: Int64 = 0, transferAllocatedBytes: Int64 = 0,
                backgroundReservedBytes: Int64 = 0, backgroundAllocatedBytes: Int64 = 0, quota: V2ResourceQuotaSnapshot) {
        self.files = files; self.transferReservedBytes = transferReservedBytes; self.transferAllocatedBytes = transferAllocatedBytes
        self.avatarOnlyCacheFileIDs = avatarOnlyCacheFileIDs
        self.quota = quota
        self.backgroundReservedBytes = backgroundReservedBytes; self.backgroundAllocatedBytes = backgroundAllocatedBytes
    }
    public var totalBytes: Int64 { files.reduce(transferAllocatedBytes + backgroundAllocatedBytes) { $0 + $1.allocatedBytes } }
    public var avatarCacheBytes: Int64 {
        files.filter { $0.retention == .cache && avatarOnlyCacheFileIDs.contains($0.id) }.reduce(0) { $0 + $1.allocatedBytes }
    }
    public var otherCacheBytes: Int64 { bytes(for: .cache) - avatarCacheBytes }
    public func bytes(for retention: V2ResourceFileRetention) -> Int64 {
        files.filter { $0.retention == retention }.reduce(0) { $0 + $1.allocatedBytes }
    }
}
