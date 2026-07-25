import IMV2Core

/// Deployed account-factor adapters validate their opaque assertion here. The
/// V2 device issuer never accepts a user ID supplied by a mobile client.
public protocol V2AccountAssertionVerifier: Sendable {
    func verifiedUserID(for accountAssertion: String) async throws -> UserID
}

/// Built-in account factors bind their result to the exact installation that
/// will receive credentials, preventing a stolen short-lived assertion from
/// being replayed to enrol a second device.
public protocol V2DeviceBoundAccountAssertionVerifier: V2AccountAssertionVerifier {
    func verifiedUserID(for accountAssertion: String, deviceID: DeviceID) async throws -> UserID
}
