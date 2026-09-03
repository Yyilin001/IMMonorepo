import Foundation
import IMV2Core
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

    @Test("device activity writes are coalesced without changing authentication")
    func activityWriteGate() async throws {
        let gate = V2DeviceActivityWriteGate(interval: 60)
        let device = try DeviceID("00000000-0000-0000-0000-000000000901")
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(await gate.shouldWrite(deviceID: device, at: now))
        #expect(await !gate.shouldWrite(deviceID: device, at: now.addingTimeInterval(59)))
        #expect(await gate.shouldWrite(deviceID: device, at: now.addingTimeInterval(60)))
    }
}
