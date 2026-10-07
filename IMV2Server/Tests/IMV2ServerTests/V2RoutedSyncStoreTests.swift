@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import FluentKit
import FluentPostgresDriver
import NIOCore
import SQLKit
import Synchronization
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2RoutedSyncStoreTests {
    @Test("routed Sync classifies the first real control borrow and reuses its co-located connection")
    func syncPurposeCoversRouteBorrowAndNestedOwner() async throws {
        guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 11), as: .psql)
            let database = try V2EventLoopBalancedDatabase(databases: [resources.database(.psql)], loanPolicy: .init(
                maximumConnections: 11, reservedRenewalConnections: 2,
                maximumQueued: 16, maximumWait: .seconds(5)))
            let pids = BorrowedSyncPIDs()
            let route = try V2UserShardRoute(bucket: "sync-owner", observedRouterEpoch: 1)
            let registry = try V2StaticUserShardStorageRegistry(locations: [
                .init(bucket: "sync-owner", database: database, schema: "im_v2")
            ])
            let store = V2RoutedSyncStore(registry: registry,
                routeFence: BorrowedSyncRouteFence(database: database, route: route, pids: pids),
                coLocatedControlBuckets: ["sync-owner"]) { location in
                    BorrowedSyncOwnerStore(database: location.database, pids: pids)
                }
            _ = try await store.pull(userID: UserID(uuid: UUID()), deviceID: DeviceID(uuid: UUID()),
                syncToken: nil, maxRecords: 10, now: Date())
            let identifiers = pids.values.withLock { $0 }
            #expect(identifiers.count == 2 && identifiers.first == identifiers.last)
            let completed = database.loanMetricsSnapshot()
            #expect(completed.classes[.sync]?.granted == 1)
            #expect(completed.classes[.sync]?.inFlight == 0)
            #expect(completed.classes[.ordinary]?.granted == 0)
            // The trusted purpose ends with withStore, not with the shared facade.
            let ordinary: EventLoopFuture<Void> = database.withConnection { borrowed in
                borrowed.eventLoop.makeSucceededFuture(())
            }
            try await ordinary.get()
            #expect(database.loanMetricsSnapshot().classes[.ordinary]?.granted == 1)
            #expect(database.loanMetricsSnapshot().classes[.sync]?.granted == 1)
            await database.shutdownLoans()
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("sync operations use the current write bucket")
    func usesCurrentLogicalOwner() async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"] else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql)
            let user = try UserID("00000000-0000-0000-0000-000000000fa1")
            let device = try DeviceID("00000000-0000-0000-0000-000000000fa2")
            let route = try V2UserShardRoute(
                bucket: "users-target", observedRouterEpoch: 9
            )
            let registry = try V2StaticUserShardStorageRegistry(locations: [
                try .init(bucket: "users-source", database: resources.database(.psql), schema: "im_v2"),
                try .init(bucket: "users-target", database: resources.database(.psql), schema: "im_v2"),
            ])
            let recorder = RoutedSyncRecorder()
            let store = V2RoutedSyncStore(
                registry: registry,
                routeFence: V2FixedUserShardRouteFence(route: route, database: resources.database(.psql))
            ) { location in
                RoutedSyncStoreFake(bucket: location.bucket, recorder: recorder)
            }

            _ = try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 10, now: .init(timeIntervalSince1970: 1_750_000_200))
            _ = try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 10, requireSnapshot: true, now: .init(timeIntervalSince1970: 1_750_000_200))
            #expect(await recorder.buckets() == ["users-target", "users-target"])
            #expect(await recorder.rebuildFlags() == [false, true])
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            throw error
        }
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

private struct BorrowedSyncRouteFence: V2UserShardRouteFencing {
    let database: V2EventLoopBalancedDatabase
    let route: V2UserShardRoute
    let pids: BorrowedSyncPIDs
    func withCurrentRoute<Result: Sendable>(for userID: UserID,
        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result
    ) async throws -> Result {
        try await database.transaction { borrowed in
            let sql = try #require(borrowed as? any SQLDatabase)
            let row = try #require(try await sql.raw("SELECT pg_backend_pid() AS pid").first())
            let pid = try row.decode(column: "pid", as: Int32.self)
            pids.values.withLock { $0.append(pid) }
            #expect(database.loanMetricsSnapshot().classes[.sync]?.inFlight == 1)
            #expect(database.loanMetricsSnapshot().classes[.ordinary]?.inFlight == 0)
            return try await operation(route, borrowed)
        }
    }
}

private struct BorrowedSyncOwnerStore: V2SyncStore {
    let database: any Database
    let pids: BorrowedSyncPIDs
    func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int,
              requireSnapshot: Bool, now: Date) async throws -> V2SyncPullResult {
        let future: EventLoopFuture<Int32> = database.withConnection { borrowed in
            borrowed.eventLoop.makeFutureWithTask {
                let sql = try #require(borrowed as? any SQLDatabase)
                let row = try #require(try await sql.raw("SELECT pg_backend_pid() AS pid").first())
                return try row.decode(column: "pid", as: Int32.self)
            }
        }
        let pid = try await future.get()
        pids.values.withLock { $0.append(pid) }
        return .ready(generation: 1, records: [], nextSyncToken: try .init(UUID().uuidString),
                      receipt: try .init(UUID().uuidString), hasMore: false)
    }
    func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64,
                     highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws { fatalError("not used") }
    func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID,
                               generation: UInt64, now: Date) async throws -> V2SnapshotManifest { fatalError("not used") }
    func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64,
                          rootDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage { fatalError("not used") }
    func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64,
                             baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws { fatalError("not used") }
}

private final class BorrowedSyncPIDs: Sendable {
    let values = Mutex<[Int32]>([])
}
