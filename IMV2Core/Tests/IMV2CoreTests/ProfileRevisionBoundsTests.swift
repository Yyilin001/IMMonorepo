import Foundation
import IMV2Core
import Testing

@Suite("Profile revision persistence bounds")
struct ProfileRevisionBoundsTests {
    @Test(arguments: [UInt64(0), UInt64(Int64.max) + 1, UInt64.max])
    func constructionRejectsOutOfRange(_ value: UInt64) {
        #expect(V2ProfileRevision(rawValue: value) == nil)
    }

    @Test(arguments: ["0", "9223372036854775808", "18446744073709551615", "-1", "1.5"])
    func decodingCannotBypassValidation(_ json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(V2ProfileRevision.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [UInt64(1), UInt64(Int64.max)])
    func exactMaximumRoundTrip(_ value: UInt64) throws {
        let revision = try #require(V2ProfileRevision(rawValue: value))
        let encoded = try JSONEncoder().encode(revision)
        #expect(encoded == Data(String(value).utf8))
        #expect(try JSONDecoder().decode(V2ProfileRevision.self, from: encoded) == revision)
    }
}
