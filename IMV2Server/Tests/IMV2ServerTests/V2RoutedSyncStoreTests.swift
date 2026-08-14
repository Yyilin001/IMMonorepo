import Foundation
import FluentPostgresDriver
import IMV2Core
@testable import IMV2Server
import Testing
import Vapor

struct V2RoutedSyncStoreTests {
    @Test("sync operations use the current write bucket and never the read fallback")
    func usesCurrentLogicalOwner() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL") else { return }
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql)
        let user = try UserID("00000000-0000-0000-0000-000000000fa1")
        let device = try DeviceID("00000000-0000-0000-0000-000000000fa2")
        let router = V2SingleUserShardRouter(route: try .init(
            bucket: "users-target", observedRouterEpoch: 9, readFallbackBucket: "users-source"
        ))
        let registry = try V2StaticUserShardStorageRegistry(locations: [
            try .init(bucket: "users-source", database: app.db(.psql), schema: "im_v2"),
            try .init(bucket: "users-target", database: app.db(.psql), schema: "im_v2"),
        ])
        let recorder = RoutedSyncRecorder()
        let store = V2RoutedSyncStore(router: router, registry: registry) { location in
            RoutedSyncStoreFake(bucket: location.bucket, recorder: recorder)
        }

        _ = try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 10, now: .init(timeIntervalSince1970: 1_750_000_200))
        #expect(await recorder.buckets() == ["users-target"])
    }
}

private actor RoutedSyncRecorder {
    private var values: [String] = []
    func record(_ bucket: String) { values.append(bucket) }
    func buckets() -> [String] { values }
}

private struct RoutedSyncStoreFake: V2SyncStore {
    let bucket: String
    let recorder: RoutedSyncRecorder

    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, now _: Date) async throws -> V2SyncPullResult {
        await recorder.record(bucket)
        return .ready(
            generation: 1, records: [], nextSyncToken: try .init("00000000-0000-0000-0000-000000000fa3"),
            receipt: try .init("00000000-0000-0000-0000-000000000fa4"), hasMore: false
        )
    }

    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) async throws { fatalError("not used") }
    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, now _: Date) async throws -> V2SnapshotManifest { fatalError("not used") }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, rootDigest _: String, index _: UInt32, now _: Date) async throws -> V2SnapshotPage { fatalError("not used") }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, baseSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) async throws { fatalError("not used") }
}
