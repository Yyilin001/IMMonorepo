import Foundation
import Testing
@testable import IMV2Core

struct IdentifierTests {
    @Test("entity identifiers use bounded RFC 3986 unreserved encoding")
    func acceptsURLSafeOpaqueIdentifier() throws {
        let identifier = try MediaID("device_01-asset.~v2")

        #expect(identifier.rawValue == "device_01-asset.~v2")
    }

    @Test("UUID-backed opaque identifiers use one case-insensitive storage spelling")
    func canonicalizesUUIDSpelling() throws {
        let upper = try RoomID("F90A83A4-DEC2-4BF5-80AA-4068A71AFC9F")
        let lower = try RoomID("f90a83a4-dec2-4bf5-80aa-4068a71afc9f")

        #expect(upper == lower)
        #expect(upper.rawValue == "F90A83A4-DEC2-4BF5-80AA-4068A71AFC9F")
    }

    @Test("Codable identifier input shares the construction validation and UUID canonicalization boundary")
    func decodesThroughIdentifierBoundary() throws {
        let payload = Data(#"{"rawValue":"F90A83A4-DEC2-4BF5-80AA-4068A71AFC9F"}"#.utf8)
        let decoded = try JSONDecoder().decode(RoomID.self, from: payload)

        #expect(decoded.rawValue == "F90A83A4-DEC2-4BF5-80AA-4068A71AFC9F")
        #expect(try JSONEncoder().encode(decoded) == Data(#"{"rawValue":"F90A83A4-DEC2-4BF5-80AA-4068A71AFC9F"}"#.utf8))
        #expect(throws: V2CoreError.invalidIdentifier) {
            try JSONDecoder().decode(RoomID.self, from: Data(#"{"rawValue":"room/other"}"#.utf8))
        }
    }

    @Test("entity identifiers reject path, control, Unicode, and oversized values")
    func rejectsUnsafeOpaqueIdentifierValues() {
        for value in [
            "",
            "media/other",
            "media\\other",
            "media?query",
            "media#fragment",
            "media%2Fother",
            "media\nother",
            "媒体",
            String(repeating: "a", count: V2Identifier<MediaIDTag>.maximumUTF8Bytes + 1)
        ] {
            #expect(throws: V2CoreError.invalidIdentifier) {
                _ = try MediaID(value)
            }
        }
    }
}
