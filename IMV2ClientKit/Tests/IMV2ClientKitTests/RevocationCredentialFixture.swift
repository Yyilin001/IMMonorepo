import Foundation
import IMV2Core
import IMV2ClientKit

// Explicit synthetic capability for fake credential factories in this test
// target only. Production initializers require a server-issued value.
let fixtureRevocationCredential = try! V2DeviceRevocationCredential(rawValue: "imv2-revoke-v1." + String(repeating: "A", count: 43))
let fixtureRevocationExpiry = Date(timeIntervalSince1970: 4_102_444_800)

extension V2AuthCredentials {
    init(userID: UserID, deviceID: DeviceID, accessToken: String, accessTokenExpiresAt: Date, refreshCredential: String) throws {
        try self.init(userID: userID, deviceID: deviceID, accessToken: accessToken, accessTokenExpiresAt: accessTokenExpiresAt,
            refreshCredential: refreshCredential, revocationCredential: fixtureRevocationCredential,
            revocationCredentialExpiresAt: fixtureRevocationExpiry)
    }
}

extension V2RefreshRequest {
    init(userID: UserID, deviceID: DeviceID, refreshCredential: String, operationID: UUID) {
        self.init(userID: userID, deviceID: deviceID, refreshCredential: refreshCredential,
            revocationCredential: fixtureRevocationCredential, operationID: operationID)
    }
}

// These tests explicitly keep revocation work in memory; production requires
// its independently durable store at the composition boundary.
actor FixtureRevocationScheduler: V2DeviceRevocationScheduling {
    private(set) var intents: [UUID: V2DeviceRevocationIntent] = [:]
    func enqueue(_ intent: V2DeviceRevocationIntent) throws {
        if let prior = intents[intent.operationID], prior != intent { throw V2DeviceRevocationStoreError.conflict }
        intents[intent.operationID] = intent
    }
}

extension V2AuthSession {
    init(credentialStore: any V2CredentialStore, transport: any V2AuthTransport,
         makeUUID: @escaping @Sendable () -> UUID = { UUID() },
         now: @escaping @Sendable () -> Date = Date.init) {
        self.init(credentialStore: credentialStore, transport: transport,
            revocationScheduler: FixtureRevocationScheduler(), makeUUID: makeUUID, now: now)
    }
}

actor FixtureIssuedCredentialRecovery: V2IssuedCredentialRecovering {
    private var receipts: [UUID: V2DeviceRevocationIntent] = [:]
    func receive(_ credentials: V2AuthCredentials, operationID: UUID) -> V2DeviceRevocationIntent {
        let receipt = V2DeviceRevocationIntent(credentials: credentials, operationID: operationID)
        receipts[operationID] = receipt
        return receipt
    }
    func adopt(_ receipt: V2DeviceRevocationIntent) { receipts[receipt.operationID] = nil }
    func abandon(_ receipt: V2DeviceRevocationIntent) { receipts[receipt.operationID] = nil }
}

extension V2HTTPAccountAssertionDeviceCredentialProvider {
    init(issueEndpoint: URL, assertionProvider: any V2DeviceBoundAccountAssertionProvider,
         deviceIdentityProvider: any V2DeviceIdentityProvider,
         operationStore: any V2DeviceCredentialRegistrationOperationStore,
         registrationMetadata: V2ClientDeviceRegistrationMetadata = .unknown,
         transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport(),
         makeUUID: @escaping @Sendable () -> UUID = { UUID() }, now: @escaping @Sendable () -> Date = Date.init) throws {
        try self.init(issueEndpoint: issueEndpoint, assertionProvider: assertionProvider,
            deviceIdentityProvider: deviceIdentityProvider, operationStore: operationStore,
            recovery: FixtureIssuedCredentialRecovery(), registrationMetadata: registrationMetadata,
            transport: transport, makeUUID: makeUUID, now: now)
    }
}
