@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing

@Suite("V2 room activation transaction deadline")
struct V2RoomActivationTransactionDeadlineTests {
    @Test("PG16 borrowed connection enforces total deadline and commit uncertainty",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func physicalDeadlineAndCommitClassification() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        let singleID = DatabaseID(string: "deadline-one-connection")
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4),
            as: .psql, isDefault: true)
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 1),
            as: singleID)
        let database = resources.database(.psql)
        let singleConnectionDatabase = resources.database(singleID)
        let sql = try #require(database as? any SQLDatabase)
        let timeouts = try V2RoomActivationSQLTimeouts(lockMilliseconds: 1_000,
            statementMilliseconds: 1_000, idleTransactionMilliseconds: 1_000)
        do {
            guard try await sql.raw("SELECT to_regclass('public.v2_actor_deadline_probe') IS NOT NULL AS value")
                .first(decoding: DeadlineBool.self)?.value == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await sql.raw("""
                CREATE TABLE public.v2_actor_deadline_probe (id integer PRIMARY KEY)
                """).run()

            let committed: Int = try await v2WithRoomActivationTransaction(
                database: database, deadline: .now + .seconds(2), timeouts: timeouts) { borrowed in
                let connection = try deadlineSQL(borrowed)
                try await connection.raw("INSERT INTO public.v2_actor_deadline_probe VALUES (1)").run()
                return 17
            }
            #expect(committed == 17)
            #expect(try await count(id: 1, sql: sql) == 1)

            let distinctTimeouts = try V2RoomActivationSQLTimeouts(lockMilliseconds: 75,
                statementMilliseconds: 250, idleTransactionMilliseconds: 400)
            let settings: DeadlineTimeoutSettings = try await v2WithRoomActivationTransaction(
                database: database, deadline: .now + .seconds(2), timeouts: distinctTimeouts) { borrowed in
                try #require(try await deadlineSQL(borrowed).raw("""
                    SELECT current_setting('lock_timeout') AS lock_timeout,
                           current_setting('statement_timeout') AS statement_timeout,
                           current_setting('idle_in_transaction_session_timeout') AS idle_timeout
                    """).first(decoding: DeadlineTimeoutSettings.self))
            }
            #expect(settings.lockTimeout == "75ms")
            #expect(settings.statementTimeout == "250ms")
            #expect(settings.idleTimeout == "400ms")

            await #expect(throws: V2RoomCallFailure.rolledBack(.deadlineExceeded)) {
                try await V2RoomSQLDeadline.withDeadline(.now + .milliseconds(270)) {
                    _ = try await v2WithRoomScopedTransaction(database: database,
                        timeouts: timeouts) { borrowed in
                        let connection = try deadlineSQL(borrowed)
                        try await connection.raw("INSERT INTO public.v2_actor_deadline_probe VALUES (8)").run()
                        try await connection.raw("SELECT pg_sleep(0.14)").run()
                        try await connection.raw("SELECT pg_sleep(0.14)").run()
                    }
                }
            }
            #expect(try await count(id: 8, sql: sql) == 0)

            // The body can return after the watchdog has closed its borrowed
            // connection but before COMMIT dispatch. That is a proved
            // rollback, even though the legacy attempt marker saw a return.
            await #expect(throws: V2RoomCallFailure.rolledBack(.deadlineExceeded)) {
                try await V2RoomSQLDeadline.withDeadline(.now + .milliseconds(100)) {
                    _ = try await v2WithPostgresTransactionRetry(database: database,
                        maximumRetryCount: 0, classifyCommitFailure: true,
                        useRoomDeadline: true) { borrowed in
                        try await deadlineSQL(borrowed).raw(
                            "INSERT INTO public.v2_actor_deadline_probe VALUES (10)").run()
                        try await Task.sleep(for: .milliseconds(180))
                    }
                }
            }
            #expect(try await count(id: 10, sql: sql) == 0)

            try await sql.raw("CREATE SEQUENCE public.v2_actor_deadline_retry_counter").run()
            try await sql.raw("""
                CREATE FUNCTION public.v2_actor_deadline_retry_probe() RETURNS void
                LANGUAGE plpgsql AS $$ BEGIN
                    IF nextval('public.v2_actor_deadline_retry_counter') = 1 THEN
                        PERFORM pg_sleep(0.22);
                        RAISE EXCEPTION 'retry this complete transaction' USING ERRCODE = '40001';
                    END IF;
                    PERFORM pg_sleep(0.22);
                END; $$
                """).run()
            await #expect(throws: V2RoomCallFailure.rolledBack(.deadlineExceeded)) {
                try await V2RoomSQLDeadline.withDeadline(.now + .milliseconds(350)) {
                    _ = try await v2WithPostgresTransactionRetry(database: database,
                        maximumRetryCount: 1, useRoomDeadline: true) { borrowed in
                        let connection = try deadlineSQL(borrowed)
                        try await connection.raw("SELECT public.v2_actor_deadline_retry_probe()").run()
                        try await connection.raw("INSERT INTO public.v2_actor_deadline_probe VALUES (9)").run()
                    }
                }
            }
            #expect(try await count(id: 9, sql: sql) == 0)
            #expect(try await sql.raw("SELECT last_value AS value FROM public.v2_actor_deadline_retry_counter")
                .first(decoding: DeadlineCount.self)?.value == 2)
            await #expect(throws: V2RoomCallFailure.rolledBack(.unavailable)) {
                _ = try await v2WithPostgresTransactionRetry(database: database,
                    maximumRetryCount: 0, useRoomDeadline: true) { borrowed in
                    try await deadlineSQL(borrowed).raw("""
                        DO $$ BEGIN RAISE EXCEPTION 'retry exhausted' USING ERRCODE = '40001'; END $$
                        """).run()
                }
            }

            let borrowedReady = AsyncStream<Void>.makeStream()
            let poolHolder = Task {
                try await singleConnectionDatabase.withConnection { borrowed in
                    borrowedReady.continuation.yield(())
                    try await deadlineSQL(borrowed).raw("SELECT pg_sleep(0.45)").run()
                }
            }
            for await _ in borrowedReady.stream { break }
            let enteredBody = Mutex(false)
            await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) {
                _ = try await v2WithRoomActivationTransaction(
                    database: singleConnectionDatabase,
                    deadline: .now + .milliseconds(120), timeouts: timeouts) { _ in
                    enteredBody.withLock { $0 = true }
                }
            }
            try await poolHolder.value
            #expect(enteredBody.withLock { !$0 })

            // Each statement is below statement_timeout; their sum crosses
            // the monotonic transaction deadline. The connection must close.
            await #expect(throws: V2RoomCallFailure.rolledBack(.deadlineExceeded)) {
                _ = try await v2WithRoomActivationTransaction(
                    database: database, deadline: .now + .milliseconds(270),
                    timeouts: timeouts) { borrowed in
                    let connection = try deadlineSQL(borrowed)
                    try await connection.raw("INSERT INTO public.v2_actor_deadline_probe VALUES (2)").run()
                    try await connection.raw("SELECT pg_sleep(0.13)").run()
                    try await connection.raw("SELECT pg_sleep(0.13)").run()
                    try await connection.raw("SELECT pg_sleep(0.13)").run()
                }
            }
            #expect(try await count(id: 2, sql: sql) == 0)

            let advisoryKey: Int64 = Int64.random(in: 100_000...Int64.max)
            let ready = AsyncStream<Void>.makeStream()
            let holder = Task {
                try await database.withConnection { borrowed in
                    let connection = try deadlineSQL(borrowed)
                    try await connection.raw("SELECT pg_advisory_lock(\(bind: advisoryKey))").run()
                    ready.continuation.yield(())
                    try await Task.sleep(for: .milliseconds(650))
                    try await connection.raw("SELECT pg_advisory_unlock(\(bind: advisoryKey))").run()
                }
            }
            for await _ in ready.stream { break }
            await #expect(throws: V2RoomCallFailure.rolledBack(.deadlineExceeded)) {
                _ = try await v2WithRoomActivationTransaction(
                    database: database, deadline: .now + .milliseconds(180),
                    timeouts: timeouts) { borrowed in
                    let connection = try deadlineSQL(borrowed)
                    try await connection.raw("INSERT INTO public.v2_actor_deadline_probe VALUES (3)").run()
                    try await connection.raw("SELECT pg_advisory_xact_lock(\(bind: advisoryKey))").run()
                }
            }
            try await holder.value
            #expect(try await count(id: 3, sql: sql) == 0)

            let sqlTimeoutKey: Int64 = Int64.random(in: 100_000...Int64.max)
            let sqlTimeoutReady = AsyncStream<Void>.makeStream()
            let sqlTimeoutHolder = Task {
                try await database.withConnection { borrowed in
                    let connection = try deadlineSQL(borrowed)
                    try await connection.raw("SELECT pg_advisory_lock(\(bind: sqlTimeoutKey))").run()
                    sqlTimeoutReady.continuation.yield(())
                    try await Task.sleep(for: .milliseconds(300))
                    try await connection.raw("SELECT pg_advisory_unlock(\(bind: sqlTimeoutKey))").run()
                }
            }
            for await _ in sqlTimeoutReady.stream { break }
            let shortLockTimeout = try V2RoomActivationSQLTimeouts(lockMilliseconds: 75,
                statementMilliseconds: 1_000, idleTransactionMilliseconds: 1_000)
            await #expect(throws: V2RoomCallFailure.rolledBack(.unavailable)) {
                _ = try await v2WithRoomActivationTransaction(database: database,
                    deadline: .now + .seconds(1), timeouts: shortLockTimeout) { borrowed in
                    let connection = try deadlineSQL(borrowed)
                    try await connection.raw("INSERT INTO public.v2_actor_deadline_probe VALUES (11)").run()
                    try await connection.raw("SELECT pg_advisory_xact_lock(\(bind: sqlTimeoutKey))").run()
                }
            }
            try await sqlTimeoutHolder.value
            #expect(try await count(id: 11, sql: sql) == 0)

            let cancellation = Task {
                try await v2WithRoomActivationTransaction(database: database,
                    deadline: .now + .seconds(3), timeouts: timeouts) { borrowed in
                    let connection = try deadlineSQL(borrowed)
                    try await connection.raw("INSERT INTO public.v2_actor_deadline_probe VALUES (4)").run()
                    try await connection.raw("SELECT pg_sleep(1)").run()
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            cancellation.cancel()
            await #expect(throws: V2RoomCallFailure.rolledBack(.cancelled)) {
                try await cancellation.value
            }
            #expect(try await count(id: 4, sql: sql) == 0)

            try await sql.raw("""
                CREATE FUNCTION public.v2_actor_deadline_commit_sleep() RETURNS trigger
                LANGUAGE plpgsql AS $$ BEGIN
                    IF NEW.id = 6 THEN
                        RAISE EXCEPTION 'injected serialization rollback' USING ERRCODE = '40001';
                    END IF;
                    PERFORM pg_sleep(1);
                    RETURN NEW;
                END; $$
                """).run()
            try await sql.raw("""
                CREATE CONSTRAINT TRIGGER v2_actor_deadline_commit_sleep
                AFTER INSERT ON public.v2_actor_deadline_probe
                DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
                WHEN (NEW.id IN (5, 6, 7))
                EXECUTE FUNCTION public.v2_actor_deadline_commit_sleep()
                """).run()
            let commitFault = Task {
                try await v2WithRoomActivationTransaction(database: database,
                    deadline: .now + .milliseconds(450), timeouts: timeouts) { borrowed in
                    let connection = try deadlineSQL(borrowed)
                    try await connection.raw("INSERT INTO public.v2_actor_deadline_probe VALUES (5)").run()
                }
            }
            var sawCommit = false
            for _ in 0..<30 {
                let row = try await sql.raw("""
                    SELECT EXISTS (
                        SELECT 1 FROM pg_stat_activity
                        WHERE datname = current_database() AND state = 'active'
                          AND query = 'COMMIT'
                    ) AS value
                    """).first(decoding: DeadlineBool.self)
                if row?.value == true { sawCommit = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(sawCommit)
            // Fault injection closes the client connection while a deferred
            // COMMIT trigger sleeps. This proves classification of missing ACK;
            // it does not claim the server committed or model true ACK loss.
            await #expect(throws: V2RoomTransactionOutcomeUnknown.self) {
                try await commitFault.value
            }

            // A server SQLSTATE 40001 at deferred COMMIT proves rollback and
            // stays retryable even though it arrives after body success.
            do {
                _ = try await v2WithRoomActivationTransaction(database: database,
                    deadline: .now + .seconds(2), timeouts: timeouts) { borrowed in
                    try await deadlineSQL(borrowed).raw("""
                        INSERT INTO public.v2_actor_deadline_probe VALUES (6)
                        """).run()
                }
                Issue.record("injected serialization failure unexpectedly committed")
            } catch {
                #expect(v2PostgresFailureDisposition(error) == .retryTransaction)
            }
            #expect(try await count(id: 6, sql: sql) == 0)

            let commitBackend = Mutex<Int32?>(nil)
            let cancelledCommit = Task {
                try await v2WithRoomActivationTransaction(database: database,
                    deadline: .now + .seconds(2), timeouts: timeouts) { borrowed in
                    let connection = try deadlineSQL(borrowed)
                    let pid = try await connection.raw("SELECT pg_backend_pid() AS value")
                        .first(decoding: DeadlinePID.self)?.value
                    commitBackend.withLock { $0 = pid }
                    try await connection.raw("""
                        INSERT INTO public.v2_actor_deadline_probe VALUES (7)
                        """).run()
                }
            }
            var cancelledCommitReached = false
            for _ in 0..<100 {
                if let pid = commitBackend.withLock({ $0 }),
                   try await sql.raw("""
                        SELECT EXISTS (
                            SELECT 1 FROM pg_stat_activity
                            WHERE pid = \(bind: pid) AND state = 'active' AND query = 'COMMIT'
                        ) AS value
                        """).first(decoding: DeadlineBool.self)?.value == true {
                    cancelledCommitReached = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(cancelledCommitReached)
            cancelledCommit.cancel()
            await #expect(throws: V2RoomTransactionOutcomeUnknown.self) {
                try await cancelledCommit.value
            }

            try await sql.raw("DROP TABLE public.v2_actor_deadline_probe").run()
            try await sql.raw("DROP FUNCTION public.v2_actor_deadline_commit_sleep()").run()
            try await sql.raw("DROP FUNCTION public.v2_actor_deadline_retry_probe()").run()
            try await sql.raw("DROP SEQUENCE public.v2_actor_deadline_retry_counter").run()
            try await resources.shutdown()
        } catch {
            try? await sql.raw("DROP TABLE IF EXISTS public.v2_actor_deadline_probe CASCADE").run()
            try? await sql.raw("DROP FUNCTION IF EXISTS public.v2_actor_deadline_commit_sleep()").run()
            try? await sql.raw("DROP FUNCTION IF EXISTS public.v2_actor_deadline_retry_probe()").run()
            try? await sql.raw("DROP SEQUENCE IF EXISTS public.v2_actor_deadline_retry_counter").run()
            try? await resources.shutdown()
            throw error
        }
    }
}

private func deadlineSQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return sql
}

private func count(id: Int, sql: any SQLDatabase) async throws -> Int64 {
    try await sql.raw("SELECT count(*)::bigint AS value FROM public.v2_actor_deadline_probe WHERE id = \(bind: id)")
        .first(decoding: DeadlineCount.self)?.value ?? -1
}

private struct DeadlineBool: Decodable { let value: Bool }
private struct DeadlineCount: Decodable { let value: Int64 }
private struct DeadlinePID: Decodable { let value: Int32 }
private struct DeadlineTimeoutSettings: Decodable, Sendable {
    let lockTimeout: String
    let statementTimeout: String
    let idleTimeout: String

    enum CodingKeys: String, CodingKey {
        case lockTimeout = "lock_timeout"
        case statementTimeout = "statement_timeout"
        case idleTimeout = "idle_timeout"
    }
}
