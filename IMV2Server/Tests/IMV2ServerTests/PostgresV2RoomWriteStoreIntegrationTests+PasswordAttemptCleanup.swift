@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("password attempt cleanup is bounded and preserves live windows, locks and rollback clocks")
    func expiredPasswordAttemptsAreCleanedWithoutResettingLiveBudgets() async throws {
        guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: url), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            try await installSchema(on: sql)
            let now = Date(), old = now.addingTimeInterval(-120)
            let policy = try V2PasswordLoginRateLimitPolicy(maximumFailures: 3, window: 60, lockout: 180)
            let missing = "missing-" + UUID().uuidString.lowercased()
            #expect(try await V2PostgresPasswordLoginAttemptLimiter(database: database, policy: policy)
                .consumeAttempt(accountHandle: missing) == nil)
            try await sql.raw("UPDATE im_v2.account_password_login_rate_limits SET window_started_at=\(bind: old),updated_at=\(bind: old) WHERE account_handle=\(bind: missing)").run()
            for index in 0..<8 {
                try await sql.raw("INSERT INTO im_v2.account_password_login_rate_limits(account_handle,window_started_at,failure_count,updated_at) VALUES(\(bind: "expired-\(index)"),\(bind: old),1,\(bind: old))").run()
            }
            let protected: [(String, Date, Date, Date?)] = [
                ("live-window", now.addingTimeInterval(-30), now.addingTimeInterval(-30), nil),
                ("live-lock", old, old, now.addingTimeInterval(60)),
                ("clock-rollback", now.addingTimeInterval(60), old, nil),
                ("recent-attempt", old, now.addingTimeInterval(-10), nil),
            ]
            for (handle, start, updated, blocked) in protected {
                try await sql.raw("INSERT INTO im_v2.account_password_login_rate_limits(account_handle,window_started_at,failure_count,updated_at,blocked_until) VALUES(\(bind: handle),\(bind: start),2,\(bind: updated),\(bind: blocked))").run()
            }
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database, policy: policy)
            var removed = 0
            for _ in 0..<9 {
                let deleted = try await limiter.purgeExpired(now: now, limit: 1)
                #expect(deleted <= 1)
                removed += deleted
            }
            #expect(removed == 9)
            #expect(try await count("im_v2.account_password_login_rate_limits", on: sql) == 4)
            #expect(try await count("im_v2.account_password_login_rate_limits WHERE failure_count = 2", on: sql) == 4)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }
}
