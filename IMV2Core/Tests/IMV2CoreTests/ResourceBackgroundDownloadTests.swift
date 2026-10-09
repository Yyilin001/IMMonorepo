import Foundation
import IMV2Core
import Testing

@Suite("Background download delegation boundary")
struct ResourceBackgroundDownloadTests {
    private let issued = Date(timeIntervalSince1970: 1_750_000_000)
    private var expiry: Date { issued.addingTimeInterval(120) }
    private var digest: V2ResourceChecksum { get throws { try .init(value: String(repeating: "a", count: 64)) } }
    private func plan() throws -> V2ResourceTransferPlan {
        try .init(mode: .httpGet, url: URL(string: "https://objects.invalid/download?cap=opaque")!,
            expiresAt: expiry, expectedByteCount: 3, checksum: digest,
            backgroundDownloadAuthorization: .init(id: UUID(), expectedByteCount: 3, checksum: digest,
                issuedAt: issued, expiresAt: expiry))
    }

    @Test func exactGetPlanRoundTripsWithoutChangingItsDelegation() throws {
        let original = try plan()
        let decoded = try JSONDecoder().decode(V2ResourceTransferPlan.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let grant = try #require(decoded.backgroundDownloadAuthorization)
        let bytes = try JSONEncoder().encode(grant)
        let encoded = String(decoding: bytes, as: UTF8.self)
        #expect(!encoded.contains("https") && !encoded.contains("cap=opaque"))
        #expect(grant.expectedByteCount == decoded.expectedByteCount && grant.checksum == decoded.checksum)
    }

    @Test(arguments: ["method", "length", "digest", "expiry", "credential", "range"])
    func decodedPlanCannotWidenDelegation(change: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan())) as? [String: Any])
        switch change {
        case "method": object["mode"] = "http_put"
        case "length": object["expectedByteCount"] = 4
        case "digest": object["checksum"] = ["algorithm": "sha256", "value": String(repeating: "b", count: 64)]
        case "expiry": object["expiresAtUnixMilliseconds"] = Int64(expiry.timeIntervalSince1970 * 1000) + 1
        case "credential": object["headers"] = [["name": "Authorization", "value": "Bearer object", "kind": "object_capability"]]
        default: object["byteRange"] = ["start": 0, "endInclusive": 2]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ResourceTransferPlan.self, from: data) }
    }

    @Test(arguments: ["empty", "oversized", "zero-time", "expired", "long-lived"])
    func decodedGrantCannotBypassBounds(change: String) throws {
        let grant = try #require(plan().backgroundDownloadAuthorization)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
        switch change {
        case "empty": object["expectedByteCount"] = 0
        case "oversized": object["expectedByteCount"] = 512 * 1024 * 1024 + 1
        case "zero-time": object["issuedAtMilliseconds"] = 0
        case "expired": object["expiresAtMilliseconds"] = grant.issuedAtMilliseconds
        default: object["expiresAtMilliseconds"] = grant.issuedAtMilliseconds + 900_001
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ResourceBackgroundDownloadAuthorization.self, from: data) }
    }
}
