import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2CancellableDeviceRegistration: Sendable {
    public let registration: V2TrustedDeviceRegistration
    public let cancellation: V2DeviceRegistrationCancellation

    public init(registration: V2TrustedDeviceRegistration, cancellation: V2DeviceRegistrationCancellation) throws {
        guard UUID(uuidString: registration.deviceID.rawValue) == UUID(uuidString: cancellation.deviceID.rawValue),
              registration.operationID == cancellation.operationID else { throw V2DeviceSessionServiceError.invalidRequest }
        self.registration = registration; self.cancellation = cancellation
    }
}

public enum V2DeviceRegistrationCancellationOutcome: Equatable, Sendable {
    case applied, idempotent, expired
}

public protocol V2DeviceRegistrationCancelling: Sendable {
    func cancel(_ request: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationOutcome
}

/// The proof lock precedes the existing account lock. A cancellation before
/// issuance leaves a tombstone; a cancellation after issuance revokes the
/// exact bound session. Both transitions commit with their durable marker.
public struct V2PostgresDeviceRegistrationCancellationService: V2DeviceRegistrationCancelling, Sendable {
    private let database: any Database
    private let now: @Sendable () -> Date

    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database; self.now = now
    }

    public func cancel(_ request: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            try await Self.lock(sql, request: request)
            let prior = try await Self.record(sql, request: request)
            if prior?.cancelledAt != nil { return .idempotent }
            if let prior, let userID = prior.userID {
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + userID.uuidString), 0))").run()
                guard try await sql.raw("""
                    SELECT device.device_id FROM im_v2.auth_devices AS device
                    JOIN im_v2.device_registration_cancellations AS binding
                      ON binding.user_id=device.user_id AND binding.device_id=device.device_id
                     AND binding.session_created_at=device.created_at
                     AND binding.session_expires_at=device.session_expires_at
                    WHERE binding.request_digest=\(bind: Self.digest(request))
                      AND device.user_id=\(bind: userID) AND device.device_id=\(bind: Self.device(request))
                    FOR UPDATE OF device
                    """).first() != nil
                else { throw V2DeviceSessionServiceError.malformedPersistence }
                let occurredAt = now()
                guard v2PostgresTimestampCanEncode(occurredAt) else { throw V2DeviceSessionServiceError.unavailable }
                // EXTRACT returns numeric: compare the exact grace period
                // without a Date round trip or overflowing a SQL timestamp.
                guard let deadline = try await sql.raw("SELECT EXTRACT(EPOCH FROM session_expires_at) + 600 > EXTRACT(EPOCH FROM \(bind: occurredAt)::timestamptz) AS is_open FROM im_v2.auth_devices WHERE user_id=\(bind: userID) AND device_id=\(bind: Self.device(request))").first(decoding: Deadline.self) else {
                    throw V2DeviceSessionServiceError.malformedPersistence
                }
                guard deadline.isOpen else { return .expired }
                try await Self.markCancelled(sql, request: request, at: occurredAt)
                try await V2PostgresDeviceSessionService.revokeSession(sql, userID: userID, deviceID: Self.device(request), at: occurredAt)
                return .applied
            }
            let occurredAt = now()
            guard try Self.admitsNewRequest(request, at: occurredAt) else { return .expired }
            try await sql.raw("""
                INSERT INTO im_v2.device_registration_cancellations
                    (request_digest, device_id, operation_id, issue_before, created_at, cancelled_at)
                VALUES (\(bind: Self.digest(request)), \(bind: Self.device(request)), \(bind: request.operationID),
                    \(bind: request.issueBefore), \(bind: occurredAt), \(bind: occurredAt))
                """).run()
            return .applied
        }
    }

    static func lock(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation) async throws {
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "registration-cancellation:" + digest(request)), 0))").run()
    }

    /// Caller holds proof lock then account lock; observe time only afterwards.
    static func permitsIssuance(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation,
                                at now: Date) async throws -> Bool {
        guard try admitsNewRequest(request, at: now) else { return false }
        return try await record(sql, request: request)?.cancelledAt == nil
    }

    static func ownsReplay(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation,
                           userID: UUID) async throws -> Bool {
        try await record(sql, request: request)?.userID == userID
    }

    static func bindIssuedSession(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation,
                                  userID: UUID, at now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now) else { throw V2DeviceSessionServiceError.unavailable }
        // The proof lock excludes cancellation and duplicate binding until the
        // credentials, replay envelope, and this record commit together.
        try await sql.raw("""
            INSERT INTO im_v2.device_registration_cancellations
                (request_digest, device_id, operation_id, issue_before, created_at,
                 user_id, session_created_at, session_expires_at)
            SELECT \(bind: digest(request)), device_id, \(bind: request.operationID), \(bind: request.issueBefore),
                \(bind: now), user_id, created_at, session_expires_at
            FROM im_v2.auth_devices WHERE user_id = \(bind: userID) AND device_id = \(bind: device(request))
            """).run()
    }

    private static func admitsNewRequest(_ request: V2DeviceRegistrationCancellation, at now: Date) throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2DeviceSessionServiceError.unavailable }
        guard v2PostgresTimestampPrecedes(now, request.issueBefore) else { return false }
        // Limits unauthenticated pre-issuance tombstones and clock errors.
        guard request.issueBefore.timeIntervalSince(now) <= 86_400 else { throw V2DeviceSessionServiceError.invalidRequest }
        return true
    }

    private static func markCancelled(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation, at now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now) else { throw V2DeviceSessionServiceError.unavailable }
        try await sql.raw("UPDATE im_v2.device_registration_cancellations SET cancelled_at = \(bind: now) WHERE request_digest = \(bind: digest(request))").run()
    }

    private static func record(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation) async throws -> Record? {
        try await sql.raw("""
            SELECT user_id, cancelled_at
            FROM im_v2.device_registration_cancellations WHERE request_digest = \(bind: digest(request))
            """).first(decoding: Record.self)
    }

    private static func device(_ request: V2DeviceRegistrationCancellation) throws -> UUID {
        guard let value = UUID(uuidString: request.deviceID.rawValue) else { throw V2DeviceSessionServiceError.invalidRequest }
        return value
    }

    private static func digest(_ request: V2DeviceRegistrationCancellation) -> String {
        let context = "imv2-registration-cancellation-v1\0\(request.deviceID.rawValue)\0\(request.operationID.uuidString)\0\(request.issueBeforeMilliseconds)\0\(request.proof.rawValue)"
        return SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Record: Decodable {
        let userID: UUID?
        let cancelledAt: Date?
        enum CodingKeys: String, CodingKey {
            case userID = "user_id", cancelledAt = "cancelled_at"
        }
    }
    private struct Deadline: Decodable {
        let isOpen: Bool
        enum CodingKeys: String, CodingKey { case isOpen = "is_open" }
    }
}
