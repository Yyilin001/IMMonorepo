import Foundation
import IMV2Core

/// Resolves the current logical user owner for every sync operation. Read
/// fallback is deliberately not used here: returning an older source cursor
/// after target cutover could violate the authenticated device's monotonic
/// sequence. Migration copy/forwarding establishes the target state before
/// route control makes it the owner.
public struct V2RoutedSyncStore: V2SyncStore, Sendable {
    private let registry: any V2UserShardStorageResolving
    private let routeFence: any V2UserShardRouteFencing
    private let coLocatedControlBuckets: Set<String>
    private let makeStore: @Sendable (V2UserShardStorageLocation) -> any V2SyncStore

    public init(
        registry: any V2UserShardStorageResolving,
        routeFence: any V2UserShardRouteFencing,
        coLocatedControlBuckets: Set<String> = [],
        capabilityProfile: String = "base",
        maximumEncodedRecordsBytes: Int = 48 * 1_024,
        makeStore: (@Sendable (V2UserShardStorageLocation) -> any V2SyncStore)? = nil
    ) {
        precondition(maximumEncodedRecordsBytes > 0)
        self.registry = registry
        self.routeFence = routeFence
        self.coLocatedControlBuckets = coLocatedControlBuckets
        self.makeStore = makeStore ?? {
            PostgresV2SyncStore(
                database: $0.database, schema: $0.schema,
                capabilityProfile: capabilityProfile,
                maximumEncodedRecordsBytes: maximumEncodedRecordsBytes
            )
        }
    }

    public func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, requireSnapshot: Bool = false, now: Date) async throws -> V2SyncPullResult {
        try await withStore(for: userID) {
            try await $0.pull(userID: userID, deviceID: deviceID, syncToken: syncToken, maxRecords: maxRecords, requireSnapshot: requireSnapshot, now: now)
        }
    }

    public func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        try await withStore(for: userID) {
            try await $0.acknowledge(userID: userID, deviceID: deviceID, generation: generation, highestContiguousSequence: highestContiguousSequence, receipt: receipt, now: now)
        }
    }

    public func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest {
        try await withStore(for: userID) {
            try await $0.fetchSnapshotManifest(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, now: now)
        }
    }

    public func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage {
        try await withStore(for: userID) {
            try await $0.fetchSnapshotPage(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, rootDigest: rootDigest, index: index, now: now)
        }
    }

    public func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        try await withStore(for: userID) {
            try await $0.acknowledgeSnapshot(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, baseSequence: baseSequence, receipt: receipt, now: now)
        }
    }

    private func withStore<Result: Sendable>(
        for userID: UserID,
        _ operation: @escaping @Sendable (any V2SyncStore) async throws -> Result
    ) async throws -> Result {
        try await routeFence.withCurrentRoute(for: userID) { route, fencedDatabase in
            var location = try registry.location(for: route.bucket)
            // A co-located shard must use the fence transaction's database
            // handle. Opening a second pooled connection while the first
            // holds the route lock can self-deadlock in one-connection
            // deployments and would not share the transaction boundary.
            if coLocatedControlBuckets.contains(route.bucket) {
                location = try .init(
                    bucket: location.bucket, database: fencedDatabase,
                    schema: location.schema
                )
            }
            return try await operation(makeStore(location))
        }
    }
}
