import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Frozen user buckets agree across transactional and realtime reads after restart")
    func fixedUserBuckets() async throws {
        guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: url), as: .psql, isDefault: true)
            let db = resources.database(.psql)
            let sql = try #require(db as? any SQLDatabase)
            try await installSchema(on: sql)
            try await sql.raw("DELETE FROM im_v2.user_shard_router_configuration").run()
            let router = V2PostgresUserShardRouter(database: db)
            let route = try V2UserShardRoute(bucket: "u0", observedRouterEpoch: 1)
            try await router.bootstrap(defaultRoute: route, fixedBuckets: ["u1","u0"])
            try await router.bootstrap(defaultRoute: route, fixedBuckets: ["u0","u1"])
            let users = try ["00","01","02","ff"].map { try UserID("00000000-0000-0000-0000-0000000000" + $0) }
            let expected = try await router.routes(for: users)
            #expect(expected.map(\.bucket) == ["u0","u1","u0","u1"])
            let snapshot = try await V2StaticUserShardRouter.load(database: db)
            #expect(try await snapshot.routes(for: users) == expected)
            await #expect(throws: V2UserShardRouterError.invalidRoute) {
                try await router.bootstrap(defaultRoute: route, fixedBuckets: ["u0","u1","u2"])
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            throw error
        }
    }
}
