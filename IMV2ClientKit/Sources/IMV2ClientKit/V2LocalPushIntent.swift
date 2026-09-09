import Foundation
import IMV2Core

public enum V2LocalPushIntentError: Error, Equatable, Sendable {
    case invalidScope, scopeMismatch, staleOwner, invalidState, versionExhausted
}

public struct V2PushIntentScope: Equatable, Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let installation: V2LocalInstallationBinding
    public init(userID: UserID, deviceID: DeviceID, installation: V2LocalInstallationBinding) throws {
        guard userID.uuidValue != nil, deviceID.uuidValue != nil else { throw V2LocalPushIntentError.invalidScope }
        self.userID = userID; self.deviceID = deviceID; self.installation = installation
    }
}

public enum V2PushIntentPauseReason: String, Sendable {
    case staleSession, conflictingIntent, authorization
}

/// Token-free state. tokenReference correlates only with an in-memory OS token;
/// activating a new owner clears it and reserves a newer revision.
public struct V2LocalPushIntent: Equatable, Sendable {
    public let scope: V2PushIntentScope
    public internal(set) var ownerID: UUID
    public internal(set) var preferenceEnabled: Bool
    public internal(set) var desiredEnabled: Bool
    public internal(set) var revision: UInt64
    public internal(set) var acknowledgedRevision: UInt64
    public internal(set) var tokenReference: UUID?
    public internal(set) var claim: V2PushIntentSessionClaim?
    public internal(set) var epoch: UInt64?
    public internal(set) var attemptCount: Int
    public internal(set) var nextAttemptAt: Date
    public internal(set) var pauseReason: V2PushIntentPauseReason?

    public var pending: Bool { acknowledgedRevision < revision }
    public var waitingForToken: Bool { desiredEnabled && tokenReference == nil }
    public var version: V2PushIntentVersion? {
        guard let epoch else { return nil }
        return try? .init(epoch: epoch, revision: revision)
    }
}

public protocol V2LocalPushIntentStoring: Sendable {
    func inspectPushIntent(scope: V2PushIntentScope) async throws -> V2LocalPushIntent?
    func activatePushIntent(scope: V2PushIntentScope, ownerID: UUID, initialPreference: Bool, replacing: V2LocalPushIntent?) async throws -> V2LocalPushIntent
    func pushIntent(scope: V2PushIntentScope, ownerID: UUID) async throws -> V2LocalPushIntent
    func setPushIntentEnabled(_ enabled: Bool, scope: V2PushIntentScope, ownerID: UUID) async throws -> V2LocalPushIntent
    func stagePushToken(reference: UUID, scope: V2PushIntentScope, ownerID: UUID) async throws -> V2LocalPushIntent
    func preparePushSignOut(scope: V2PushIntentScope, ownerID: UUID) async throws -> V2LocalPushIntent
    func savePushInput(preferenceEnabled: Bool, desiredEnabled: Bool, tokenReference: UUID?, expected: V2LocalPushIntent) async throws -> Bool
    func savePushClaim(_ claim: V2PushIntentSessionClaim, expected: V2LocalPushIntent) async throws -> Bool
    func completePushClaim(epoch: UInt64, expected: V2LocalPushIntent) async throws -> Bool
    func restartPushIntentSession(expected: V2LocalPushIntent) async throws -> Bool
    func acknowledgePushIntent(_ expected: V2LocalPushIntent) async throws -> Bool
    func retryPushIntent(at: Date, expected: V2LocalPushIntent) async throws -> Bool
    func pausePushIntent(_ reason: V2PushIntentPauseReason, expected: V2LocalPushIntent) async throws -> Bool
}
