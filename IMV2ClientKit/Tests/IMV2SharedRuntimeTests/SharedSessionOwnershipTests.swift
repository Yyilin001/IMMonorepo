import Foundation
import Testing
import IMV2Core
import IMV2ClientRuntime
import IMV2SharedRuntime

@Suite(.timeLimit(.minutes(1))) struct SharedSessionOwnershipTests {
    @Test func sharedSessionErrorsRetainTheirCauses() {
        let mappings: [(any Error, SharedFailure)] = [
            (V2AuthSessionError.unauthenticated, .authenticationRequired),
            (V2AuthSessionError.credentialsUnavailable, .credentialsUnavailable),
            (V2AuthSessionError.malformedCredentials, .malformedCredentials),
            (V2AuthSessionError.deviceMismatch, .deviceMismatch),
            (V2AuthSessionError.sessionInvalidated, .sessionInvalidated),
            (V2ClientSessionBootstrapError.authenticationRequired, .authenticationRequired),
            (V2ClientSessionBootstrapError.credentialsUnavailable, .credentialsUnavailable),
            (V2ClientSessionBootstrapError.credentialIssueRecoveryPending, .credentialIssueRecoveryPending),
            (V2ClientSessionBootstrapError.localStoreCloseFailed, .localStoreCloseFailed)
        ]
        for (error, expected) in mappings {
            #expect(sharedFailure(error) == expected)
        }
    }

    @Test func exitRetainsIntentAndCredentialsUntilStoreReallyCloses() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = try await f.session.openEstablishedSession()
        #expect(await f.session.ownedStoreCount() == 1)
        try await f.session.beginSignOut()
        await #expect(throws: V2SharedSessionError.self) { try await f.session.completeSignOut() }
        #expect(await f.marker.pending)
        #expect(await f.credentials.record != nil)
        await f.closeFailure.set(true)
        await #expect(throws: V2ClientSessionBootstrapError.self) { try await f.session.closeLocalStore(store) }
        #expect(await f.session.ownedStoreCount() == 1)
        #expect(await f.marker.pending)
        await f.closeFailure.set(false)
        try await f.session.closeLocalStore(store)
        try await f.session.completeSignOut()
        #expect(await f.credentials.record == nil)
        #expect(await f.credentials.deletions == 1)
        #expect(await !f.marker.pending)
        #expect(await f.session.ownedStoreCount() == 0)
        await #expect(throws: V2ClientSessionBootstrapError.self) { _ = try await f.session.openEstablishedSession() }
    }

    @Test func accountActivitiesDrainBeforeTheOwnedDatabaseCanClose() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = try await f.session.openEstablishedSession(), account = V2AccountRuntime(), barrier = Barrier()
        try await f.session.adoptAccount(account, store: store)
        await account.startActivity(id: "blocked-file-operation") { await barrier.wait(); try Task.checkCancellation() }
        await barrier.waitUntilStarted()
        await #expect(throws: V2SharedSessionError.self) { try await f.session.closeLocalStore(store) }
        let closing = Task { await f.session.closeAccount(account) }
        // An activity that has not physically returned still fences SQLite close.
        await #expect(throws: V2SharedSessionError.self) { try await f.session.closeLocalStore(store) }
        await barrier.release(); await closing.value
        try await f.session.closeLocalStore(store)
        #expect(await f.session.ownedStoreCount() == 0)
        #expect(await f.credentials.record != nil) // close preserves login
    }

    @Test func callerCancellationDoesNotTruncateCommittedExit() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Restore identity before terminal rejection, just as a restored App would.
        _ = try await f.auth.restoreState()
        await f.credentials.blockDeletion()
        try await f.session.beginSignOut()
        let first = Task { try await f.session.completeSignOut() }
        await f.credentials.deleteBarrier.waitUntilStarted()
        first.cancel()
        let second = Task { try await f.session.completeSignOut() }
        #expect(await f.marker.pending)
        await f.credentials.deleteBarrier.release()
        try await first.value; try await second.value
        #expect(await !f.marker.pending)
        #expect(await f.credentials.deletions == 1)
    }

    @Test func pendingExitBlocksOpenAndMaintenanceCancellationDrainsPhysicalWork() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.marker.markPending()
        await #expect(throws: V2OfflineReadBootstrapError.self) { _ = try await f.session.openEstablishedSession() }
        #expect(await f.session.ownedStoreCount() == 0)
        let barrier = Barrier()
        let running = Task { try await f.session.runMaintenance(.deviceRevocation) { await barrier.wait(); try Task.checkCancellation() } }
        await barrier.waitUntilStarted()
        running.cancel()
        #expect(await f.session.activeTaskCount() == 1)
        await #expect(throws: V2SharedSessionError.self) {
            try await f.session.runMaintenance(.deviceRevocation) {}
        }
        let draining = Task { await f.session.suspendMaintenance() }
        await barrier.release()
        await draining.value
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await f.session.activeTaskCount() == 0)
    }

    @Test func exitFencesAnOpeningThatIgnoresCancellationUntilDiskReturns() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.binding.blockSave()
        let opening = Task { try await f.session.openEstablishedSession() }
        await f.binding.barrier.waitUntilStarted()
        let exit = Task { try await f.session.beginSignOut() }
        await f.marker.waitUntilMarked()
        #expect(await f.session.activeTaskCount() == 1)
        await f.binding.barrier.release()
        _ = await opening.result
        try await exit.value
        #expect(await f.session.activeTaskCount() == 0)
        #expect(await f.session.ownedStoreCount() == 0)
        try await f.session.completeSignOut()
        #expect(await f.credentials.record == nil)
    }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-session-" + UUID().uuidString)
    let credentials: Credentials
    let binding = Binding()
    let marker = ExitMarker()
    let closeFailure = CloseFailure()
    let auth: V2AuthSession
    let session: V2SharedSession
    init() throws {
        credentials = Credentials(try .init(userID: .init(UUID().uuidString), deviceID: .init(UUID().uuidString),
            accessToken: "test-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "test-refresh",
            revocationCredential: .generate(), revocationCredentialExpiresAt: .distantFuture))
        auth = V2AuthSession(credentialStore: credentials, transport: NoRefresh(), revocationScheduler: Revocations())
        let failure = closeFailure
        let bootstrap = V2ClientSessionBootstrapper(authSession: auth, localStoreBootstrapper: .init(bindingStore: binding),
            databaseURL: root.appendingPathComponent("unused.sqlite"),
            accountStorageRoots: .init(persistent: root.appendingPathComponent("accounts"), cache: root.appendingPathComponent("cache")),
            beforeClosingLocalStore: { _ in try await failure.check() })
        session = V2SharedSession(authSession: auth, bootstrapper: bootstrap, exitIntent: marker)
    }
}
private actor Barrier {
    private var started = false
    private var released = false
    private var starts: [CheckedContinuation<Void, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true; starts.forEach { $0.resume() }; starts.removeAll()
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { starts.append($0) } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private actor Credentials: V2CredentialStore {
    var record: V2AuthCredentialRecord?
    var deletions = 0
    let deleteBarrier = Barrier()
    private var blocks = false
    init(_ credentials: V2AuthCredentials) { record = .init(credentials: credentials) }
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ value: V2AuthCredentialRecord) { record = value }
    func blockDeletion() { blocks = true }
    func delete() async { if blocks { await deleteBarrier.wait() }; deletions += 1; record = nil }
}
private actor Binding: V2InstallationBindingStore {
    private var value: V2LocalInstallationBinding?
    let barrier = Barrier()
    private var blocks = false
    func blockSave() { blocks = true }
    func load() -> V2LocalInstallationBinding? { value }
    func save(_ value: V2LocalInstallationBinding) async { if blocks { await barrier.wait() }; self.value = value }
    func delete() { value = nil }
}
private actor ExitMarker: V2SharedExitIntentStoring {
    var pending = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func isPending() -> Bool { pending }
    func markPending() { pending = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func waitUntilMarked() async { if !pending { await withCheckedContinuation { waiters.append($0) } } }
    func clearPending() { pending = false }
}
private actor CloseFailure {
    var fails = false
    func set(_ value: Bool) { fails = value }
    func check() throws { if fails { throw V2ClientSessionBootstrapError.localStoreCloseFailed } }
}
private struct NoRefresh: V2AuthTransport {
    func refresh(_ request: V2RefreshRequest) async throws -> V2AuthCredentials { throw URLError(.notConnectedToInternet) }
}

private actor Revocations: V2DeviceRevocationScheduling {
    private var intents: [V2DeviceRevocationIntent] = []
    func enqueue(_ intent: V2DeviceRevocationIntent) { intents.append(intent) }
}
