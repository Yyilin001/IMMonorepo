import Foundation
@testable import IMV2Server
import Testing

struct V2PostgresGatewayAuthenticatorTests {
    @Test("HMAC token digest is deterministic, keyed, and rejects short secrets")
    func tokenDigest() throws {
        let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 7, count: 32))
        #expect(key.digest("access-token") == key.digest("access-token"))
        #expect(key.digest("access-token") != key.digest("different-token"))
        #expect(key.digest("access-token").count == 64)
        #expect(throws: V2GatewayAuthenticationError.invalidKeyMaterial) {
            _ = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 1, count: 31))
        }
    }
}
