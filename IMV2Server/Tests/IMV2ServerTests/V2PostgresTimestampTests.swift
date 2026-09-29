@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import NIOCore
import PostgresNIO
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

struct V2PersistenceTimestampTests {
    @Test("Persisted timestamp bytes survive epochs and database endpoints without a Date round trip",
          arguments: [Int64(-211_813_488_000_000_000), -211_813_487_999_999_999,
              -1, 0, 1, 9_223_371_331_199_999_998, 9_223_371_331_199_999_999])
    func preservesDatabaseBytes(microseconds: Int64) throws {
        var input = ByteBuffer()
        input.writeInteger(microseconds)
        let timestamp = try V2PersistenceTimestamp(from: &input, type: .timestamptz, format: .binary, context: .default)
        var output = ByteBuffer()
        timestamp.encode(into: &output, context: .default)
        #expect(output.readInteger(as: Int64.self) == microseconds)
        #expect(input.readableBytes == 0 && output.readableBytes == 0)
    }

    @Test("Persisted timestamp decoding rejects infinity and out-of-range database offsets",
          arguments: [Int64.min, .max, -211_813_488_000_000_001, 9_223_371_331_200_000_000])
    func rejectsUnsupportedDatabaseValues(microseconds: Int64) {
        var input = ByteBuffer()
        input.writeInteger(microseconds)
        #expect(throws: (any Error).self) {
            try V2PersistenceTimestamp(from: &input, type: .timestamptz, format: .binary, context: .default)
        }
    }

    @Test("Fresh timestamps retain the driver's truncation and reject unusable clocks")
    func encodesFreshDate() throws {
        for (seconds, microseconds): (Double, Int64) in [(946_684_800, 0), (946_684_800.00000125, 1), (946_684_799.99999875, -1)] {
            #expect(try V2PersistenceTimestamp(date: .init(timeIntervalSince1970: seconds)).microseconds == microseconds)
        }
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1e14, 1e14] {
            #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try V2PersistenceTimestamp(date: .init(timeIntervalSince1970: seconds))
            }
        }
    }
}
