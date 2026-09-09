import Foundation
import SQLKit

/// Budget persistence only. The caller holds the account-state lock and uses
/// the same transaction as the successful new-device write. This component
/// neither reads nor creates credentials.
struct PostgresV2DeviceRegistrationBudget: Sendable {
    let policy: V2DeviceRegistrationPolicy

    func retryAfter(
        _ sql: any SQLDatabase,
        userID: UUID,
        now: Date
    ) async throws -> Int? {
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: policy.window) else {
            throw V2DeviceCredentialServiceError.unavailable
        }
        guard let row = try await sql.raw("SELECT window_started_at, successful_registrations FROM im_v2.device_registration_rate_limits WHERE user_id = \(bind: userID) AND window_started_at > \(bind: cutoff) FOR UPDATE")
            .first(decoding: DeviceRegistrationRateLimitRow.self)
        else { return nil }
        guard row.successfulRegistrations >= policy.maximumNewDevicesPerWindow
        else { return nil }
        guard let retryAfter = v2RateLimitRetryAfterSeconds(
            windowStartedAt: row.windowStartedAt, now: now, window: policy.window
        ) else { throw V2DeviceCredentialServiceError.unavailable }
        return retryAfter
    }

    func recordSuccess(
        _ sql: any SQLDatabase,
        userID: UUID,
        now: Date
    ) async throws {
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: policy.window) else {
            throw V2DeviceCredentialServiceError.unavailable
        }
        // Use the same complete window as retryAfter. Adding a truncated
        // interval to the stored start both loses fractional seconds and can
        // overflow PostgreSQL's upper timestamp boundary.
        try await sql.raw("""
            INSERT INTO im_v2.device_registration_rate_limits
                (user_id, window_started_at, successful_registrations, updated_at)
            VALUES (\(bind: userID), \(bind: now), 1, \(bind: now))
            ON CONFLICT (user_id) DO UPDATE
            SET window_started_at = CASE
                    WHEN im_v2.device_registration_rate_limits.window_started_at <= \(bind: cutoff)
                    THEN EXCLUDED.window_started_at
                    ELSE im_v2.device_registration_rate_limits.window_started_at
                END,
                successful_registrations = CASE
                    WHEN im_v2.device_registration_rate_limits.window_started_at <= \(bind: cutoff)
                    THEN 1
                    ELSE im_v2.device_registration_rate_limits.successful_registrations + 1
                END,
                updated_at = GREATEST(im_v2.device_registration_rate_limits.updated_at, EXCLUDED.updated_at)
            """).run()
    }
}

private struct DeviceRegistrationRateLimitRow: Decodable {
    let windowStartedAt: V2PostgresTimestamp
    let successfulRegistrations: Int
    enum CodingKeys: String, CodingKey {
        case windowStartedAt = "window_started_at"
        case successfulRegistrations = "successful_registrations"
    }
}
