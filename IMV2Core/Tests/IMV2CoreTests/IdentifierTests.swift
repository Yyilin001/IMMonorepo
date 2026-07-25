import Testing
@testable import IMV2Core

struct IdentifierTests {
    @Test("entity identifiers use bounded RFC 3986 unreserved encoding")
    func acceptsURLSafeOpaqueIdentifier() throws {
        let identifier = try MediaID("device_01-asset.~v2")

        #expect(identifier.rawValue == "device_01-asset.~v2")
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
