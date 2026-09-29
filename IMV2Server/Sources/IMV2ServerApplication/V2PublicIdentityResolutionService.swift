import IMV2ServerContracts
import Foundation
import IMV2Core

/// Applies the short discovery lifetime around the existing exact lookup policy.
/// Authorization is rechecked after the directory I/O; no CDN/storage dependency.
public struct V2PublicIdentityResolutionService: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let directory: any V2PublicIdentityDirectoryReading
    private let now: @Sendable () -> Date

    public init(authenticator: any V2GatewayAuthenticator, directory: any V2PublicIdentityDirectoryReading,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.authenticator = authenticator; self.directory = directory; self.now = now
    }

    public func resolve(handle: V2PublicHandle, accessToken: String, deviceID: DeviceID) async throws -> V2PublicIdentityResolution? {
        let observed = now()
        let actor = try await authenticator.authenticateSession(accessToken: accessToken, deviceID: deviceID)
        try Task.checkCancellation()
        guard actor.expiresAt.map({ $0 > observed }) ?? true else { throw V2GatewayAuthenticationError.unauthenticated }
        guard let identity = try await directory.resolve(handle: handle, actorUserID: actor.userID) else { return nil }
        try Task.checkCancellation()
        guard identity.handle == handle else { throw V2PublicIdentityDirectoryError.unavailable }
        let current = try await authenticator.authenticateSession(accessToken: accessToken, deviceID: deviceID)
        try Task.checkCancellation()
        guard current.userID == actor.userID else { throw V2GatewayAuthenticationError.unauthenticated }
        let emitted = now()
        let maximumEnd = observed.addingTimeInterval(Double(V2PublicIdentityResolution.maximumLifetimeMilliseconds) / 1_000)
        let validUntil = min(maximumEnd, actor.expiresAt ?? maximumEnd, current.expiresAt ?? maximumEnd)
        guard emitted >= observed, validUntil > emitted else { throw V2PublicIdentityDirectoryError.unavailable }
        return try .init(identity: identity, actorUserID: actor.userID, deviceID: deviceID,
            observedAt: observed, validUntil: validUntil, serverNow: emitted)
    }
}
