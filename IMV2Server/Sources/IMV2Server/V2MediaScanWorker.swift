import Foundation
import IMV2Core

public enum V2MediaScanResult: Equatable, Sendable {
    case passed
    case failed
}

public struct V2MediaScanLease: Equatable, Sendable {
    public let mediaID: MediaID
    public let claimToken: UUID

    public init(mediaID: MediaID, claimToken: UUID) {
        self.mediaID = mediaID
        self.claimToken = claimToken
    }
}

/// The scanner resolves provider-private object identity behind this boundary;
/// the chat worker passes only an opaque media ID and never receives bytes,
/// filename, hash, thumbnail, object key, or provider credential.
public protocol V2MediaScanProvider: Sendable {
    func scan(mediaID: MediaID) async throws -> V2MediaScanResult
}

public protocol V2MediaScanStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2MediaScanLease]
    func complete(_ lease: V2MediaScanLease, result: V2MediaScanResult, now: Date) async throws
    func release(_ lease: V2MediaScanLease) async throws
}

public struct V2MediaScanReport: Equatable, Sendable {
    public let claimedCount: Int
    public let completedCount: Int
    public let releasedCount: Int

    public init(claimedCount: Int, completedCount: Int, releasedCount: Int) {
        self.claimedCount = claimedCount
        self.completedCount = completedCount
        self.releasedCount = releasedCount
    }
}

/// Bounded scanner worker. A provider failure cannot make media referenceable:
/// its outbox item is retried while the media object remains `scanning`.
public struct V2MediaScanWorker: Sendable {
    private let store: any V2MediaScanStore
    private let provider: any V2MediaScanProvider
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date

    public init(store: any V2MediaScanStore, provider: any V2MediaScanProvider, leaseDuration: TimeInterval = 30, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration > 0 else { throw V2MediaScanWorkerError.invalidLeaseDuration }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2MediaScanReport {
        guard limit > 0 else { throw V2MediaScanWorkerError.invalidLimit }
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var completed = 0
        var released = 0
        for lease in leases {
            do {
                try await store.complete(lease, result: try await provider.scan(mediaID: lease.mediaID), now: now())
                completed += 1
            } catch {
                try await store.release(lease)
                released += 1
            }
        }
        return .init(claimedCount: leases.count, completedCount: completed, releasedCount: released)
    }
}

public enum V2MediaScanWorkerError: Error, Equatable, Sendable {
    case invalidLeaseDuration
    case invalidLimit
}
