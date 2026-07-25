import Foundation
import IMV2Core

/// Resolves the current logical user owner for every sync operation. Read
/// fallback is deliberately not used here: returning an older source cursor
/// after target cutover could violate the authenticated device's monotonic
/// sequence. Migration copy/forwarding establishes the target state before
/// route control makes it the owner.
public struct V2RoutedSyncStore: V2SyncStore, Sendable {
    private let router: any V2UserShardRouter
    private let registry: any V2UserShardStorageResolving
    private let makeStore: @Sendable (V2UserShardStorageLocation) -> any V2SyncStore

    public init(
        router: any V2UserShardRouter,
        registry: any V2UserShardStorageResolving,
        makeStore: @escaping @Sendable (V2UserShardStorageLocation) -> any V2SyncStore = {
            PostgresV2SyncStore(database: $0.database, schema: $0.schema)
        }
    ) {
        self.router = router
        self.registry = registry
        self.makeStore = makeStore
    }

    public func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, now: Date) async throws -> V2SyncPullResult {
        try await store(for: userID).pull(userID: userID, deviceID: deviceID, syncToken: syncToken, maxRecords: maxRecords, now: now)
    }

    public func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        try await store(for: userID).acknowledge(userID: userID, deviceID: deviceID, generation: generation, highestContiguousSequence: highestContiguousSequence, receipt: receipt, now: now)
    }

    public func stageReset(userID: UserID, deviceID: DeviceID, snapshot: V2SnapshotStage, now: Date) async throws -> UInt64 {
        try await store(for: userID).stageReset(userID: userID, deviceID: deviceID, snapshot: snapshot, now: now)
    }

    public func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest {
        try await store(for: userID).fetchSnapshotManifest(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, now: now)
    }

    public func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, manifestDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage {
        try await store(for: userID).fetchSnapshotPage(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, manifestDigest: manifestDigest, index: index, now: now)
    }

    public func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        try await store(for: userID).acknowledgeSnapshot(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, baseSequence: baseSequence, receipt: receipt, now: now)
    }

    private func store(for userID: UserID) async throws -> any V2SyncStore {
        let routes = try await router.routes(for: [userID])
        guard routes.count == 1 else { throw V2UserShardRouterError.resultCountMismatch }
        return makeStore(try registry.location(for: routes[0].bucket))
    }
}
