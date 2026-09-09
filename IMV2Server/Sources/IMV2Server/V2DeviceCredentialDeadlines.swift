import Foundation

/// One checked set of effective deadlines shared by response construction
/// and persistence. Access and refresh lifetimes are capped by the session;
/// validate that effective value rather than an unused uncapped sum.
struct V2DeviceCredentialDeadlines: Sendable {
    let accessExpiresAt: Date
    let refreshExpiresAt: Date
    let replayExpiresAt: Date

    init(issuedAt: Date, sessionExpiresAt: Date, accessLifetime: TimeInterval,
         refreshLifetime: TimeInterval, replayWindow: TimeInterval) throws {
        guard accessLifetime.isFinite, accessLifetime > 0,
              refreshLifetime.isFinite, refreshLifetime > 0,
              v2PostgresTimestampPrecedes(issuedAt, sessionExpiresAt),
              let replayExpiry = v2PostgresFutureTimestamp(now: issuedAt, interval: replayWindow)
        else { throw V2DeviceCredentialServiceError.unavailable }
        let accessExpiry = min(issuedAt.addingTimeInterval(accessLifetime), sessionExpiresAt)
        let refreshExpiry = min(issuedAt.addingTimeInterval(refreshLifetime), sessionExpiresAt)
        guard v2PostgresTimestampPrecedes(issuedAt, accessExpiry),
              v2PostgresTimestampPrecedes(issuedAt, refreshExpiry)
        else { throw V2DeviceCredentialServiceError.unavailable }
        accessExpiresAt = accessExpiry
        refreshExpiresAt = refreshExpiry
        replayExpiresAt = replayExpiry
    }
}
