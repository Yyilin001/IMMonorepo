import FluentKit
import Foundation
import IMV2ServerContracts
import SQLKit

public struct PostgresV2AdminStore: V2AdminStore {
    private let database: any Database
    public init(database: any Database) { self.database = database }
    private var sql: any SQLDatabase {
        get throws { guard let sql = database as? any SQLDatabase else { throw V2AdminError.unavailable }; return sql }
    }

    public func verifySchema() async throws {
        struct Version: Decodable { let version: Int }
        guard try await sql.raw("SELECT version FROM im_admin.schema_version").all(decoding: Version.self).map(\.version) == [1] else { throw V2AdminError.unavailable }
        // 实际读取依赖列；缺失表或列应在绑定监听前失败。
        _ = try await sql.raw("SELECT digest, username, credential_version, expires_at FROM im_admin.sessions LIMIT 0").all()
        _ = try await sql.raw("SELECT bucket, window_started_at, attempts FROM im_admin.login_budgets LIMIT 0").all()
        _ = try await sql.raw("SELECT sequence, operation_id, principal, action, target_user_id, reason, outcome, occurred_at, completed_at FROM im_admin.audit LIMIT 0").all()
    }

    public func consumeLoginBudget(username: String?, now: Date) async throws -> Bool {
        // 未知名称共享一个桶，避免攻击者创建无界数据库键；全局预算同时限制分布式猜测。
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw V2AdminError.unavailable }
            struct Count: Decodable { let attempts: Int }
            var allowed = true
            for (bucket, maximum) in [("global", 60), ("account:" + (username ?? "unknown"), 5)] {
                let row = try await sql.raw("""
                    INSERT INTO im_admin.login_budgets(bucket, window_started_at, attempts) VALUES (\(bind: bucket), \(bind: now), 1)
                    ON CONFLICT (bucket) DO UPDATE SET
                    attempts = CASE WHEN im_admin.login_budgets.window_started_at <= \(bind: now.addingTimeInterval(-60)) THEN 1 ELSE LEAST(im_admin.login_budgets.attempts + 1, 1000) END,
                    window_started_at = CASE WHEN im_admin.login_budgets.window_started_at <= \(bind: now.addingTimeInterval(-60)) THEN EXCLUDED.window_started_at ELSE im_admin.login_budgets.window_started_at END
                    RETURNING attempts
                    """).first(decoding: Count.self)
                allowed = allowed && (row?.attempts ?? Int.max) <= maximum
            }
            return allowed
        }
    }

    public func createSession(_ session: V2AdminSession, replacing digest: String?, now: Date) async throws {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw V2AdminError.unavailable }
            // 每个管理员只保留最近一次登录；数据库锁使并发登录也满足该约束。
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "admin-session:" + session.username), 0))").run()
            try await sql.raw("DELETE FROM im_admin.sessions WHERE expires_at <= \(bind: now) OR username = \(bind: session.username)").run()
            if let digest { try await sql.raw("DELETE FROM im_admin.sessions WHERE digest = \(bind: digest)").run() }
            try await sql.raw("INSERT INTO im_admin.sessions(digest, username, credential_version, expires_at) VALUES (\(bind: session.digest), \(bind: session.username), \(bind: session.credentialVersion), \(bind: session.expiresAt))").run()
            try await Self.record(on: sql, principal: "admin:" + session.username, action: "login", target: nil, outcome: "succeeded", now: now)
        }
    }

    public func session(digest: String, now: Date) async throws -> V2AdminSession? {
        struct Row: Decodable { let digest: String; let username: String; let credential_version: String; let expires_at: Date }
        guard let row = try await sql.raw("SELECT digest, username, credential_version, expires_at FROM im_admin.sessions WHERE digest = \(bind: digest) AND expires_at > \(bind: now)").first(decoding: Row.self) else { return nil }
        return .init(digest: row.digest, username: row.username, credentialVersion: row.credential_version, expiresAt: row.expires_at)
    }

    public func revokeSession(digest: String, principal: String, now: Date) async throws {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw V2AdminError.unavailable }
            try await sql.raw("DELETE FROM im_admin.sessions WHERE digest = \(bind: digest)").run()
            try await Self.record(on: sql, principal: principal, action: "logout", target: nil, outcome: "succeeded", now: now)
        }
    }

    public func users(query: String, after: UUID?, limit: Int) async throws -> [V2AdminUser] {
        // 精确 UUID/公开账号检索；名称支持字面子串，绑定参数且不解释 LIKE 通配符。
        let uuid = UUID(uuidString: query)
        let rows = try await sql.raw("""
            SELECT p.user_id, p.public_handle, p.display_name, p.state, p.account_kind, p.created_at, d.disabled_at,
              (SELECT count(*)::integer FROM im_v2.auth_devices a WHERE a.user_id = p.user_id AND a.revoked_at IS NULL AND a.session_expires_at > CURRENT_TIMESTAMP) AS active_devices
            FROM im_v2.public_user_profiles p LEFT JOIN im_v2.account_disables d USING(user_id)
            WHERE (\(bind: query) = '' OR p.user_id = \(bind: uuid)::uuid OR p.public_handle = \(bind: query.lowercased()) OR strpos(lower(p.display_name), lower(\(bind: query))) > 0)
              AND (\(bind: after)::uuid IS NULL OR p.user_id > \(bind: after)::uuid)
            ORDER BY p.user_id LIMIT \(bind: limit)
            """).all(decoding: UserRow.self)
        return rows.map(\.value)
    }

    public func user(id: UUID) async throws -> V2AdminUser? {
        try await sql.raw("""
            SELECT p.user_id, p.public_handle, p.display_name, p.state, p.account_kind, p.created_at, d.disabled_at,
              (SELECT count(*)::integer FROM im_v2.auth_devices a WHERE a.user_id = p.user_id AND a.revoked_at IS NULL AND a.session_expires_at > CURRENT_TIMESTAMP) AS active_devices
            FROM im_v2.public_user_profiles p LEFT JOIN im_v2.account_disables d USING(user_id) WHERE p.user_id = \(bind: id)
            """).first(decoding: UserRow.self)?.value
    }

    public func record(principal: String?, action: String, target: UUID?, outcome: String, now: Date) async throws {
        try await Self.record(on: sql, principal: principal, action: action, target: target, outcome: outcome, now: now)
    }
    private static func record(on sql: any SQLDatabase, principal: String?, action: String, target: UUID?, outcome: String, now: Date) async throws {
        try await sql.raw("INSERT INTO im_admin.audit(operation_id, principal, action, target_user_id, outcome, occurred_at, completed_at) VALUES (\(bind: UUID()), \(bind: principal), \(bind: action), \(bind: target), \(bind: outcome), \(bind: now), \(bind: now))").run()
    }

    public func prepareDisable(id: UUID, principal: String, target: UUID, reason: V2AccountDisableReason, now: Date) async throws -> V2AdminAudit {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw V2AdminError.unavailable }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "admin-operation:" + id.uuidString), 0))").run()
            if let prior = try await sql.raw("SELECT * FROM im_admin.audit WHERE operation_id = \(bind: id)").first(decoding: AuditRow.self) {
                guard prior.principal == principal, prior.target_user_id == target, prior.reason == reason.rawValue, prior.action == "account_disable" else { throw V2AdminError.conflict }
                return prior.value
            }
            guard try await sql.raw("SELECT user_id FROM im_v2.public_user_profiles WHERE user_id = \(bind: target)").first() != nil else { throw V2AdminError.notFound }
            guard let row = try await sql.raw("""
                INSERT INTO im_admin.audit(operation_id, principal, action, target_user_id, reason, outcome, occurred_at)
                VALUES (\(bind: id), \(bind: principal), 'account_disable', \(bind: target), \(bind: reason.rawValue), 'pending', \(bind: now)) RETURNING *
                """).first(decoding: AuditRow.self) else { throw V2AdminError.unavailable }
            return row.value
        }
    }

    public func finishDisable(id: UUID, outcome: String, now: Date) async throws -> V2AdminAudit {
        try await sql.raw("UPDATE im_admin.audit SET outcome = \(bind: outcome), completed_at = \(bind: now) WHERE operation_id = \(bind: id) AND outcome = 'pending'").run()
        guard let row = try await audit(id: id), row.outcome == outcome else { throw V2AdminError.conflict }
        return row
    }

    public func audit(id: UUID) async throws -> V2AdminAudit? {
        try await sql.raw("SELECT * FROM im_admin.audit WHERE operation_id = \(bind: id)").first(decoding: AuditRow.self)?.value
    }
    public func audits(before: Int64?, target: UUID?, limit: Int) async throws -> [V2AdminAudit] {
        try await sql.raw("""
            SELECT * FROM im_admin.audit WHERE (\(bind: before)::bigint IS NULL OR sequence < \(bind: before)::bigint)
            AND (\(bind: target)::uuid IS NULL OR target_user_id = \(bind: target)::uuid)
            ORDER BY sequence DESC LIMIT \(bind: limit)
            """).all(decoding: AuditRow.self).map(\.value)
    }
}

private struct UserRow: Decodable {
    let user_id: UUID; let public_handle: String; let display_name: String; let state: String
    let account_kind: String; let created_at: Date; let disabled_at: Date?; let active_devices: Int
    var value: V2AdminUser { .init(userID: user_id, publicHandle: public_handle, displayName: display_name, state: state,
        accountKind: account_kind, createdAt: created_at, disabledAt: disabled_at, activeDevices: active_devices) }
}
private struct AuditRow: Decodable {
    let sequence: Int64; let operation_id: UUID; let principal: String?; let action: String; let target_user_id: UUID?
    let reason: String?; let outcome: String; let occurred_at: Date; let completed_at: Date?
    var value: V2AdminAudit { .init(sequence: String(sequence), operationID: operation_id, principal: principal, action: action,
        targetUserID: target_user_id, reason: reason, outcome: outcome, occurredAt: occurred_at, completedAt: completed_at) }
}
