import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 client session bootstrap")
struct V2ClientSessionBootstrapperTests {
    @Test("late issued authority is durably relinquished after cancellation, logout or replacement", arguments: ["cancel", "logout", "replacement", "adopted"])
    func relinquishesLateIssuedResult(ending: String) async throws {
        let url = temporarySessionBootstrapDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let credentials = try V2AuthCredentials(userID: .init("old-account"), deviceID: .init("old-device"),
            accessToken: "old-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "old-refresh")
        let replacement = try V2AuthCredentials(userID: .init("new-account"), deviceID: .init("new-device"),
            accessToken: "new-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "new-refresh")
        let credentialStore = SessionBootstrapCredentialStore()
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let persistence = IssuedRecoveryTestPersistence()
        let recovery = V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue)
        let auth = V2AuthSession(credentialStore: credentialStore, transport: SessionBootstrapRefreshTransport(), revocationScheduler: queue)
        let bootstrapper = V2ClientSessionBootstrapper(authSession: auth,
            localStoreBootstrapper: .init(bindingStore: SessionBootstrapBindingStore()), databaseURL: url)
        let provider = DeferredRecoveringBootstrapProvider(credentials: credentials, recovery: recovery)
        let task = Task { try await bootstrapper.establishSession(using: provider) }
        await provider.waitUntilStarted()
        if ending == "cancel" { task.cancel() }
        else if ending == "logout" { try await auth.handleTerminalRejection() }
        else { try await auth.establish(ending == "adopted" ? credentials : replacement) }
        await provider.release()
        if ending == "cancel" {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await task.value }
        }
        #expect(await credentialStore.load()?.credentials == (ending == "replacement" ? replacement : ending == "adopted" ? credentials : nil))
        #expect(try await queue.jobs().map(\.intent.deviceID) == (ending == "adopted" ? [] : [credentials.deviceID]))
        #expect(try persistence.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("logout fences a login that has not yet begun credential issuance")
    func logoutPreventsLateEstablishmentStart() async throws {
        let url = temporarySessionBootstrapDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let credentialStore = SessionBootstrapCredentialStore()
        let auth = V2AuthSession(credentialStore: credentialStore, transport: SessionBootstrapRefreshTransport())
        let bootstrapper = V2ClientSessionBootstrapper(authSession: auth,
            localStoreBootstrapper: .init(bindingStore: SessionBootstrapBindingStore()), databaseURL: url)
        let expected = await auth.currentEpoch()
        let credentials = try V2AuthCredentials(userID: .init("old-account"), deviceID: .init("old-device"),
            accessToken: "test-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "test-refresh")
        let provider = SessionBootstrapProvider(credentials: credentials)
        await auth.invalidateOutstandingWork()
        try await auth.handleTerminalRejection()
        await #expect(throws: V2AuthSessionError.sessionInvalidated) {
            try await bootstrapper.establishSession(using: provider, ifCurrent: expected)
        }
        #expect(await provider.issuedCount() == 0)
        #expect(await credentialStore.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

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

    @Test("production scoped bootstrap reopens retained commands through a fresh store object")
    func scopedBootstrapOwnsStoreCloseAndReopen() async throws {
        let url = temporarySessionBootstrapDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let credentials = try V2AuthCredentials(userID: .init("account-a"), deviceID: .init("device-a"),
                                                accessToken: "access", accessTokenExpiresAt: .distantFuture, refreshCredential: "refresh")
        let bootstrapper = V2ClientSessionBootstrapper(
            authSession: V2AuthSession(credentialStore: SessionBootstrapCredentialStore(), transport: SessionBootstrapRefreshTransport()),
            localStoreBootstrapper: .init(bindingStore: SessionBootstrapBindingStore()),
            databaseURL: url, accountStorageRoot: url.appendingPathExtension("accounts")
        )
        let first = try await bootstrapper.establishSession(using: SessionBootstrapProvider(credentials: credentials))
        let scope = try #require(await bootstrapper.storageScope(for: first))
        #expect(scope.accountID == credentials.userID)
        #expect(scope.database.primary != url)
        let command = try await persistDurableMessage(in: first, roomID: .init("room-a"),
            clientMessageID: .init("pending-a"), text: "preserve")
        try await bootstrapper.closeLocalStore(first)
        let reopened = try await bootstrapper.openEstablishedSession()
        #expect(reopened !== first)
        #expect(try await bootstrapper.storageScope(for: reopened) == scope)
        try await bootstrapper.closeLocalStore(first)
        #expect(try await savedDurableMessages(in: reopened) == [command])
        try await bootstrapper.closeLocalStore(reopened)
    }

    @Test("a late old account provider cannot overwrite a newer bootstrap")
    func lateAccountProviderCannotReplaceNewSession() async throws {
        let url = temporarySessionBootstrapDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let credentialStore = SessionBootstrapCredentialStore()
        let auth = V2AuthSession(credentialStore: credentialStore, transport: SessionBootstrapRefreshTransport())
        let bootstrapper = V2ClientSessionBootstrapper(authSession: auth, localStoreBootstrapper: .init(bindingStore: SessionBootstrapBindingStore()),
                                                      databaseURL: url, accountStorageRoot: url.appendingPathExtension("accounts"))
        let a = try V2AuthCredentials(userID: .init("account-a"), deviceID: .init("device-a"), accessToken: "a", accessTokenExpiresAt: .distantFuture, refreshCredential: "a-refresh")
        let b = try V2AuthCredentials(userID: .init("account-b"), deviceID: .init("device-b"), accessToken: "b", accessTokenExpiresAt: .distantFuture, refreshCredential: "b-refresh")
        let provider = DelayedSessionBootstrapProvider(credentials: a)
        let old = Task { try await bootstrapper.establishSession(using: provider) }
        await provider.waitUntilIssued()
        let newStore = try await bootstrapper.establishSession(using: SessionBootstrapProvider(credentials: b))
        await provider.release()
        await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await old.value }
        #expect(await credentialStore.load()?.credentials == b)
        #expect(try await bootstrapper.storageScope(for: newStore)?.accountID == b.userID)
        try await bootstrapper.closeLocalStore(newStore)
    }

    @Test("revocation while opening the database still requests authentication, not a storage error")
    func revocationDuringLocalStoreOpen() async throws {
        let url = temporarySessionBootstrapDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let credentials = try V2AuthCredentials(userID: .init("account-a"), deviceID: .init("device-a"), accessToken: "a", accessTokenExpiresAt: .distantFuture, refreshCredential: "a-refresh")
        let auth = V2AuthSession(credentialStore: SessionBootstrapCredentialStore(), transport: SessionBootstrapRefreshTransport())
        try await auth.establish(credentials)
        let binding = DelayedSessionBindingStore()
        let bootstrapper = V2ClientSessionBootstrapper(authSession: auth, localStoreBootstrapper: .init(bindingStore: binding), databaseURL: url)
        let opening = Task { try await bootstrapper.openEstablishedSession() }
        await binding.waitUntilRead()
        try await auth.handleTerminalRejection()
        await binding.release()
        await #expect(throws: V2ClientSessionBootstrapError.authenticationRequired) { try await opening.value }
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

    func discardIssuedDeviceCredentials(_ credentials: V2AuthCredentials) {}
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

private actor DelayedSessionBootstrapProvider: V2AccountDeviceCredentialProvider {
    let credentials: V2AuthCredentials
    private var issued = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    init(credentials: V2AuthCredentials) { self.credentials = credentials }
    func issueDeviceCredentials() async -> V2AuthCredentials {
        issued = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { continuation = $0 }
        return credentials
    }
    func waitUntilIssued() async { if !issued { await withCheckedContinuation { observer = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor DelayedSessionBindingStore: V2InstallationBindingStore {
    private let binding = V2LocalInstallationBinding(value: UUID())
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func load() async -> V2LocalInstallationBinding? {
        entered = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { continuation = $0 }
        return binding
    }
    func save(_ value: V2LocalInstallationBinding) {}
    func delete() {}
    func waitUntilRead() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor DeferredRecoveringBootstrapProvider: V2AccountDeviceCredentialProvider, V2AccountDeviceCredentialIssueFinalizer {
    let credentials: V2AuthCredentials
    let recovery: V2IssuedCredentialRecoveryStore
    private var receipt: V2DeviceRevocationIntent?
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(credentials: V2AuthCredentials, recovery: V2IssuedCredentialRecoveryStore) {
        self.credentials = credentials; self.recovery = recovery
    }
    func issueDeviceCredentials() async throws -> V2AuthCredentials {
        started = true; observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
        receipt = try await recovery.receive(credentials, operationID: UUID())
        return credentials
    }
    func finalizeIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws {
        try await recovery.adopt(receipt!)
    }
    func discardIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws {
        try await recovery.abandon(receipt!)
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
