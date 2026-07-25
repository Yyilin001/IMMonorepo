import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 client session bootstrap")
struct V2ClientSessionBootstrapperTests {
    @Test("an unauthenticated installation never opens the V2 local store")
    func unauthenticatedInstallationRequiresTrustedCredentials() async throws {
        let databaseURL = temporarySessionBootstrapDatabaseURL()
        let credentialStore = SessionBootstrapCredentialStore()
        let authSession = V2AuthSession(credentialStore: credentialStore, transport: SessionBootstrapRefreshTransport())
        let bootstrapper = V2ClientSessionBootstrapper(
            authSession: authSession,
            localStoreBootstrapper: V2LocalStoreBootstrapper(bindingStore: SessionBootstrapBindingStore()),
            databaseURL: databaseURL
        )

        await #expect(throws: V2ClientSessionBootstrapError.authenticationRequired) {
            try await bootstrapper.openEstablishedSession()
        }
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    }

    @Test("trusted credentials establish the session before the bound local store opens")
    func trustedCredentialsEstablishBeforeStoreOpen() async throws {
        let databaseURL = temporarySessionBootstrapDatabaseURL()
        let credentialStore = SessionBootstrapCredentialStore()
        let bindingStore = SessionBootstrapBindingStore()
        let issued = try V2AuthCredentials(
            userID: .init("00000000-0000-0000-0000-000000000601"),
            deviceID: .init("00000000-0000-0000-0000-000000000602"),
            accessToken: "access",
            accessTokenExpiresAt: .distantFuture,
            refreshCredential: "refresh"
        )
        let provider = SessionBootstrapProvider(credentials: issued)
        let first = V2ClientSessionBootstrapper(
            authSession: V2AuthSession(credentialStore: credentialStore, transport: SessionBootstrapRefreshTransport()),
            localStoreBootstrapper: V2LocalStoreBootstrapper(bindingStore: bindingStore),
            databaseURL: databaseURL
        )

        _ = try await first.establishSession(using: provider)
        #expect(await provider.issuedCount() == 1)
        #expect((await credentialStore.load())?.credentials == issued)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))

        let restored = V2ClientSessionBootstrapper(
            authSession: V2AuthSession(credentialStore: credentialStore, transport: SessionBootstrapRefreshTransport()),
            localStoreBootstrapper: V2LocalStoreBootstrapper(bindingStore: bindingStore),
            databaseURL: databaseURL
        )
        _ = try await restored.openEstablishedSession()
        #expect(await provider.issuedCount() == 1)
    }

    @Test("a replay-operation provider is finalized only after credentials are established")
    func finalizesIssuedCredentialsAfterSessionPersistence() async throws {
        let databaseURL = temporarySessionBootstrapDatabaseURL()
        let credentialStore = SessionBootstrapCredentialStore()
        let issued = try V2AuthCredentials(
            userID: .init("00000000-0000-0000-0000-000000000611"),
            deviceID: .init("00000000-0000-0000-0000-000000000612"),
            accessToken: "access",
            accessTokenExpiresAt: .distantFuture,
            refreshCredential: "refresh"
        )
        let provider = FinalizingSessionBootstrapProvider(credentials: issued, credentialStore: credentialStore)
        let bootstrapper = V2ClientSessionBootstrapper(
            authSession: V2AuthSession(credentialStore: credentialStore, transport: SessionBootstrapRefreshTransport()),
            localStoreBootstrapper: V2LocalStoreBootstrapper(bindingStore: SessionBootstrapBindingStore()),
            databaseURL: databaseURL
        )

        _ = try await bootstrapper.establishSession(using: provider)

        #expect(await provider.finalizedCredentials() == [issued])
        #expect(await provider.sawPersistedCredentialsBeforeFinalization())
    }
}

private actor SessionBootstrapCredentialStore: V2CredentialStore {
    private var record: V2AuthCredentialRecord?
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ record: V2AuthCredentialRecord) { self.record = record }
    func delete() { record = nil }
}

private actor SessionBootstrapBindingStore: V2InstallationBindingStore {
    private var binding: V2LocalInstallationBinding?
    func load() -> V2LocalInstallationBinding? { binding }
    func save(_ binding: V2LocalInstallationBinding) { self.binding = binding }
    func delete() { binding = nil }
}

private actor SessionBootstrapProvider: V2AccountDeviceCredentialProvider {
    private let credentials: V2AuthCredentials
    private var count = 0
    init(credentials: V2AuthCredentials) { self.credentials = credentials }
    func issueDeviceCredentials() -> V2AuthCredentials { count += 1; return credentials }
    func issuedCount() -> Int { count }
}

private actor FinalizingSessionBootstrapProvider: V2AccountDeviceCredentialProvider, V2AccountDeviceCredentialIssueFinalizer {
    private let credentials: V2AuthCredentials
    private let credentialStore: SessionBootstrapCredentialStore
    private var finalized: [V2AuthCredentials] = []
    private var observedPersistence = false

    init(credentials: V2AuthCredentials, credentialStore: SessionBootstrapCredentialStore) {
        self.credentials = credentials
        self.credentialStore = credentialStore
    }

    func issueDeviceCredentials() -> V2AuthCredentials { credentials }

    func finalizeIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws {
        observedPersistence = (await credentialStore.load())?.credentials == credentials
        finalized.append(credentials)
    }

    func finalizedCredentials() -> [V2AuthCredentials] { finalized }
    func sawPersistedCredentialsBeforeFinalization() -> Bool { observedPersistence }
}

private actor SessionBootstrapRefreshTransport: V2AuthTransport {
    func refresh(_: V2RefreshRequest) throws -> V2AuthCredentials {
        throw V2AuthTransportError.terminalRejection
    }
}

private func temporarySessionBootstrapDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "im-v2-session-bootstrap-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "state.sqlite")
}
