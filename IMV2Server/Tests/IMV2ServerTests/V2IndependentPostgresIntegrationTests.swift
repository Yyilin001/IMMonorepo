import FluentPostgresDriver
import Foundation
import NIOCore
import PostgresKit
import PostgresNIO
import SQLKit
import Testing
@testable import IMV2ServerInfrastructure

@Suite("Independent protocol live PostgreSQL", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
struct V2IndependentPostgresIntegrationTests {
    @Test("two writes commit independently; SQL failure does not abort its peer; ordinary commands drain")
    func independentWritesAndFailure() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        var configuration = try SQLPostgresConfiguration(url: url)
        configuration.coreConfiguration.options.preparedQueryCacheCapacity = 16
        resources.databases.use(.postgres(configuration: configuration, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
        do {
            let database = resources.database(.psql)
            try await v2WithOwnerBatchConnection(database: database, deadline: .now + .seconds(10),
                metrics: nil, acquisitionOnly: true, interrupted: { _ in }) { _, _ in
                let pinned = try #require(V2BorrowedRoomConnectionScope.current)
                try await pinned.sql.raw("CREATE TEMP TABLE independent_cycle_test (id BIGINT PRIMARY KEY)").run()
                var first = PostgresBindings(); first.append(Int64(1))
                var second = PostgresBindings(); second.append(Int64(2))
                let shape = "INSERT INTO independent_cycle_test VALUES ($1) RETURNING id"
                let a = pinned.physical.independentQuery(.init(unsafeSQL: shape, binds: first))
                let b = pinned.physical.independentQuery(.init(unsafeSQL: shape, binds: second))
                // This barrier was registered while both responses were outstanding.
                let ready = pinned.physical.confirmReadyForQuery()
                #expect(try await a.get().rows[0].decode(Int64.self) == 1)
                #expect(try await b.get().rows[0].decode(Int64.self) == 2)
                #expect(try await ready.get() == .idle)
                let duplicate = pinned.physical.independentQuery(.init(unsafeSQL: shape, binds: first))
                var third = PostgresBindings(); third.append(Int64(3))
                let good = pinned.physical.independentQuery(.init(unsafeSQL: shape, binds: third))
                do { _ = try await duplicate.get(); Issue.record("duplicate unexpectedly succeeded") }
                catch let error as PSQLError { #expect(error.serverInfo?[.sqlState] == "23505") }
                #expect(try await good.get().rows[0].decode(Int64.self) == 3)
                let ordinary = try await pinned.sql.raw("SELECT count(*) AS count FROM independent_cycle_test").first()
                #expect(try ordinary?.decode(column: "count", as: Int64.self) == 3)
                // Exact message-path binding types, including binary data and typed NULL.
                let adapter = V2IndependentRoomSQLDatabase(base: pinned.sql, connection: pinned.physical)
                let id = UUID(), bytes = Data([0, 1, 255]), absent: UUID? = nil
                let bound = try await adapter.raw("""
                    /* imv2_plain_direct_append */ SELECT \(bind: id)::uuid AS id,
                    \(bind: bytes)::bytea AS bytes, \(bind: absent)::uuid IS NULL AS absent
                    """).first()
                #expect(try bound?.decode(column: "id", as: UUID.self) == id)
                #expect(try bound?.decode(column: "bytes", as: Data.self) == bytes)
                #expect(try bound?.decode(column: "absent", as: Bool.self) == true)
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
    @Test("socket loss leaves only unconfirmed cycles unknown and confirmed write durable")
    func connectionLossAfterFirstConfirmation() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
        let tableName = "independent_close_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let table = SQLIdentifier(tableName)
        do {
            let database = resources.database(.psql)
            try await v2WithOwnerBatchConnection(database: database, deadline: .now + .seconds(10),
                metrics: nil, acquisitionOnly: true, interrupted: { _ in }) { _, _ in
                let pinned = try #require(V2BorrowedRoomConnectionScope.current)
                try await pinned.sql.raw("CREATE TABLE \(table) (id BIGINT PRIMARY KEY)").run()
                let sql = "INSERT INTO \"\(tableName)\" VALUES (1) RETURNING id"
                let a = pinned.physical.independentQuery(.init(unsafeSQL: sql))
                let b = pinned.physical.independentQuery(.init(unsafeSQL: "SELECT pg_sleep(1)"))
                #expect(try await a.get().rows[0].decode(Int64.self) == 1)
                try await pinned.physical.close().get()
                await #expect(throws: PostgresIndependentQueryError.outcomeUnknown) { _ = try await b.get() }
            }
            let sql = try #require(database as? any SQLDatabase)
            let row = try await sql.raw("SELECT count(*) AS count FROM \(table)").first()
            #expect(try row?.decode(column: "count", as: Int64.self) == 1)
            try await sql.raw("DROP TABLE \(table)").run()
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    @Test("graceful shutdown drains submitted cycles before closing")
    func gracefulShutdownDrains() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
        do {
            try await v2WithOwnerBatchConnection(database: resources.database(.psql), deadline: .now + .seconds(10),
                metrics: nil, acquisitionOnly: true, interrupted: { _ in }) { _, _ in
                let pinned = try #require(V2BorrowedRoomConnectionScope.current)
                let a = pinned.physical.independentQuery(.init(unsafeSQL: "SELECT pg_sleep(0.02)"))
                let b = pinned.physical.independentQuery(.init(unsafeSQL: "SELECT 42"))
                async let shutdown: Void = pinned.physical.closeGracefully()
                #expect(try await a.get().commandTag == "SELECT 1")
                #expect(try await b.get().rows[0].decode(Int32.self) == 42)
                try await shutdown
                #expect(pinned.physical.isClosed)
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

}
