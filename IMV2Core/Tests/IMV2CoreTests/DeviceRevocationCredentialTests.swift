import Foundation
@testable import IMV2Core
import Testing

@Suite("Device revocation credential")
struct DeviceRevocationCredentialTests {
    @Test("Canonical 256-bit credentials round trip without diagnostic disclosure")
    func roundTrip() throws {
        let credential = V2DeviceRevocationCredential.generate()
        let encoded = try JSONEncoder().encode(credential)
        let decoded = try JSONDecoder().decode(V2DeviceRevocationCredential.self, from: encoded)
        #expect(decoded == credential)
        #expect(credential.rawValue.utf8.count == 58)
        #expect(String(describing: credential) == "V2DeviceRevocationCredential(<redacted>)")
        #expect(String(reflecting: credential) == credential.description)
        #expect(Mirror(reflecting: credential).children.isEmpty)
        var diagnostic = ""
        dump(credential, to: &diagnostic)
        #expect(!diagnostic.contains(credential.rawValue))
    }

    @Test("Reject access-like, padded, noncanonical and oversized wire values")
    func invalidValues() throws {
        let canonical = "imv2-revoke-v1." + String(repeating: "A", count: 43)
        _ = try V2DeviceRevocationCredential(rawValue: canonical)
        let invalid = ["", String(repeating: "A", count: 43), canonical + "=", canonical + "\n",
            "imv2-revoke-v2." + String(repeating: "A", count: 43),
            String(canonical.dropLast()) + "B", String(canonical.dropLast()) + "+",
            String(canonical.dropLast()) + "é", String(repeating: "A", count: 100_000)]
        for value in invalid {
            #expect(throws: V2DeviceRevocationCredential.ValidationError.invalidCredential) {
                try V2DeviceRevocationCredential(rawValue: value)
            }
            let encoded = try JSONEncoder().encode(value)
            #expect(throws: V2DeviceRevocationCredential.ValidationError.invalidCredential) {
                try JSONDecoder().decode(V2DeviceRevocationCredential.self, from: encoded)
            }
        }
    }
}
