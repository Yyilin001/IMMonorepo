@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("PostgreSQL timestamp bounds")
struct V2PersistenceTimestampBoundsTests {
    @Test("Raw PostgreSQL timestamp offsets retain exact one-microsecond boundaries")
    func exactMicrosecondBounds() {
        for value: Int64 in [0, -211_813_488_000_000_000, 9_223_371_331_199_999_999] {
            #expect(v2PostgresTimestampMicrosecondsCanEncode(value))
        }
        for value: Int64 in [.min, .max, -211_813_488_000_000_001, 9_223_371_331_200_000_000] {
            #expect(!v2PostgresTimestampMicrosecondsCanEncode(value))
        }
    }

    @Test("Absolute grant deadlines remain ordered in database microseconds")
    func absoluteTimestampBounds() {
        let now = Date(timeIntervalSince1970: 946_684_800.00000025)
        let sameMicrosecond = Date(timeIntervalSince1970: 946_684_800.00000075)
        #expect(now < sameMicrosecond)
        #expect(!v2PostgresTimestampPrecedes(now, sameMicrosecond))
        #expect(!v2PostgresTimestampPrecedes(now, now))
        #expect(!v2PostgresTimestampPrecedes(now, now.addingTimeInterval(-1)))
        #expect(v2PostgresTimestampPrecedes(now, now.addingTimeInterval(1)))
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
            let invalid = Date(timeIntervalSince1970: seconds)
            #expect(!v2PostgresTimestampPrecedes(now, invalid))
            #expect(!v2PostgresTimestampPrecedes(invalid, now))
        }
    }

    @Test("Retention cutoff validates the lower database bound and preserves a positive age")
    func pastTimestampBounds() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        for interval in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0, -1, .leastNonzeroMagnitude] {
            #expect(v2PostgresPastTimestamp(now: now, interval: interval) == nil)
        }
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
            #expect(v2PostgresPastTimestamp(now: .init(timeIntervalSince1970: seconds), interval: 60) == nil)
        }
        let lower = Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000 + 30)
        #expect(v2PostgresTimestampCanEncode(lower))
        #expect(v2PostgresPastTimestamp(now: lower, interval: 60) == nil)
        for date in [now, Date(timeIntervalSince1970: -100_000_000_000)] {
            #expect(v2PostgresPastTimestamp(now: date, interval: 60) == date.addingTimeInterval(-60))
        }
    }

    @Test("Expiry validates the actual database range and survives timestamp precision loss")
    func futureTimestampBounds() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        for interval in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0, -1, .leastNonzeroMagnitude, 0.0000001] {
            #expect(v2PostgresFutureTimestamp(now: now, interval: interval) == nil)
        }
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
            #expect(v2PostgresFutureTimestamp(now: .init(timeIntervalSince1970: seconds), interval: 60) == nil)
        }
        let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 30)
        #expect(v2PostgresTimestampCanEncode(upper))
        #expect(v2PostgresFutureTimestamp(now: upper, interval: 60) == nil)
        for date in [now, Date(timeIntervalSince1970: -100_000_000_000), Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000)] {
            #expect(v2PostgresFutureTimestamp(now: date, interval: 60) == date.addingTimeInterval(60))
        }
    }
}
