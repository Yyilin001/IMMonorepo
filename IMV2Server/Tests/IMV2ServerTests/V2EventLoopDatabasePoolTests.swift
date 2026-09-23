import FluentPostgresDriver
import Foundation
import IMV2Server
import SQLKit
import Testing

@Suite("V2 EventLoop database pool")
struct V2EventLoopDatabasePoolTests {
    @Test("one retained database handle is materialized per distinct EventLoop")
    func materializesEveryEventLoop() async throws {
        let resources = makeV2DatabaseTestResources(eventLoopThreads: 2)
        do {
            resources.databases.use(
                try .postgres(url: "postgres://imv2:unused@127.0.0.1:1/imv2", maxConnectionsPerEventLoop: 1),
                as: .psql,
                isDefault: true
            )
            let pool = try V2EventLoopDatabasePool(
                databases: resources.databases,
                logger: resources.logger,
                identifier: .psql,
                eventLoops: Array(resources.eventLoopGroup.makeIterator())
            )
            #expect(pool.database.configuredEventLoopCount == 2)
            #expect(Set(pool.eventLoopDatabases.map { ObjectIdentifier($0.eventLoop) }).count == 2)
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("empty and duplicate EventLoop topologies fail before startup")
    func rejectsInvalidTopology() async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            let eventLoop = resources.eventLoopGroup.next()
            #expect(throws: V2EventLoopDatabasePoolError.emptyEventLoopSet) {
                _ = try V2EventLoopDatabasePool(databases: resources.databases, logger: resources.logger,
                                                identifier: .psql, eventLoops: [])
            }
            #expect(throws: V2EventLoopDatabasePoolError.duplicateEventLoop) {
                _ = try V2EventLoopDatabasePool(databases: resources.databases, logger: resources.logger,
                                                identifier: .psql, eventLoops: [eventLoop, eventLoop])
            }
            #expect(throws: V2EventLoopDatabasePoolError.databaseNotRegistered) {
                _ = try V2EventLoopDatabasePool(databases: resources.databases, logger: resources.logger,
                                                identifier: .psql, eventLoops: [eventLoop])
            }
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("real queries, transactions and sessions retain their selected PostgreSQL backend")
    func realQueriesUseEveryEventLoopPool() async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }
        let resources = makeV2DatabaseTestResources(eventLoopThreads: 2)
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                                    as: .psql, isDefault: true)
            let pool = try V2EventLoopDatabasePool(
                databases: resources.databases,
                logger: resources.logger,
                identifier: .psql,
                eventLoops: Array(resources.eventLoopGroup.makeIterator())
            )
            var backendPIDs = Set<Int>()
            for _ in 0..<2 {
                let row = try #require(try await pool.database.raw("SELECT pg_backend_pid() AS value")
                    .first(decoding: BackendPIDRow.self))
                backendPIDs.insert(row.value)
            }
            #expect(backendPIDs.count == 2)

            var transactionalBackendPIDs = Set<Int>()
            for _ in 0..<2 {
                let pid = try await pool.database.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    let first = try #require(try await sql.raw("SELECT pg_backend_pid() AS value")
                        .first(decoding: BackendPIDRow.self)).value
                    let second = try #require(try await sql.raw("SELECT pg_backend_pid() AS value")
                        .first(decoding: BackendPIDRow.self)).value
                    #expect(first == second)
                    return first
                }
                transactionalBackendPIDs.insert(pid)
            }
            #expect(transactionalBackendPIDs.count == 2)

            var sessionBackendPIDs = Set<Int>()
            for _ in 0..<2 {
                let pid = try await pool.database.withSession { sql in
                    let first = try #require(try await sql.raw("SELECT pg_backend_pid() AS value")
                        .first(decoding: BackendPIDRow.self)).value
                    let second = try #require(try await sql.raw("SELECT pg_backend_pid() AS value")
                        .first(decoding: BackendPIDRow.self)).value
                    #expect(first == second)
                    return first
                }
                sessionBackendPIDs.insert(pid)
            }
            #expect(sessionBackendPIDs.count == 2)
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct BackendPIDRow: Decodable { let value: Int }
