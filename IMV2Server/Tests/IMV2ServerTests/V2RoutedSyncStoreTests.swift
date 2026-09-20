import Foundation
import FluentPostgresDriver
import IMV2Core
@testable import IMV2Server
import Testing
import Vapor

struct V2RoutedSyncStoreTests {
    @Test("sync operations use the current write bucket")
    func usesCurrentLogicalOwner() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL") else { return }
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        app.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql)
        let user = try UserID("00000000-0000-0000-0000-000000000fa1")
        let device = try DeviceID("00000000-0000-0000-0000-000000000fa2")
        let route = try V2UserShardRoute(
            bucket: "users-target", observedRouterEpoch: 9
        )
        let registry = try V2StaticUserShardStorageRegistry(locations: [
            try .init(bucket: "users-source", database: app.db(.psql), schema: "im_v2"),
            try .init(bucket: "users-target", database: app.db(.psql), schema: "im_v2"),
        ])
        let recorder = RoutedSyncRecorder()
        let store = V2RoutedSyncStore(
            registry: registry,
            routeFence: V2FixedUserShardRouteFence(route: route, database: app.db(.psql))
        ) { location in
            RoutedSyncStoreFake(bucket: location.bucket, recorder: recorder)
        }

        _ = try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 10, now: .init(timeIntervalSince1970: 1_750_000_200))
        _ = try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 10, requireSnapshot: true, now: .init(timeIntervalSince1970: 1_750_000_200))
        #expect(await recorder.buckets() == ["users-target", "users-target"])
        #expect(await recorder.rebuildFlags() == [false, true])
    }
}

private actor RoutedSyncRecorder {
    private var values: [String] = []
    private var flags: [Bool] = []
    func record(_ bucket: String, requireSnapshot: Bool) { values.append(bucket); flags.append(requireSnapshot) }
    func rebuildFlags() -> [Bool] { flags }
    func buckets() -> [String] { values }
}

private struct RoutedSyncStoreFake: V2SyncStore {
    let bucket: String
    let recorder: RoutedSyncRecorder

    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot: Bool, now _: Date) async throws -> V2SyncPullResult {
        await recorder.record(bucket, requireSnapshot: requireSnapshot)
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
