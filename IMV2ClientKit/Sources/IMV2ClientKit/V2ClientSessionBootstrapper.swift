import Foundation

/// The app-owned account factor (password, passkey, SSO, or another approved
/// mechanism) implements this boundary. ClientKit deliberately receives only
/// the already-issued device credentials and never imports a V1 session.
public protocol V2AccountDeviceCredentialProvider: Sendable {
    func issueDeviceCredentials() async throws -> V2AuthCredentials
}

/// Providers that persist a first-registration operation use this callback to
/// remove the operation only after `V2AuthSession` has durably committed the
/// returned credential pair. Ordinary providers do not need to conform.
public protocol V2AccountDeviceCredentialIssueFinalizer: Sendable {
    func finalizeIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws
}

public enum V2ClientSessionBootstrapError: Error, Equatable, Sendable {
    case authenticationRequired
    case credentialsUnavailable
}

/// Coordinates the two device-local roots in the only safe order: an existing
/// authenticated session may open its bound SQLite store; an unauthenticated
/// installation must first receive V2 device credentials from the trusted
/// account boundary. Views should call this actor instead of opening the local
/// store or writing the credential Keychain item directly.
public actor V2ClientSessionBootstrapper {
    private let authSession: V2AuthSession
    private let localStoreBootstrapper: V2LocalStoreBootstrapper
    private let databaseURL: URL

    public init(authSession: V2AuthSession, localStoreBootstrapper: V2LocalStoreBootstrapper, databaseURL: URL) {
        self.authSession = authSession
        self.localStoreBootstrapper = localStoreBootstrapper
        self.databaseURL = databaseURL
    }

    /// Restores an established V2 session. It deliberately does not invoke an
    /// account provider; callers can render an explicit re-authentication UI
    /// when this reports `authenticationRequired`.
    public func openEstablishedSession() async throws -> GRDBV2LocalSyncStore {
        do {
            _ = try await authSession.accessToken()
        } catch V2AuthSessionError.unauthenticated {
            throw V2ClientSessionBootstrapError.authenticationRequired
        } catch V2AuthSessionError.credentialsUnavailable {
            throw V2ClientSessionBootstrapError.credentialsUnavailable
        }
        return try await localStoreBootstrapper.open(databaseURL: databaseURL)
    }

    /// Establishes the first device credential record from a trusted account
    /// provider, then opens a local store bound to this installation. A failed
    /// store open leaves the durable credential record intact so a later retry
    /// can safely use `openEstablishedSession()`.
    public func establishSession(using provider: any V2AccountDeviceCredentialProvider) async throws -> GRDBV2LocalSyncStore {
        let credentials = try await provider.issueDeviceCredentials()
        try await authSession.establish(credentials)
        if let finalizer = provider as? any V2AccountDeviceCredentialIssueFinalizer {
            try await finalizer.finalizeIssuedDeviceCredentials(credentials)
        }
        return try await localStoreBootstrapper.open(databaseURL: databaseURL)
    }
}
