import FluentPostgresDriver
import IMV2ServerHTTP
import NIOPosix
import SQLKit
import Testing
import Vapor

@Suite("V2 application EventLoop database pool")
struct V2ApplicationEventLoopDatabasePoolTests {
    @Test("one retained database handle is materialized per distinct application EventLoop")
    func materializesEveryEventLoop() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let app = try await Application.make(.testing, .shared(group))
        do {
            app.databases.use(
                try .postgres(
                    url: "postgres://imv2:unused@127.0.0.1:1/imv2",
                    maxConnectionsPerEventLoop: 1
                ),
                as: .psql,
                isDefault: true
            )
            let eventLoops = Array(group.makeIterator())
            let pool = try V2ApplicationEventLoopDatabasePool(
                application: app,
                identifier: .psql,
                eventLoops: eventLoops
            )

            #expect(pool.database.configuredEventLoopCount == 2)
            #expect(Set(pool.eventLoopDatabases.map {
                ObjectIdentifier($0.eventLoop)
            }).count == 2)

            try await app.asyncShutdown()
            try await group.shutdownGracefully()
        } catch {
            try? await app.asyncShutdown()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("empty and duplicate EventLoop topologies fail before startup")
    func rejectsInvalidTopology() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let app = try await Application.make(.testing, .shared(group))
        do {
            let eventLoop = group.next()
            #expect(throws: V2ApplicationEventLoopDatabasePoolError.emptyEventLoopSet) {
                _ = try V2ApplicationEventLoopDatabasePool(
                    application: app,
                    identifier: .psql,
                    eventLoops: []
                )
            }
            #expect(throws: V2ApplicationEventLoopDatabasePoolError.duplicateEventLoop) {
                _ = try V2ApplicationEventLoopDatabasePool(
                    application: app,
                    identifier: .psql,
                    eventLoops: [eventLoop, eventLoop]
                )
            }

            try await app.asyncShutdown()
            try await group.shutdownGracefully()
        } catch {
            try? await app.asyncShutdown()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("real queries reach independent EventLoop-owned PostgreSQL pools")
    func realQueriesUseEveryEventLoopPool() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let app = try await Application.make(.testing, .shared(group))
        do {
            app.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql,
                isDefault: true
            )
            let pool = try V2ApplicationEventLoopDatabasePool(
                application: app,
                identifier: .psql,
                eventLoops: Array(group.makeIterator())
            )
            var backendPIDs = Set<Int>()
            for _ in 0..<2 {
                let row = try #require(try await pool.database.raw(
                    "SELECT pg_backend_pid() AS value"
                ).first(decoding: BackendPIDRow.self))
                backendPIDs.insert(row.value)
            }
            #expect(backendPIDs.count == 2)

            var transactionalBackendPIDs = Set<Int>()
            for _ in 0..<2 {
                let pid = try await pool.database.transaction { transaction in
                    guard let sql = transaction as? any SQLDatabase else {
                        throw V2ApplicationEventLoopDatabasePoolError.databaseNotRegistered
                    }
                    return try #require(try await sql.raw(
                        "SELECT pg_backend_pid() AS value"
                    ).first(decoding: BackendPIDRow.self)).value
                }
                transactionalBackendPIDs.insert(pid)
            }
            #expect(transactionalBackendPIDs.count == 2)

            try await app.asyncShutdown()
            try await group.shutdownGracefully()
        } catch {
            try? await app.asyncShutdown()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private struct BackendPIDRow: Decodable {
    let value: Int
}
