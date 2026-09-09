import Foundation
import Testing
@testable import IMV2Server

@Suite("Device service effective deadlines")
struct V2DeviceCredentialDeadlinesTests {
    @Test("Response and persistence deadlines retain fractional lifetimes and session caps",
          arguments: [1_750_000_000.125, 946_684_800.25, -210_866_802_200, 9_224_318_015_000])
    func effectiveDeadlines(seconds: Double) throws {
        let now = Date(timeIntervalSince1970: seconds)
        let session = now.addingTimeInterval(60.5)
        let deadlines = try V2DeviceCredentialDeadlines(issuedAt: now, sessionExpiresAt: session,
            accessLifetime: 5.25, refreshLifetime: 120, replayWindow: 10.75)
        #expect(deadlines.accessExpiresAt == now.addingTimeInterval(5.25))
        #expect(deadlines.refreshExpiresAt == session)
        #expect(deadlines.replayExpiresAt == now.addingTimeInterval(10.75))
        let encodedNow = try V2PostgresTimestamp(date: now)
        for date in [deadlines.accessExpiresAt, deadlines.refreshExpiresAt, deadlines.replayExpiresAt] {
            let encoded = try V2PostgresTimestamp(date: date)
            #expect(encoded.microseconds > encodedNow.microseconds)
        }
    }

    @Test("Large access and refresh durations remain valid when their effective session cap fits")
    func cappedLargeDurations() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let session = now.addingTimeInterval(60)
        let deadlines = try V2DeviceCredentialDeadlines(issuedAt: now, sessionExpiresAt: session,
            accessLifetime: .greatestFiniteMagnitude, refreshLifetime: .greatestFiniteMagnitude, replayWindow: 30)
        #expect(deadlines.accessExpiresAt == session)
        #expect(deadlines.refreshExpiresAt == session)
        #expect(deadlines.replayExpiresAt == now.addingTimeInterval(30))
    }

    @Test("Expired, nonfinite and out-of-range session limits cannot produce new deadlines",
          arguments: [Double.nan, .infinity, -.infinity, 1e14, 1_750_000_000, 1_749_999_999])
    func invalidSessionLimit(seconds: Double) {
        #expect(throws: V2DeviceCredentialServiceError.unavailable) {
            try V2DeviceCredentialDeadlines(issuedAt: Date(timeIntervalSince1970: 1_750_000_000),
                sessionExpiresAt: Date(timeIntervalSince1970: seconds),
                accessLifetime: 30, refreshLifetime: 30, replayWindow: 30)
        }
    }
}
