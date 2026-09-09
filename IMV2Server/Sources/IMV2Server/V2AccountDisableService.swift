import Fluent
import Foundation
import IMV2Core
import SQLKit

/// A bounded, auditable reason supplied by the separately authenticated
/// operator control plane. Free-form operator notes belong in the external
/// case-management system, never in the account database.
public enum V2AccountDisableReason: String, Codable, CaseIterable, Sendable {
    case userRequested = "user_requested"
    case credentialCompromise = "credential_compromise"
    case policyEnforcement = "policy_enforcement"
}

public struct V2AccountDisableCommand: Sendable {
    public let userID: UserID
    public let operationID: UUID
    public let reason: V2AccountDisableReason

    public init(userID: UserID, operationID: UUID, reason: V2AccountDisableReason) throws {
        guard UUID(uuidString: userID.rawValue) != nil else { throw V2AccountDisableError.invalidUserID }
        self.userID = userID
        self.operationID = operationID
        self.reason = reason
    }
}

public enum V2AccountDisableOutcome: Equatable, Sendable {
    case disabled(disabledAt: Date)
    case idempotent(disabledAt: Date)
    case alreadyDisabled(disabledAt: Date)
}

public enum V2AccountDisableError: Error, Equatable, Sendable {
    case invalidUserID
    case invalidOperatorPrincipal
    case operationConflict
    case unavailable
}

/// The operator boundary intentionally contains one destructive action only:
/// permanently disable one account. It cannot re-enable an account, delete
/// retained data, or accept raw SQL/batches. Recovery is a separately
/// specified product and audit workflow.
public protocol V2AccountDisabling: Sendable {
    func disable(_ command: V2AccountDisableCommand) async throws -> V2AccountDisableOutcome
}

public struct V2PostgresAccountDisableService: V2AccountDisabling, Sendable {
    private let database: any Database
    private let operatorPrincipal: String
    private let now: @Sendable () -> Date

    public init(
        database: any Database,
        operatorPrincipal: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal) else {
            throw V2AccountDisableError.invalidOperatorPrincipal
        }
        self.database = database
        self.operatorPrincipal = operatorPrincipal
        self.now = now
    }

    public func disable(_ command: V2AccountDisableCommand) async throws -> V2AccountDisableOutcome {
        guard let userUUID = UUID(uuidString: command.userID.rawValue) else {
            throw V2AccountDisableError.invalidUserID
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2AccountDisableError.unavailable }
            let occurredAt = now()
            // Credential issue/refresh uses this same lock before it returns
            // any credential. The ordering guarantees either a newly-issued
            // credential is revoked by this transaction or issuance observes
            // the disabled state and returns none.
            try await lockOperation(sql, operationID: command.operationID)
            try await lockAccountState(sql, userID: userUUID)

            if let prior = try await sql.raw("SELECT user_id, disabled_at FROM im_v2.account_disables WHERE operation_id = \(bind: command.operationID)").first(decoding: DisableRecord.self) {
                guard prior.userID == userUUID else { throw V2AccountDisableError.operationConflict }
                return .idempotent(disabledAt: prior.disabledAt)
            }
            if let prior = try await sql.raw("SELECT user_id, disabled_at FROM im_v2.account_disables WHERE user_id = \(bind: userUUID)").first(decoding: DisableRecord.self) {
                return .alreadyDisabled(disabledAt: prior.disabledAt)
            }

            guard v2PostgresTimestampCanEncode(occurredAt) else { throw V2AccountDisableError.unavailable }

            guard let persisted = try await sql.raw("""
                INSERT INTO im_v2.account_disables (user_id, operation_id, reason, operator_principal, disabled_at)
                VALUES (\(bind: userUUID), \(bind: command.operationID), \(bind: command.reason.rawValue), \(bind: operatorPrincipal), \(bind: occurredAt))
                RETURNING user_id, disabled_at
                """).first(decoding: DisableRecord.self) else { throw V2AccountDisableError.unavailable }
            guard try await sql.raw("""
                INSERT INTO im_v2.user_direct_send_policy_versions AS version (user_id, revision, updated_at)
                VALUES (\(bind: userUUID), 2, \(bind: occurredAt))
                ON CONFLICT (user_id) DO UPDATE
                SET revision = version.revision + 1, updated_at = EXCLUDED.updated_at
                WHERE version.revision < \(bind: Int64.max)
                RETURNING user_id
                """).first() != nil else { throw V2AccountDisableError.unavailable }
            try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at = COALESCE(revoked_at, \(bind: occurredAt)) WHERE user_id = \(bind: userUUID)").run()
            try await sql.raw("UPDATE im_v2.device_refresh_sessions SET revoked_at = COALESCE(revoked_at, \(bind: occurredAt)) WHERE user_id = \(bind: userUUID)").run()
            try await sql.raw("UPDATE im_v2.device_access_tokens SET revoked_at = COALESCE(revoked_at, \(bind: occurredAt)) WHERE user_id = \(bind: userUUID)").run()
            if let profile = try await sql.raw("""
                WITH candidate AS MATERIALIZED (
                    SELECT user_id, public_handle, display_name, account_kind
                    FROM im_v2.public_user_profiles
                    WHERE user_id = \(bind: userUUID) AND state <> 'deleted'
                      AND state <> 'suspended'
                    FOR UPDATE
                ), updated AS (
                    UPDATE im_v2.public_user_profiles AS profile
                    SET state = 'suspended', avatar_media_id = NULL,
                        revision = profile.revision + 1,
                        visibility_revision = profile.visibility_revision + 1,
                        updated_at = \(bind: occurredAt)
                    FROM candidate
                    WHERE profile.user_id = candidate.user_id
                      AND profile.revision < \(bind: Int64.max)
                      AND profile.visibility_revision < \(bind: Int64.max)
                    RETURNING profile.revision
                )
                SELECT candidate.public_handle, candidate.display_name,
                       candidate.account_kind, updated.revision
                FROM candidate LEFT JOIN updated ON TRUE
                """).first(decoding: DisabledProfileRow.self) {
                // An eligible profile must actually be suspended. A missing
                // revision distinguishes exhausted counters from no profile
                // transition being necessary.
                guard let revision = profile.revision else { throw V2AccountDisableError.unavailable }
                try await sql.raw("""
                    INSERT INTO im_v2.public_profile_update_outbox
                        (source_event_id, source_user_id, public_handle,
                         display_name, account_kind, profile_state, revision,
                         profile_updated_at, created_at)
                    VALUES (\(bind: command.operationID), \(bind: userUUID),
                            \(bind: profile.publicHandle), \(bind: profile.displayName),
                            \(bind: profile.accountKind), 'suspended',
                            \(bind: revision), \(bind: occurredAt), \(bind: occurredAt))
                    """).run()
            }
            // The durable gateway worker consumes this per-device stream on
            // every gateway replica and closes already-authenticated sockets.
            try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) SELECT user_id, device_id, \(bind: occurredAt) FROM im_v2.auth_devices WHERE user_id = \(bind: userUUID) ON CONFLICT (device_id) DO NOTHING").run()
            // Keep native time binds above, while returning exactly the
            // committed receipt time that a later replay will decode.
            return .disabled(disabledAt: persisted.disabledAt)
        }
    }

    private func lockAccountState(_ sql: any SQLDatabase, userID: UUID) async throws {
        let key = "account-state:" + userID.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }

    private func lockOperation(_ sql: any SQLDatabase, operationID: UUID) async throws {
        let key = "account-disable-operation:" + operationID.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }
}

private struct DisableRecord: Decodable {
    let userID: UUID
    let disabledAt: Date
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case disabledAt = "disabled_at" }
}

private struct DisabledProfileRow: Decodable {
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let revision: Int64?
    enum CodingKeys: String, CodingKey {
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case revision
    }
}
