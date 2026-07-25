import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 account assertions")
struct V2AccountAssertionTests {
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
