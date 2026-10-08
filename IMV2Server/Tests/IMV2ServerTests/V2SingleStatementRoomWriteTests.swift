import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import Logging
import PostgresKit
import PostgresNIO
import SQLKit
import Testing

@Suite(.serialized)
struct V2SingleStatementRoomWriteTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_TEST_DATABASE_IS_DISPOSABLE"] == "1"),
        arguments: ["success", "constraint", "late", "validation", "deadline", "cancel"])
    func atomicWriteAndConfirmation(mode: String) async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        var configuration = try SQLPostgresConfiguration(url: url)
        configuration.coreConfiguration.options.additionalStartupParameters += V2RoomActivationSQLTimeouts.default.startupParameters
        let controlID = DatabaseID(string: "implicit-control")
        resources.databases.use(.postgres(configuration: configuration, maxConnectionsPerEventLoop: 1), as: .psql)
        resources.databases.use(.postgres(configuration: configuration, maxConnectionsPerEventLoop: 1), as: controlID)
        let logger = Logger(label: "imv2.implicit.commit.test")
        let control = try #require(resources.databases.database(controlID, logger: logger, on: resources.eventLoopGroup.next()) as? any SQLDatabase)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let message = "implicit_message_" + suffix, completion = "implicit_completion_" + suffix, trigger = "implicit_trigger_" + suffix
        var tablesCreated = false
        do {
            let pool = try V2EventLoopDatabasePool(databases: resources.databases, logger: logger, identifier: .psql,
                eventLoops: Array(resources.eventLoopGroup.makeIterator()),
                loanPolicy: .init(maximumConnections: 1, reservedRenewalConnections: 0,
                    maximumQueued: 8, maximumWait: .seconds(2)), sessionTimeouts: .default)
            try await V2PostgresSessionReadiness.verify(database: pool.database, timeouts: .default)
            try await control.raw("CREATE TABLE \(unsafeRaw: message) (value bigint PRIMARY KEY)").run()
            try await control.raw("CREATE TABLE \(unsafeRaw: completion) (value bigint PRIMARY KEY CHECK(value > 0))").run()
            tablesCreated = true
            if mode == "late" {
                try await control.raw("""
                    CREATE FUNCTION \(unsafeRaw: trigger)() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN PERFORM pg_sleep(0.1); RAISE EXCEPTION 'test late implicit commit'; END $$
                    """).run()
                try await control.raw("""
                    CREATE CONSTRAINT TRIGGER test_late_implicit AFTER INSERT ON \(unsafeRaw: message)
                    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: trigger)()
                    """).run()
            }
            let metrics = V2SendOperationBatchMetrics()
            let statement: SQLQueryString = """
                WITH inserted AS (
                    INSERT INTO \(unsafeRaw: message) SELECT 1 FROM (SELECT pg_sleep(\(bind: (mode == "deadline" || mode == "cancel") ? 1.0 : 0.0))) AS delay
                    RETURNING value
                ) INSERT INTO \(unsafeRaw: completion) SELECT \(bind: mode == "constraint" ? Int64(-1) : Int64(1)) FROM inserted RETURNING value
                """
            func sqlCount() -> UInt64 {
                pool.database.loanMetricsSnapshot().observations.values.reduce(0) { sum, source in
                    sum + source.sqlPhases.values.reduce(0) { $0 + $1.count }
                }
            }
            let before = sqlCount()
            let started = ContinuousClock.now
            let task = Task {
                try await v2WithOwnerBatchConnection(database: pool.database, deadline: .now + .seconds(5),
                    metrics: nil, interrupted: { _ in }) { _, _ -> Int64 in
                    let connection = try #require(V2BorrowedRoomConnectionScope.current)
                    return try await v2ExecuteSingleStatementRoomWrite(connection: connection,
                        deadline: .now + (mode == "deadline" ? .milliseconds(150) : .seconds(5)), metrics: metrics) {
                        let row = try #require(try await connection.sql.raw(statement).first(decoding: ImplicitValue.self))
                        if mode == "validation" { throw ImplicitProbe.invalidResult }
                        return row.value
                    }
                }
            }
            if mode == "cancel" {
                let limit = ContinuousClock.now + .seconds(3)
                var active = false
                while .now < limit {
                    active = try await control.raw("""
                        SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid()
                            AND state='active' AND query LIKE \(bind: "%" + message + "%") AND query LIKE '%pg_sleep%') AS active
                        """).first(decoding: ImplicitActive.self)?.active == true
                    if active { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(active)
                task.cancel()
            }
            let result = await task.result
            switch (mode, result) {
            case ("success", .success(let value)): #expect(value == 1)
            case ("constraint", .failure(let error)):
                #expect((error as? PSQLError)?.serverInfo?[.sqlState] == "23514")
            case ("late", .failure(let error)), ("validation", .failure(let error)),
                 ("deadline", .failure(let error)), ("cancel", .failure(let error)):
                #expect(error is V2RoomTransactionOutcomeUnknown)
            default: Issue.record("unexpected implicit outcome for \(mode)")
            }
            if mode == "deadline" { #expect(started.duration(to: .now) < .seconds(2)) }
            #expect(metrics.sendOperationBatchMetricsSnapshot().stages[.ownerSingleStatement]?.count == 1)
            #expect(sqlCount() - before == 1) // No BEGIN, COMMIT, or SQL confirmation probe.
            let counts = try #require(try await control.raw("""
                SELECT (SELECT count(*) FROM \(unsafeRaw: message)) AS messages,
                       (SELECT count(*) FROM \(unsafeRaw: completion)) AS completions
                """).first(decoding: ImplicitCounts.self))
            #expect(counts.messages == counts.completions)
            if mode == "success" || mode == "validation" { #expect(counts.messages == 1) }
            if mode == "constraint" || mode == "late" { #expect(counts.messages == 0) }
            try await control.raw("DROP TABLE \(unsafeRaw: completion), \(unsafeRaw: message)").run()
            tablesCreated = false
            if mode == "late" { try await control.raw("DROP FUNCTION \(unsafeRaw: trigger)()").run() }
            try await resources.shutdown()
        } catch {
            if tablesCreated { try? await control.raw("DROP TABLE IF EXISTS \(unsafeRaw: completion), \(unsafeRaw: message) CASCADE").run() }
            if mode == "late" { try? await control.raw("DROP FUNCTION IF EXISTS \(unsafeRaw: trigger)()").run() }
            try? await resources.shutdown()
            throw error
        }
    }
}
private enum ImplicitProbe: Error { case invalidResult }
private struct ImplicitValue: Decodable, Sendable { let value: Int64 }
private struct ImplicitActive: Decodable { let active: Bool }
private struct ImplicitCounts: Decodable { let messages: Int64; let completions: Int64 }
