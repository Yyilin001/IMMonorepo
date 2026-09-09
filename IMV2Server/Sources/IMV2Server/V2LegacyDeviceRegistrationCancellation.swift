import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Construct only after verifying a fresh account factor for assertionDeviceID.
/// The target's old IDs identify work; account verification supplies authority.
public struct V2TrustedLegacyDeviceRegistrationCancellation: Sendable {
    public let userID: UserID
    public let assertionDeviceID: DeviceID
    public let targetDeviceID: DeviceID
    public let operationID: UUID

    public init(userID: UserID, assertionDeviceID: DeviceID, targetDeviceID: DeviceID, operationID: UUID) throws {
        guard userID.uuidValue != nil, assertionDeviceID.uuidValue != nil, targetDeviceID.uuidValue != nil,
              assertionDeviceID != targetDeviceID else { throw V2DeviceSessionServiceError.invalidRequest }
        self.userID = userID; self.assertionDeviceID = assertionDeviceID
        self.targetDeviceID = targetDeviceID; self.operationID = operationID
    }
}

public enum V2LegacyDeviceRegistrationCancellationOutcome: Equatable, Sendable {
    case applied, idempotent, targetUnavailable, accountUnavailable, conflict, capacityExceeded
}

public protocol V2LegacyDeviceRegistrationCancelling: Sendable {
    func cancel(_ request: V2TrustedLegacyDeviceRegistrationCancellation) async throws -> V2LegacyDeviceRegistrationCancellationOutcome
}

/// Shares account -> registration -> device lock ordering with issuance.
/// Account-scoped tombstones also reject an operation that never issued.
public struct V2PostgresLegacyDeviceRegistrationCancellationService: V2LegacyDeviceRegistrationCancelling {
    private let database: any Database
    private let now: @Sendable () -> Date
    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database; self.now = now
    }

    public func cancel(_ request: V2TrustedLegacyDeviceRegistrationCancellation) async throws -> V2LegacyDeviceRegistrationCancellationOutcome {
        guard let user = request.userID.uuidValue, let device = request.targetDeviceID.uuidValue else { throw V2DeviceSessionServiceError.invalidRequest }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + user.uuidString), 0))").run()
            guard try await sql.raw("SELECT 1 FROM im_v2.account_disables WHERE user_id = \(bind: user)").first() == nil,
                  try await sql.raw("SELECT 1 FROM im_v2.special_accounts WHERE account_user_id = \(bind: user) AND status = 'active'").first() == nil
            else { return .accountUnavailable }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "register:" + device.uuidString), 0))").run()
            let target = try await sql.raw("SELECT user_id FROM im_v2.auth_devices WHERE device_id = \(bind: device) FOR UPDATE").first(decoding: Target.self)
            guard target == nil || target?.userID == user else { return .targetUnavailable }
            if let previous = try await sql.raw("SELECT device_id, operation_id FROM im_v2.legacy_device_registration_cancellations WHERE user_id = \(bind: user) AND (device_id = \(bind: device) OR operation_id = \(bind: request.operationID))").first(decoding: Previous.self) {
                return previous.deviceID == device && previous.operationID == request.operationID ? .idempotent : .conflict
            }
            let count = try await sql.raw("SELECT count(*)::integer AS count FROM im_v2.legacy_device_registration_cancellations WHERE user_id = \(bind: user)").first(decoding: Count.self)?.count ?? 0
            guard count < 256 else { return .capacityExceeded }
            let at = now()
            guard v2PostgresTimestampCanEncode(at) else { throw V2DeviceSessionServiceError.unavailable }
            try await sql.raw("INSERT INTO im_v2.legacy_device_registration_cancellations (user_id, device_id, operation_id, cancelled_at) VALUES (\(bind: user), \(bind: device), \(bind: request.operationID), \(bind: at))").run()
            if target != nil { try await V2PostgresDeviceSessionService.revokeSession(sql, userID: user, deviceID: device, at: at) }
            return .applied
        }
    }

    static func permitsIssuance(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID) async throws -> Bool {
        try await sql.raw("SELECT 1 FROM im_v2.legacy_device_registration_cancellations WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)").first() == nil
    }

    private struct Target: Decodable {
        let userID: UUID
        enum CodingKeys: String, CodingKey { case userID = "user_id" }
    }
    private struct Previous: Decodable {
        let deviceID: UUID
        let operationID: UUID
        enum CodingKeys: String, CodingKey { case deviceID = "device_id", operationID = "operation_id" }
    }
    private struct Count: Decodable { let count: Int }
}
