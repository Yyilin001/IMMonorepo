import Fluent
import Foundation
import IMV2Core
import SQLKit

public enum V2PublicIdentityDirectoryError: Error, Equatable, Sendable {
    case unavailable
    case rateLimited(retryAfterSeconds: Int)
}

public protocol V2PublicIdentityDirectoryReading: Sendable {
    func resolve(handle: V2PublicHandle, actorUserID: UserID) async throws -> V2PublicIdentity?
}

public protocol V2PublicIdentityAccountManaging: V2PublicIdentityDirectoryReading {
    func profile(for userID: UserID) async throws -> V2PublicIdentity?
    func updateDisplayName(for userID: UserID, displayName: String) async throws -> V2PublicIdentity
}

/// Account-edge directory backed solely by public-profile data. A target that
/// has blocked the caller resolves as nil, exactly like an absent handle. The
/// caller's own block is deliberately not hidden so it can be revoked later.
public struct V2PostgresPublicIdentityDirectory: V2PublicIdentityAccountManaging, Sendable {
    private let database: any Database
    private let policy: V2PublicIdentityLookupRateLimitPolicy
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        database: any Database,
        policy: V2PublicIdentityLookupRateLimitPolicy,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.policy = policy
        self.makeUUID = makeUUID
        self.now = now
    }

    public func resolve(
        handle: V2PublicHandle,
        actorUserID: UserID
    ) async throws -> V2PublicIdentity? {
        guard let actorUUID = UUID(uuidString: actorUserID.rawValue) else {
            throw V2PublicIdentityDirectoryError.unavailable
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2PublicIdentityDirectoryError.unavailable
            }
            try await consumeLookupBudget(sql: sql, actorUserID: actorUUID)
            guard let row = try await sql.raw("""
                SELECT p.user_id, p.public_handle, p.display_name, p.account_kind
                FROM im_v2.public_user_profiles p
                WHERE p.public_handle = \(bind: handle.rawValue)
                  AND p.state = 'active'
                  AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables d WHERE d.user_id = p.user_id)
                  AND NOT EXISTS (
                    SELECT 1 FROM im_v2.user_blocks b
                    WHERE b.blocker_user_id = p.user_id
                      AND b.blocked_user_id = \(bind: actorUUID)
                  )
                """).first(decoding: PublicIdentityRow.self),
                let userID = try? UserID(row.userID.uuidString),
                let accountKind = V2AccountKind(rawValue: row.accountKind),
                let profile = try? V2PublicIdentity(
                    userID: userID,
                    handle: .init(row.handle),
                    displayName: row.displayName,
                    accountKind: accountKind
                )
            else { return nil }
            return profile
        }
    }

    public func profile(for userID: UserID) async throws -> V2PublicIdentity? {
        guard let userUUID = UUID(uuidString: userID.rawValue),
              let sql = database as? any SQLDatabase
        else { throw V2PublicIdentityDirectoryError.unavailable }
        return try await profile(sql: sql, userID: userUUID)
    }

    /// Setting an identical name is a no-op. A changed name atomically writes
    /// a durable propagation source record for existing direct counterparts.
    public func updateDisplayName(
        for userID: UserID,
        displayName: String
    ) async throws -> V2PublicIdentity {
        guard let userUUID = UUID(uuidString: userID.rawValue) else {
            throw V2PublicIdentityDirectoryError.unavailable
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let current = try await profile(sql: sql, userID: userUUID)
            else { throw V2PublicIdentityDirectoryError.unavailable }
            let validated: V2PublicIdentity
            do {
                validated = try .init(
                    userID: userID,
                    handle: current.handle,
                    displayName: displayName,
                    accountKind: current.accountKind
                )
            } catch {
                throw V2PublicIdentityDirectoryError.unavailable
            }
            let changedAt = now()
            guard let updated = try await sql.raw("""
                UPDATE im_v2.public_user_profiles
                SET display_name = \(bind: validated.displayName), revision = revision + 1,
                    visibility_revision = visibility_revision + 1, updated_at = \(bind: changedAt)
                WHERE user_id = \(bind: userUUID) AND state = 'active'
                  AND display_name IS DISTINCT FROM \(bind: validated.displayName)
                RETURNING revision, updated_at
                """).first(decoding: UpdatedPublicIdentityRow.self) else {
                return current
            }
            try await sql.raw("""
                INSERT INTO im_v2.public_profile_update_outbox
                    (source_event_id, source_user_id, public_handle, display_name, account_kind, profile_state, revision, profile_updated_at, created_at)
                VALUES (\(bind: makeUUID()), \(bind: userUUID), \(bind: validated.handle.rawValue),
                    \(bind: validated.displayName), \(bind: validated.accountKind.rawValue), 'active',
                    \(bind: updated.revision), \(bind: updated.updatedAt), \(bind: changedAt))
                """).run()
            return validated
        }
    }

    private func consumeLookupBudget(sql: any SQLDatabase, actorUserID: UUID) async throws {
        let current = now()
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "v2-public-identity-lookup:" + actorUserID.uuidString), 0))").run()
        guard let existing = try await sql.raw("SELECT window_started_at, query_count FROM im_v2.public_identity_lookup_rate_limits WHERE actor_user_id = \(bind: actorUserID)").first(decoding: LookupRateLimitRow.self) else {
            try await sql.raw("INSERT INTO im_v2.public_identity_lookup_rate_limits (actor_user_id, window_started_at, query_count, updated_at) VALUES (\(bind: actorUserID), \(bind: current), 1, \(bind: current))").run()
            return
        }
        let elapsed = current.timeIntervalSince(existing.windowStartedAt)
        if elapsed >= policy.window {
            try await sql.raw("UPDATE im_v2.public_identity_lookup_rate_limits SET window_started_at = \(bind: current), query_count = 1, updated_at = \(bind: current) WHERE actor_user_id = \(bind: actorUserID)").run()
            return
        }
        guard existing.queryCount < policy.maximumQueries else {
            throw V2PublicIdentityDirectoryError.rateLimited(
                retryAfterSeconds: max(1, Int(ceil(policy.window - elapsed)))
            )
        }
        try await sql.raw("UPDATE im_v2.public_identity_lookup_rate_limits SET query_count = query_count + 1, updated_at = \(bind: current) WHERE actor_user_id = \(bind: actorUserID)").run()
    }

    private func profile(sql: any SQLDatabase, userID: UUID) async throws -> V2PublicIdentity? {
        guard let row = try await sql.raw("SELECT user_id, public_handle, display_name, account_kind FROM im_v2.public_user_profiles WHERE user_id = \(bind: userID) AND state = 'active' AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables WHERE user_id = \(bind: userID))").first(decoding: PublicIdentityRow.self),
              let profileUserID = try? UserID(row.userID.uuidString),
              let accountKind = V2AccountKind(rawValue: row.accountKind),
              let profile = try? V2PublicIdentity(
                  userID: profileUserID,
                  handle: .init(row.handle),
                  displayName: row.displayName,
                  accountKind: accountKind
              )
        else { return nil }
        return profile
    }
}

private struct PublicIdentityRow: Decodable {
    let userID: UUID
    let handle: String
    let displayName: String
    let accountKind: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case handle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
    }
}

private struct UpdatedPublicIdentityRow: Decodable {
    let revision: Int64
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case revision
        case updatedAt = "updated_at"
    }
}

private struct LookupRateLimitRow: Decodable {
    let windowStartedAt: Date
    let queryCount: Int

    enum CodingKeys: String, CodingKey {
        case windowStartedAt = "window_started_at"
        case queryCount = "query_count"
    }
}
