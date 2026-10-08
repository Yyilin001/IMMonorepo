import Foundation
import Logging
import NIOCore
import NIOPosix
import PostgresKit
import PostgresNIO
import Testing

@Suite(.serialized)
struct V2AutomaticPreparedQueryTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"] != nil
            && ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
    }

    @Test(.enabled(if: Self.enabled))
    func readinessConfirmationPreservesQueuedCommandsAndTransactionState() async throws {
        try await withConnection { connection, logger in
            let slow: EventLoopFuture<PostgresQueryResult> = connection.query("SELECT pg_sleep(0.12)", logger: logger)
            let ready = connection.confirmReadyForQuery()
            let next: EventLoopFuture<PostgresQueryResult> = connection.query("SELECT 73::bigint", logger: logger)
            let nextReady = connection.confirmReadyForQuery()
            _ = try await slow.get()
            #expect(try await ready.get() == .idle)
            #expect(try await next.get().rows[0].decode(Int64.self) == 73)
            #expect(try await nextReady.get() == .idle)
            _ = try await connection.query("BEGIN", logger: logger).get()
            #expect(try await connection.confirmReadyForQuery().get() == .inTransaction)
            do { _ = try await connection.query("SELECT 1/0", logger: logger).get(); Issue.record("expected SQL error") }
            catch {}
            #expect(try await connection.confirmReadyForQuery().get() == .inFailedTransaction)
            _ = try await connection.query("ROLLBACK", logger: logger).get()
            #expect(try await connection.confirmReadyForQuery().get() == .idle)
        }
    }

    @Test(.enabled(if: Self.enabled))
    func implicitCommitConfirmationWaitsForDeferredCommitWork() async throws {
        try await withConnection { connection, logger in
            _ = try await connection.query("CREATE TEMP TABLE readiness_commit_test (value bigint)", logger: logger).get()
            _ = try await connection.query("""
                CREATE FUNCTION pg_temp.readiness_commit_delay() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_sleep(0.2); RETURN NEW; END $$
                """, logger: logger).get()
            _ = try await connection.query("""
                CREATE CONSTRAINT TRIGGER readiness_commit_delay AFTER INSERT ON readiness_commit_test
                DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pg_temp.readiness_commit_delay()
                """, logger: logger).get()
            #expect(try await connection.confirmReadyForQuery().get() == .idle)
            let start = ContinuousClock.now
            let inserted: EventLoopFuture<PostgresQueryResult> = connection.query("INSERT INTO readiness_commit_test VALUES (41) RETURNING value", logger: logger)
            let ready = connection.confirmReadyForQuery()
            #expect(try await inserted.get().rows[0].decode(Int64.self) == 41)
            #expect(try await ready.get() == .idle)
            let confirmed = ContinuousClock.now
            #expect(start.duration(to: confirmed) >= .milliseconds(180))
            let row = try await connection.query("SELECT count(*)::bigint FROM readiness_commit_test", logger: logger).get()
            #expect(try row.rows[0].decode(Int64.self) == 1)
        }
    }

    @Test(.enabled(if: Self.enabled))
    func lateImplicitCommitFailureDoesNotConfirmSuccess() async throws {
        try await withConnection { connection, logger in
            _ = try await connection.query("CREATE TEMP TABLE readiness_failure_test (value bigint)", logger: logger).get()
            _ = try await connection.query("""
                CREATE FUNCTION pg_temp.readiness_commit_failure() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_sleep(0.15); RAISE EXCEPTION 'test deferred commit failure'; END $$
                """, logger: logger).get()
            _ = try await connection.query("""
                CREATE CONSTRAINT TRIGGER readiness_commit_failure AFTER INSERT ON readiness_failure_test
                DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pg_temp.readiness_commit_failure()
                """, logger: logger).get()
            _ = try await connection.confirmReadyForQuery().get()
            let inserted: EventLoopFuture<PostgresQueryResult> = connection.query("INSERT INTO readiness_failure_test VALUES (41) RETURNING value", logger: logger)
            let ready = connection.confirmReadyForQuery()
            #expect(try await inserted.get().rows[0].decode(Int64.self) == 41)
            var failed = false
            do { _ = try await ready.get() } catch { failed = true }
            #expect(failed)
        }
    }

    @Test(.enabled(if: Self.enabled))
    func closingConnectionSettlesPendingAndFutureConfirmations() async throws {
        try await withConnection { connection, logger in
            let slow: EventLoopFuture<PostgresQueryResult> = connection.query("SELECT pg_sleep(1)", logger: logger)
            let ready = connection.confirmReadyForQuery()
            try await connection.close().get()
            var failed = false
            do { _ = try await ready.get() } catch { failed = true }
            #expect(failed)
            _ = try? await slow.get()
            failed = false
            do { _ = try await connection.confirmReadyForQuery().get() } catch { failed = true }
            #expect(failed)
        }
    }

    @Test(.enabled(if: Self.enabled))
    func cachedBindingsAndCapacity() async throws {
        try await withConnection { connection, logger in
            for value in 1...8 {
                let result = try await connection.query("/* imv2_cache_test */ SELECT \(value) AS value", logger: logger).get()
                #expect(try result.rows[0].decode(Int64.self) == Int64(value))
            }
            let count = try await connection.query("SELECT count(*)::bigint FROM pg_prepared_statements WHERE name LIKE 'nio-postgres-auto-%'", logger: logger).get()
            #expect(try count.rows[0].decode(Int64.self) == 1)
            // Different SQL and parameter type must never share a prepared name.
            let text = try await connection.query("/* imv2_cache_test */ SELECT \("different") AS value", logger: logger).get()
            #expect(try text.rows[0].decode(String.self) == "different")
            _ = try await connection.query("/* imv2_cache_test */ SELECT 123::bigint", logger: logger).get()
            let capped = try await connection.query("SELECT count(*)::bigint FROM pg_prepared_statements WHERE name LIKE 'nio-postgres-auto-%'", logger: logger).get()
            #expect(try capped.rows[0].decode(Int64.self) == 2)
        }
    }

    @Test(.enabled(if: Self.enabled))
    func failedExecutionRollsBackAndCachedStatementRemainsUsable() async throws {
        try await withConnection { connection, logger in
            _ = try await connection.query("CREATE TEMP TABLE prepared_query_test (value bigint CHECK(value >= 0));", logger: logger).get()
            _ = try await connection.query("INSERT INTO prepared_query_test VALUES (0)", logger: logger).get()
            _ = try await connection.query("BEGIN", logger: logger).get()
            var failed = false
            do {
                _ = try await connection.query("/* imv2_cache_test */ UPDATE prepared_query_test SET value = \(-1)::bigint", logger: logger).get()
            } catch { failed = true }
            #expect(failed)
            _ = try await connection.query("ROLLBACK", logger: logger).get()
            _ = try await connection.query("BEGIN", logger: logger).get()
            _ = try await connection.query("/* imv2_cache_test */ UPDATE prepared_query_test SET value = \(42)::bigint", logger: logger).get()
            _ = try await connection.query("COMMIT", logger: logger).get()
            let result = try await connection.query("SELECT value FROM prepared_query_test", logger: logger).get()
            #expect(try result.rows[0].decode(Int64.self) == 42)
        }
    }

    private func withConnection(_ body: (PostgresConnection, Logger) async throws -> Void) async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"])
        var configuration = try SQLPostgresConfiguration(url: url).coreConfiguration
        configuration.options.preparedQueryCacheCapacity = 2
        configuration.options.preparedQuerySQLPrefixes = ["/* imv2_cache_test */"]
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let logger = Logger(label: "imv2.prepared.query.tests")
        do {
            let connection = try await PostgresConnection.connect(on: group.next(), configuration: configuration, id: 1, logger: logger).get()
            do { try await body(connection, logger) }
            catch { try? await connection.close().get(); throw error }
            try await connection.close().get()
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
