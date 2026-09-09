import Foundation
@testable import IMV2Server
import Testing

struct V2AccountRateLimitBoundsTests {
    @Test("actual PostgreSQL date offsets are checked after date addition")
    func checksTimestampAfterAddingDuration() {
        let epoch = Date(timeIntervalSince1970: 946_684_800)
        #expect(v2PostgresTimestampCanEncode(epoch))
        #expect(v2PostgresTimestampCanEncode(epoch.addingTimeInterval(9_000_000_000_000)))
        #expect(!v2PostgresTimestampCanEncode(epoch.addingTimeInterval(-9_000_000_000_000)))
        #expect(!v2PostgresTimestampCanEncode(epoch.addingTimeInterval(Double(Int64.max) / 1_000_000)))
        #expect(!v2PostgresTimestampCanEncode(epoch.addingTimeInterval(Double(Int64.min) / 1_000_000)))
        #expect(!v2PostgresTimestampCanEncode(epoch.addingTimeInterval(Double(Int64.min).nextDown / 1_000_000)))
        #expect(v2PostgresTimestampCanEncode(epoch.addingTimeInterval(-211_813_488_000)))
        #expect(!v2PostgresTimestampCanEncode(epoch.addingTimeInterval(-211_813_488_001)))
        #expect(v2PostgresTimestampCanEncode(epoch.addingTimeInterval(9_223_371_331_200 - 86_400)))
        #expect(!v2PostgresTimestampCanEncode(epoch.addingTimeInterval(9_223_371_331_200)))
        let duration = 1_000_000_000_000.0
        let now = epoch.addingTimeInterval(-211_813_487_999)
        #expect(v2RateLimitDurationIsRepresentable(duration))
        #expect(v2PostgresTimestampCanEncode(now))
        #expect(!v2PostgresTimestampCanEncode(now.addingTimeInterval(-duration)))
    }

    @Test("account limit windows must fit the PostgreSQL timestamp duration", arguments: [
        Double.nan, Double.infinity, -Double.infinity, Double(Int64.max) / 1_000_000,
        Double.greatestFiniteMagnitude, 0, -1
    ])
    func rejectsUnencodableDuration(duration: Double) {
        #expect(throws: V2AccountEdgeClientRateLimitError.invalidPolicy) {
            try V2AccountEdgeClientRateLimitPolicy(maximumRequests: 1, window: duration)
        }
        #expect(throws: V2PublicIdentityLookupRateLimitError.invalidPolicy) {
            try V2PublicIdentityLookupRateLimitPolicy(maximumQueries: 1, window: duration)
        }
        #expect(throws: V2PasswordLoginRateLimitError.invalidPolicy) {
            try V2PasswordLoginRateLimitPolicy(maximumFailures: 1, window: duration, lockout: 60)
        }
        #expect(throws: V2PasswordLoginRateLimitError.invalidPolicy) {
            try V2PasswordLoginRateLimitPolicy(maximumFailures: 1, window: 60, lockout: duration)
        }
    }

    @Test("password failure threshold must fit PostgreSQL integer", arguments: [Int(Int32.max) + 1, Int.max])
    func rejectsUnrepresentableFailureThreshold(maximum: Int) {
        #expect(throws: V2PasswordLoginRateLimitError.invalidPolicy) {
            try V2PasswordLoginRateLimitPolicy(maximumFailures: maximum, window: 60, lockout: 60)
        }
    }

    @Test("valid fractional durations and largest failure threshold remain supported", arguments: [0.5, 60, 9_000_000_000_000.0])
    func preservesRepresentablePolicy(duration: Double) throws {
        #expect(try V2AccountEdgeClientRateLimitPolicy(maximumRequests: 1, window: duration).window == duration)
        #expect(try V2PublicIdentityLookupRateLimitPolicy(maximumQueries: 1, window: duration).window == duration)
        let password = try V2PasswordLoginRateLimitPolicy(maximumFailures: Int(Int32.max), window: duration, lockout: duration)
        #expect(password.maximumFailures == Int(Int32.max))
        #expect(password.window == duration)
        #expect(password.lockout == duration)
    }
}
