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

            try await sql.raw("INSERT INTO im_v2.account_disables (user_id, operation_id, reason, operator_principal, disabled_at) VALUES (\(bind: userUUID), \(bind: command.operationID), \(bind: command.reason.rawValue), \(bind: operatorPrincipal), \(bind: occurredAt))").run()
            try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at = COALESCE(revoked_at, \(bind: occurredAt)) WHERE user_id = \(bind: userUUID)").run()
            try await sql.raw("UPDATE im_v2.device_refresh_sessions SET revoked_at = COALESCE(revoked_at, \(bind: occurredAt)) WHERE user_id = \(bind: userUUID)").run()
            try await sql.raw("UPDATE im_v2.device_access_tokens SET revoked_at = COALESCE(revoked_at, \(bind: occurredAt)) WHERE user_id = \(bind: userUUID)").run()
            // The durable gateway worker consumes this per-device stream on
            // every gateway replica and closes already-authenticated sockets.
            try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) SELECT user_id, device_id, \(bind: occurredAt) FROM im_v2.auth_devices WHERE user_id = \(bind: userUUID) ON CONFLICT (device_id) DO NOTHING").run()
            return .disabled(disabledAt: occurredAt)
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
