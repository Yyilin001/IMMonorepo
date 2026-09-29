import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ServerHTTP

// Fake issuer responses only. PostgreSQL tests use each real registration's
// independent capability, never this synthetic value.
let fixtureRevocationCredential = try! V2DeviceRevocationCredential(rawValue: "imv2-revoke-v1." + String(repeating: "A", count: 43))
let fixtureRevocationExpiry = Date(timeIntervalSince1970: 4_102_444_800)

extension V2IssuedDeviceCredentials {
    init(userID: UserID, deviceID: DeviceID, accessToken: String, accessTokenExpiresAt: Date, refreshCredential: String) throws {
        try self.init(userID: userID, deviceID: deviceID, accessToken: accessToken, accessTokenExpiresAt: accessTokenExpiresAt,
            refreshCredential: refreshCredential, revocationCredential: fixtureRevocationCredential,
            revocationCredentialExpiresAt: fixtureRevocationExpiry)
    }
}

extension V2DeviceCredentialRefreshHTTPRequest {
    init(userID: String, deviceID: String, refreshCredential: String, operationID: UUID) {
        self.init(userID: userID, deviceID: deviceID, refreshCredential: refreshCredential,
            revocationCredential: fixtureRevocationCredential, operationID: operationID)
    }
}
