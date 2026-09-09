import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 account assertions")
struct V2AccountAssertionTests {
    @Test("Assertion lifetimes cannot gain time through negative timestamp rounding",
          arguments: [Double(-1.0005), -1_000_000_000.1255, 1_750_000_000.1255])
    func deadlineRounding(seconds: Double) throws {
        let issuedAt = Date(timeIntervalSince1970: seconds)
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let key = Data(repeating: 8, count: 32)
        for lifetime in [1e-12, 0.0001] {
            let issuer = try V2HMACAccountAssertionIssuer(rawKey: key, lifetime: lifetime, now: { issuedAt })
            #expect(throws: V2AccountAssertionError.invalidClock) {
                _ = try issuer.issue(userID: user, deviceID: device)
            }
        }

        // A usable lifetime still works normally, and has ended by the
        // requested deadline. All data and key material belong to this test.
        let lifetime = 0.5
        let issuer = try V2HMACAccountAssertionIssuer(rawKey: key, lifetime: lifetime, now: { issuedAt })
        let assertion = try issuer.issue(userID: user, deviceID: device)
        let before = try V2HMACAccountAssertionIssuer(rawKey: key, now: { issuedAt.addingTimeInterval(lifetime - 0.002) })
        #expect(try before.verifiedUserID(for: assertion, deviceID: device) == user)
        let ended = try V2HMACAccountAssertionIssuer(rawKey: key, now: { issuedAt.addingTimeInterval(lifetime) })
        #expect(throws: V2AccountAssertionError.invalidAssertion) {
            _ = try ended.verifiedUserID(for: assertion, deviceID: device)
        }
    }

    @Test("signed assertion is short-lived and bound to one device")
    func verifiesOnlyForBoundDeviceBeforeExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let userID = try UserID("00000000-0000-0000-0000-000000000801")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000802")
        let otherDeviceID = try DeviceID("00000000-0000-0000-0000-000000000803")
        let issuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 8, count: 32), lifetime: 90, now: { now })

        let assertion = try issuer.issue(userID: userID, deviceID: deviceID)

        #expect(try issuer.verifiedUserID(for: assertion, deviceID: deviceID) == userID)
        #expect(throws: V2AccountAssertionError.invalidAssertion) {
            _ = try issuer.verifiedUserID(for: assertion, deviceID: otherDeviceID)
        }
    }

    @Test("tampering and expiry are rejected")
    func rejectsTamperingAndExpiry() throws {
        let userID = try UserID("00000000-0000-0000-0000-000000000811")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000812")
        let issueTime = Date(timeIntervalSince1970: 1_750_000_000)
        let issuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 9, count: 32), lifetime: 30, now: { issueTime })
        let assertion = try issuer.issue(userID: userID, deviceID: deviceID)
        let tampered = assertion + "x"
        #expect(throws: V2AccountAssertionError.invalidAssertion) {
            _ = try issuer.verifiedUserID(for: tampered, deviceID: deviceID)
        }

        let expired = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 9, count: 32), lifetime: 30, now: { issueTime.addingTimeInterval(31) })
        #expect(throws: V2AccountAssertionError.invalidAssertion) {
            _ = try expired.verifiedUserID(for: assertion, deviceID: deviceID)
        }
    }
}
