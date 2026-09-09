import Foundation
import IMV2Core

/// The app-owned account factor (password, passkey, SSO, or another approved
/// mechanism) implements this boundary. ClientKit deliberately receives only
/// already-issued device credentials and does not own account-factor state.
public protocol V2AccountDeviceCredentialProvider: Sendable {
    func issueDeviceCredentials() async throws -> V2AuthCredentials
}

/// Providers that persist a first-registration operation use this callback to
/// remove the operation only after `V2AuthSession` has durably committed the
/// returned credential pair. Ordinary providers do not need to conform.
public protocol V2AccountDeviceCredentialIssueFinalizer: Sendable {
    func finalizeIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws
    func discardIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws
}

public enum V2ClientSessionBootstrapError: Error, Equatable, Sendable {
    case authenticationRequired
    case credentialsUnavailable
    case credentialIssueRecoveryPending
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
    private let accountStorage: V2AccountLocalStoreOwner?

    public init(authSession: V2AuthSession, localStoreBootstrapper: V2LocalStoreBootstrapper, databaseURL: URL, accountStorageRoot: URL? = nil) {
        self.authSession = authSession
        self.localStoreBootstrapper = localStoreBootstrapper
        self.databaseURL = databaseURL
        accountStorage = accountStorageRoot.map { V2AccountLocalStoreOwner(root: $0, legacyDatabaseURL: databaseURL, bootstrapper: localStoreBootstrapper) }
    }

    public func storageScope(for store: GRDBV2LocalSyncStore) async throws -> V2AccountStorageScope? {
        try await accountStorage?.scope(for: store)
    }

    public func closeLocalStore(_ store: GRDBV2LocalSyncStore) async throws {
        if let accountStorage { try await accountStorage.close(store) }
        else { try await store.close() }
    }

    private func openLocalStore(userID: IMV2Core.UserID) async throws -> GRDBV2LocalSyncStore {
        if let accountStorage { return try await accountStorage.open(accountID: userID) }
        return try await localStoreBootstrapper.open(databaseURL: databaseURL, userID: userID)
    }

    /// Restores an established V2 session. It deliberately does not invoke an
    /// account provider; callers can render an explicit re-authentication UI
    /// when this reports `authenticationRequired`.
    public func openEstablishedSession() async throws -> GRDBV2LocalSyncStore {
        do {
            let credentials = try await authSession.realtimeCredentials()
            if let epoch = credentials.sessionEpoch { try await authSession.requireAuthenticatedEpoch(epoch) }
            let store = try await openLocalStore(userID: credentials.userID)
            if let epoch = credentials.sessionEpoch { try await authSession.requireAuthenticatedEpoch(epoch) }
            return store
        } catch V2AuthSessionError.unauthenticated {
            throw V2ClientSessionBootstrapError.authenticationRequired
        } catch V2AuthSessionError.credentialsUnavailable {
            throw V2ClientSessionBootstrapError.credentialsUnavailable
        }
    }

    /// Establishes the first device credential record from a trusted account
    /// provider, then opens a local store bound to this installation. A failed
    /// store open leaves the durable credential record intact so a later retry
    /// can safely use `openEstablishedSession()`.
    public func establishSession(using provider: any V2AccountDeviceCredentialProvider, ifCurrent expectedEpoch: V2AuthSessionEpoch? = nil) async throws -> GRDBV2LocalSyncStore {
        try Task.checkCancellation()
        let epoch: V2AuthSessionEpoch
        if let expectedEpoch {
            epoch = try await authSession.beginEstablishment(ifCurrent: expectedEpoch)
        } else {
            epoch = await authSession.beginEstablishment()
        }
        do {
            let credentials = try await provider.issueDeviceCredentials()
            do {
                try Task.checkCancellation()
                try await authSession.establish(credentials, ifCurrent: epoch)
            } catch {
                if error is CancellationError || (error as? V2AuthSessionError) == .sessionInvalidated,
                   let finalizer = provider as? any V2AccountDeviceCredentialIssueFinalizer {
                    do {
                        if try await authSession.ownsCredentialSession(credentials) {
                            try await finalizer.finalizeIssuedDeviceCredentials(credentials)
                        } else {
                            try await finalizer.discardIssuedDeviceCredentials(credentials)
                        }
                    } catch {
                        throw V2ClientSessionBootstrapError.credentialIssueRecoveryPending
                    }
                }
                // An uncertain credential-store save retains the recovery
                // receipt for cold-start comparison with the durable record.
                throw error
            }
            if let finalizer = provider as? any V2AccountDeviceCredentialIssueFinalizer {
                try await finalizer.finalizeIssuedDeviceCredentials(credentials)
            }
            try await authSession.requireCurrentEpoch(epoch)
            let store = try await openLocalStore(userID: credentials.userID)
            try await authSession.requireCurrentEpoch(epoch)
            return store
        } catch {
            await authSession.abandonEstablishment(ifCurrent: epoch)
            throw error
        }
    }
}
