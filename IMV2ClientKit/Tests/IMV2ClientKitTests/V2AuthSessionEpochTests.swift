import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Credential effect ownership", .timeLimit(.minutes(1)))
struct V2AuthSessionEpochTests {
    @Test("a suspended old store effect cannot overwrite a newer login", arguments: Effect.allCases)
    func serializesStoreEffects(effect: Effect) async throws {
        let a = try credentials("a", expired: true)
        let b = try credentials("b")
        let successor = try credentials("a", refresh: "successor")
        let store = EpochCredentialStore(record: .init(credentials: a), block: effect)
        let session = V2AuthSession(credentialStore: store, transport: EpochRefresh(response: successor))
        let old = Task {
            if effect == .delete { try await session.handleTerminalRejection(); return "deleted" }
            if effect == .load { return try await session.accessToken() }
            return try await session.refresh().accessToken
        }
        await store.waitUntilBlocked()
        let oldEpoch = await session.currentEpoch()
        let establish = Task { try await session.establish(b) }
        while await session.currentEpoch() == oldEpoch { await Task.yield() }
        #expect(await store.savedB == false)
        await store.release()
        await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await old.value }
        try await establish.value
        #expect(await store.record == .init(credentials: b))
        #expect(try await session.accessToken() == b.accessToken)
        let restarted = V2AuthSession(credentialStore: store, transport: EpochRefresh(response: successor))
        #expect(try await restarted.realtimeCredentials().userID == b.userID)
    }

    @Test("concurrent restore callers share one suspended credential read")
    func restoreIsSingleFlight() async throws {
        let a = try credentials("a")
        let store = EpochCredentialStore(record: .init(credentials: a), block: .load)
        let session = V2AuthSession(credentialStore: store, transport: EpochRefresh(response: a))
        let first = Task { try await session.restoreState() }
        await store.waitUntilBlocked()
        let others = (0..<20).map { _ in Task { try await session.restoreState() } }
        await store.release()
        #expect(try await first.value == .authenticated(accessTokenExpiresAt: a.accessTokenExpiresAt))
        for task in others { #expect(try await task.value == .authenticated(accessTokenExpiresAt: a.accessTokenExpiresAt)) }
        #expect(await store.loads == 1)
    }

    @Test("a locked terminal deletion retries the handoff without restoring login authority")
    func lockedTerminalDeletionNeverRestoresOldRecord() async throws {
        let a = try credentials("a")
        let store = EpochCredentialStore(record: .init(credentials: a), failFirstDelete: true)
        let session = V2AuthSession(credentialStore: store, transport: EpochRefresh(response: a))
        await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await session.handleTerminalRejection() }
        await session.retryCredentialStoreAccess()
        await #expect(throws: V2AuthSessionError.unauthenticated) { try await session.accessToken() }
        #expect(await store.record == nil)
        #expect(await store.loads == 2) // read only to recover the same revocation handoff
    }

    @Test("the latest account intent owns establishment, and old terminal errors cannot delete it")
    func accountIntentsAndTerminalErrorsAreFenced() async throws {
        let store = EpochCredentialStore()
        let a = try credentials("a")
        let b = try credentials("b")
        let session = V2AuthSession(credentialStore: store, transport: EpochRefresh(response: a))
        let first = await session.beginEstablishment()
        let latest = await session.beginEstablishment()
        try await session.establish(b, ifCurrent: latest)
        await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await session.establish(a, ifCurrent: first) }
        await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await session.handleTerminalRejection(ifCurrent: first) }
        #expect(await store.record?.credentials == b)
        let pending = await session.beginEstablishment()
        await session.invalidateOutstandingWork()
        await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await session.establish(a, ifCurrent: pending) }
    }

    @Test("old TLS authentication rejection cannot erase a replacement account")
    func delayedTLSRejectionIsAccountScoped() async throws {
        let a = try credentials("a")
        let b = try credentials("b")
        let store = EpochCredentialStore(record: .init(credentials: a))
        let session = V2AuthSession(credentialStore: store, transport: EpochRefresh(response: a))
        let wire = EpochRejectedConnection()
        let coordinator = V2RealtimeSessionCoordinator(authSession: session, connection: wire, supportedCapabilityProfiles: ["base"])
        let connect = Task { try await coordinator.connect() }
        await wire.waitUntilEntered()
        try await session.establish(b)
        await wire.release()
        await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await connect.value }
        #expect(await store.record?.credentials == b)
    }

    @Test("a predecessor TLS rejection cannot delete a refreshed token in the same account epoch")
    func delayedTLSRejectionAfterRefresh() async throws {
        let a = try credentials("a")
        let refreshed = try V2AuthCredentials(userID: a.userID, deviceID: a.deviceID, accessToken: "rotated-access",
                                               accessTokenExpiresAt: .distantFuture, refreshCredential: "rotated-refresh")
        let store = EpochCredentialStore(record: .init(credentials: a))
        let session = V2AuthSession(credentialStore: store, transport: EpochRefresh(response: refreshed))
        let wire = EpochRejectedConnection()
        let coordinator = V2RealtimeSessionCoordinator(authSession: session, connection: wire, supportedCapabilityProfiles: ["base"])
        let connect = Task { try await coordinator.connect() }
        await wire.waitUntilEntered()
        let epoch = await session.currentEpoch()
        _ = try await session.refresh()
        #expect(await session.currentEpoch() == epoch)
        await wire.release()
        await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await connect.value }
        #expect(await store.record?.credentials == refreshed)
    }

    @Test("a slow observer retains its terminal state across a replacement login")
    func terminalSnapshotCannotBeCoalescedByAnotherEpoch() async throws {
        let a = try credentials("a")
        let b = try credentials("b")
        let store = EpochCredentialStore(record: .init(credentials: a))
        let session = V2AuthSession(credentialStore: store, transport: EpochRefresh(response: a))
        _ = try await session.restoreState()
        let epoch = await session.currentEpoch()
        let stream = await session.sessionUpdates(for: epoch)
        try await session.handleTerminalRejection()
        try await session.establish(b)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.status == .ended(.authenticationRequired))
        #expect(await iterator.next() == nil)
        var old = await session.sessionUpdates(for: epoch).makeAsyncIterator()
        #expect(await old.next()?.status == .ended(.superseded))
        var current = await session.sessionUpdates(for: session.currentEpoch()).makeAsyncIterator()
        #expect(await current.next()?.status == .active(.authenticated(accessTokenExpiresAt: b.accessTokenExpiresAt)))
    }

    @Test("subscribing after a locked deletion receives its completed pending result")
    func lateObserverSeesPendingCredentialDeletion() async throws {
        let a = try credentials("a")
        let store = EpochCredentialStore(record: .init(credentials: a), failFirstDelete: true)
        let session = V2AuthSession(credentialStore: store, transport: EpochRefresh(response: a))
        let epoch = await session.currentEpoch()
        await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await session.handleTerminalRejection() }
        var observer = await session.sessionUpdates(for: epoch).makeAsyncIterator()
        #expect(await observer.next()?.status == .ended(.credentialDeletionPending))
        #expect(await observer.next() == nil)
    }

    enum Effect: CaseIterable, Sendable { case load, pendingSave, successorSave, delete }
    private func credentials(_ name: String, expired: Bool = false, refresh: String? = nil) throws -> V2AuthCredentials {
        try .init(userID: .init(name), deviceID: .init(name + "-device"), accessToken: name + "-access",
                  accessTokenExpiresAt: expired ? .distantPast : .distantFuture, refreshCredential: refresh ?? name + "-refresh")
    }
}

private actor EpochCredentialStore: V2CredentialStore {
    private(set) var record: V2AuthCredentialRecord?
    private var block: V2AuthSessionEpochTests.Effect?
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var failFirstDelete: Bool
    private(set) var savedB = false
    private(set) var loads = 0
    init(record: V2AuthCredentialRecord? = nil, block: V2AuthSessionEpochTests.Effect? = nil, failFirstDelete: Bool = false) {
        self.record = record; self.block = block; self.failFirstDelete = failFirstDelete
    }
    func load() async -> V2AuthCredentialRecord? {
        loads += 1
        let captured = record
        await pause(.load)
        return captured
    }
    func save(_ value: V2AuthCredentialRecord) async {
        if value.pendingRefreshOperationID != nil { await pause(.pendingSave) }
        else if value.credentials.refreshCredential == "successor" { await pause(.successorSave) }
        record = value
        if value.credentials.userID.rawValue == "b" { savedB = true }
    }
    func delete() async throws {
        if failFirstDelete { failFirstDelete = false; throw V2CredentialStoreError.unavailable }
        await pause(.delete)
        record = nil
    }
    private func pause(_ effect: V2AuthSessionEpochTests.Effect) async {
        guard block == effect else { return }
        block = nil; entered = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilBlocked() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
private actor EpochRefresh: V2AuthTransport {
    let response: V2AuthCredentials
    init(response: V2AuthCredentials) { self.response = response }
    func refresh(_ request: V2RefreshRequest) -> V2AuthCredentials { response }
}
private actor EpochRejectedConnection: V2RealtimeConnection {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func connectAndAuthenticate(accessToken: String, deviceID: DeviceID, supportedCapabilityProfiles: Set<String>) async throws -> V2AuthenticatedClientSession {
        entered = true; observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
        throw V2TLSFrameConnectionError.authenticationFailed
    }
    func disconnect() {}
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { waiter?.resume(); waiter = nil }
}
