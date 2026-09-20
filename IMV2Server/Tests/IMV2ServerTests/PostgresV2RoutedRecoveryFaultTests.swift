import Foundation
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite("Routed recovery with independent PostgreSQL stores")
struct PostgresV2RoutedRecoveryFaultTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func failedOwnerDoesNotHideHealthyOwnerOrBecomeUnavailable() async throws {
        let secondaryURL = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"])
        try await withUserEventDatabase { firstDB, firstSQL, firstSchema in
            try await withUserEventDatabase(databaseURL: secondaryURL) { secondDB, secondSQL, secondSchema in
                let user = UserID(uuid: UUID())
                let a = RoomID(uuid: UUID()), b = RoomID(uuid: UUID())
                for (sql, schema, room, shard) in [(firstSQL, firstSchema, a, "a"), (secondSQL, secondSchema, b, "b")] {
                    try await sql.raw("""
                        INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision)
                        VALUES (\(bind: room.uuidValue!),\(bind: shard),'standard',1)
                        """).run()
                    try await sql.raw("""
                        INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                        VALUES (\(bind: room.uuidValue!),\(bind: user.uuidValue!),1)
                        """).run()
                }
                let registry = try V2StaticRoomShardStorageRegistry(locations: [
                    .init(shardID: "a", database: firstDB, schema: firstSchema),
                    .init(shardID: "b", database: secondDB, schema: secondSchema)])
                let router = RecoveryFaultRoutes(values: [a: try .init(shardID: "a", epoch: 0),
                                                          b: try .init(shardID: "b", epoch: 0)])
                let store = V2RoutedRoomStateStore(router: router, registry: registry)
                let summaries = V2RoutedRoomLatestVisibleStore(router: router, registry: registry)
                let before = try await store.states(roomIDs: [a, b], actorUserID: user)
                guard case .state? = before[a], case .state? = before[b] else {
                    Issue.record("Both real owners must be readable before fault injection")
                    return
                }
                let beforeSummaries = try await summaries.latestVisible(roomIDs: [a, b], actorUserID: user)
                guard case .snapshot? = beforeSummaries[a], case .snapshot? = beforeSummaries[b] else {
                    Issue.record("Both summary owners must be readable before the fault")
                    return
                }
                // This changes only the disposable secondary schema; the reader
                // experiences a real PostgreSQL error rather than a stub result.
                try await secondSQL.raw("ALTER TABLE \(unsafeRaw: secondSchema).room_memberships RENAME TO unavailable_memberships").run()
                let during = try await store.states(roomIDs: [a, b], actorUserID: user)
                guard case .state? = during[a], case .retry? = during[b] else {
                    Issue.record("Owner failure must retain the healthy state and request retry")
                    return
                }
                let duringSummaries = try await summaries.latestVisible(roomIDs: [a, b], actorUserID: user)
                guard case .snapshot? = duringSummaries[a], case .retry? = duringSummaries[b] else {
                    Issue.record("Summary owner failure must be retry, never an empty snapshot or unavailable")
                    return
                }
                try await secondSQL.raw("ALTER TABLE \(unsafeRaw: secondSchema).unavailable_memberships RENAME TO room_memberships").run()
                let after = try await store.states(roomIDs: [a, b], actorUserID: user)
                guard case .state? = after[a], case .state? = after[b] else {
                    Issue.record("The failed owner must recover without changing its route or membership")
                    return
                }
                let afterSummaries = try await summaries.latestVisible(roomIDs: [a, b], actorUserID: user)
                guard case .snapshot? = afterSummaries[a], case .snapshot? = afterSummaries[b] else {
                    Issue.record("Summary reads must recover with the same registry and routes")
                    return
                }

            }
        }
    }
}

private struct RecoveryFaultRoutes: V2RoomShardRouting {
    let values: [RoomID: V2RoomShardRoute]
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        guard let route = values[roomID] else { throw V2RoomShardRouteError.roomNotFound }
        return route
    }
}
