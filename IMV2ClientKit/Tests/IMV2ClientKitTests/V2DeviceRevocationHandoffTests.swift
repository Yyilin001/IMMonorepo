import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit

@Suite("Persistent device revocation handoff", .timeLimit(.minutes(1)))
struct V2DeviceRevocationHandoffTests {
    @Test("each interrupted handoff resumes the same operation without restoring or refreshing", arguments: FailurePoint.allCases)
    func resumesHandoff(at failure: FailurePoint) async throws {
        let old = try credentials("old")
        let persistence = RevocationTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: persistence)
        let store = HandoffCredentialStore(.init(credentials: old))
        let transport = HandoffTransport()
        let operationID = UUID()
        if failure == .intentSave { persistence.setFailure(.save) }
        if failure == .markerSave { await store.setFailure(.save) }
        if failure == .credentialDelete { await store.setFailure(.delete) }
        let session = V2AuthSession(credentialStore: store, transport: transport,
            revocationScheduler: queue, makeUUID: { operationID })
        await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await session.handleTerminalRejection() }
        let retained = try #require(await store.value)
        #expect(retained.credentials == old)
        #expect(retained.pendingRevocationOperationID == (failure == .markerSave ? nil : operationID))
        #expect(await session.currentState() == .credentialsUnavailable)
        #expect(await transport.calls == 0)
        persistence.setFailure(nil)
        await store.setFailure(nil)
        let restarted = V2AuthSession(credentialStore: store, transport: transport,
            revocationScheduler: V2DeviceRevocationStore(persistence: persistence), makeUUID: { operationID })
        if failure == .markerSave {
            // The App's earlier durable sign-out marker re-enters this path.
            try await restarted.handleTerminalRejection()
        } else {
            #expect(try await restarted.restoreState() == .unauthenticated)
        }
        #expect(await store.value == nil)
        let jobs = try await queue.jobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.intent == .init(credentials: old, operationID: operationID))
        await #expect(throws: V2AuthSessionError.unauthenticated) { try await restarted.accessToken() }
        #expect(await transport.calls == 0)
    }

    @Test("a settled queue entry and interrupted credential delete reuse the original operation")
    func completedBeforeDelete() async throws {
        let old = try credentials("old")
        let persistence = RevocationTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: persistence)
        let store = HandoffCredentialStore(.init(credentials: old))
        await store.setFailure(.delete)
        let session = V2AuthSession(credentialStore: store, transport: HandoffTransport(), revocationScheduler: queue)
        await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await session.handleTerminalRejection() }
        let job = try #require(try await queue.jobs().first)
        #expect(try await queue.complete(job))
        await store.setFailure(nil)
        let restarted = V2AuthSession(credentialStore: store, transport: HandoffTransport(),
            revocationScheduler: V2DeviceRevocationStore(persistence: persistence))
        #expect(try await restarted.restoreState() == .unauthenticated)
        #expect(try await queue.jobs().first?.intent == job.intent)
        #expect(await store.value == nil)
    }

    @Test("an unavailable credential read never deletes proof; unreadable records cannot restore", arguments: [V2CredentialStoreError.unavailable, .malformedRecord, .permanentlyInvalidated])
    func failedRead(error: V2CredentialStoreError) async throws {
        let old = try credentials("old")
        let store = HandoffCredentialStore(.init(credentials: old))
        await store.setLoadFailure(error)
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let session = V2AuthSession(credentialStore: store, transport: HandoffTransport(), revocationScheduler: queue)
        if error == .unavailable {
            await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await session.handleTerminalRejection() }
            #expect(await store.value?.credentials == old)
        } else {
            try await session.handleTerminalRejection()
            #expect(await store.value == nil)
        }
        #expect(try await queue.jobs().isEmpty)
    }

    @Test("a new login hands off active or already-pending old credentials", arguments: [false, true])
    func replacementPreservesPendingHandoff(preMarked: Bool) async throws {
        let old = try credentials("old"), new = try credentials("new")
        let operationID = UUID()
        let store = HandoffCredentialStore(.init(credentials: old, pendingRevocationOperationID: preMarked ? operationID : nil))
        let persistence = RevocationTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: persistence)
        let session = V2AuthSession(credentialStore: store, transport: HandoffTransport(), revocationScheduler: queue, makeUUID: { operationID })
        persistence.setFailure(.save)
        await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await session.establish(new) }
        #expect(await store.value?.credentials == old)
        #expect(await store.value?.pendingRevocationOperationID == operationID)
        persistence.setFailure(nil)
        try await session.establish(new)
        #expect(try await session.accessToken() == new.accessToken)
        let job = try #require(try await queue.jobs().first)
        #expect(job.intent == .init(credentials: old, operationID: operationID))
        #expect(try await queue.complete(job))
        #expect(await store.value == .init(credentials: new))
    }

    @Test("a pending logout cannot reestablish the device being revoked")
    func sameDeviceCannotRestore() async throws {
        let old = try credentials("old")
        let store = HandoffCredentialStore(.init(credentials: old, pendingRevocationOperationID: UUID()))
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let session = V2AuthSession(credentialStore: store, transport: HandoffTransport(), revocationScheduler: queue)
        await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await session.establish(old) }
        #expect(await store.value?.pendingRevocationOperationID != nil)
        await session.retryCredentialStoreAccess()
        #expect(try await session.restoreState() == .unauthenticated)
        #expect(try await queue.jobs().count == 1)
    }

    @Test("an old suspended handoff drains before the new credential save")
    func lateHandoffCannotEraseReplacement() async throws {
        let old = try credentials("old"), new = try credentials("new")
        let store = HandoffCredentialStore(.init(credentials: old))
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let scheduler = BlockingRevocationScheduler(queue: queue)
        let session = V2AuthSession(credentialStore: store, transport: HandoffTransport(), revocationScheduler: scheduler)
        let logout = Task { try await session.handleTerminalRejection() }
        await scheduler.waitUntilEntered()
        let oldEpoch = await session.currentEpoch()
        let login = Task { try await session.establish(new) }
        while await session.currentEpoch() == oldEpoch { await Task.yield() }
        #expect(await store.value?.credentials == old)
        await scheduler.release()
        await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await logout.value }
        try await login.value
        #expect(await store.value == .init(credentials: new))
        #expect(try await queue.jobs().map(\.intent.deviceID) == [old.deviceID])
        #expect(try await session.accessToken() == new.accessToken)
    }

    @Test("recreated outbox owners retain retries and pause; stale completions cannot erase them")
    func durableJobState() async throws {
        let old = try credentials("old")
        let intent = V2DeviceRevocationIntent(credentials: old, operationID: UUID())
        let persistence = RevocationTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: persistence)
        try await queue.enqueue(intent)
        let initial = try #require(try await queue.jobs().first)
        let retry = Date(timeIntervalSince1970: 100)
        #expect(try await queue.recordFailure(initial, retryAt: retry))
        try await queue.enqueue(intent)
        let resumed = V2DeviceRevocationStore(persistence: persistence)
        #expect(try await resumed.due(at: retry.addingTimeInterval(-1)).isEmpty)
        let due = try #require(try await resumed.due(at: retry).first)
        #expect(due.attempts == 1)
        #expect(!due.intent.credential.rawValue.isEmpty)
        #expect(try await resumed.complete(initial) == false)
        #expect(try await resumed.recordFailure(initial, retryAt: .distantPast) == false)
        #expect(try await resumed.recordFailure(due, retryAt: retry, pauseReason: .operationConflict))
        #expect(try await resumed.due(at: .distantFuture).isEmpty)
        let paused = try #require(try await resumed.jobs().first)
        #expect(paused.pauseReason == .operationConflict)
        persistence.setFailure(.delete)
        await #expect(throws: V2DeviceRevocationStoreError.unavailable) { try await resumed.complete(paused) }
        persistence.setFailure(nil)
        #expect(try await resumed.jobs() == [paused])
        #expect(try await resumed.complete(paused))
        #expect(try persistence.load() == nil)
    }

    @Test("the independent outbox stores only old-session revocation authority and ignores local expiry")
    func limitedAuthority() async throws {
        let credentials = try credentials("old")
        let persistence = RevocationTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: persistence)
        let intent = V2DeviceRevocationIntent(credentials: credentials, operationID: UUID())
        try await queue.enqueue(intent)
        let data = try #require(try persistence.load())
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(credentials.accessToken))
        #expect(!json.contains(credentials.refreshCredential))
        #expect(!json.contains("accessToken"))
        #expect(!json.contains("refreshCredential"))
        #expect(try await queue.due(at: credentials.revocationCredentialExpiresAt.addingTimeInterval(100)).count == 1)
        await #expect(throws: V2DeviceRevocationStoreError.conflict) {
            try await queue.enqueue(.init(credentials: credentials, operationID: UUID()))
        }
        await #expect(throws: V2DeviceRevocationStoreError.conflict) {
            try await queue.enqueue(.init(credentials: self.credentials("other"), operationID: intent.operationID))
        }
        #expect(try persistence.load() == data)
    }

    @Test("bounded and corrupt outboxes fail closed without losing existing work")
    func capacityAndCorruption() async throws {
        let persistence = RevocationTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: persistence)
        for index in 0..<256 { try await queue.enqueue(.init(credentials: credentials("device-\(index)"), operationID: UUID())) }
        let full = try persistence.load()
        await #expect(throws: V2DeviceRevocationStoreError.capacityExceeded) {
            try await queue.enqueue(.init(credentials: self.credentials("extra"), operationID: UUID()))
        }
        #expect(try persistence.load() == full)
        for corrupt in [Data("bad-json".utf8), Data(#"{"version":2,"jobs":{}}"#.utf8)] {
            try persistence.save(corrupt)
            await #expect(throws: V2DeviceRevocationStoreError.malformedRecord) { try await queue.jobs() }
            await #expect(throws: V2DeviceRevocationStoreError.malformedRecord) {
                try await queue.enqueue(.init(credentials: self.credentials("extra"), operationID: UUID()))
            }
            #expect(try persistence.load() == corrupt)
        }
    }

    enum FailurePoint: CaseIterable, Sendable { case markerSave, intentSave, credentialDelete }
    private func credentials(_ id: String) throws -> V2AuthCredentials {
        try .init(userID: .init("user-" + id), deviceID: .init("device-" + id),
            accessToken: "secret-access-" + id, accessTokenExpiresAt: .distantFuture,
            refreshCredential: "secret-refresh-" + id, revocationCredential: .generate(),
            revocationCredentialExpiresAt: Date(timeIntervalSince1970: 50))
    }
}

final class RevocationTestPersistence: V2DeviceRevocationPersisting {
    enum Operation: Sendable { case load, save, delete }
    private struct State { var data: Data?; var failure: Operation? }
    private let state = Mutex(State())
    func setFailure(_ operation: Operation?) { state.withLock { $0.failure = operation } }
    func load() throws -> Data? {
        try state.withLock { state in
            guard state.failure != .load else { throw V2DeviceRevocationStoreError.unavailable }
            return state.data
        }
    }
    func save(_ data: Data) throws {
        try state.withLock { state in
            guard state.failure != .save else { throw V2DeviceRevocationStoreError.unavailable }
            state.data = data
        }
    }
    func delete() throws {
        try state.withLock { state in
            guard state.failure != .delete else { throw V2DeviceRevocationStoreError.unavailable }
            state.data = nil
        }
    }
}

private actor HandoffCredentialStore: V2CredentialStore {
    enum Operation { case save, delete }
    private(set) var value: V2AuthCredentialRecord?
    private var failure: Operation?
    private var loadFailure: V2CredentialStoreError?
    init(_ value: V2AuthCredentialRecord?) { self.value = value }
    func setFailure(_ failure: Operation?) { self.failure = failure }
    func setLoadFailure(_ failure: V2CredentialStoreError?) { loadFailure = failure }
    func load() throws -> V2AuthCredentialRecord? {
        if let loadFailure { throw loadFailure }
        return value
    }
    func save(_ value: V2AuthCredentialRecord) throws {
        guard failure != .save else { throw V2CredentialStoreError.unavailable }
        self.value = value
    }
    func delete() throws {
        guard failure != .delete else { throw V2CredentialStoreError.unavailable }
        value = nil
    }
}

private actor HandoffTransport: V2AuthTransport {
    private(set) var calls = 0
    func refresh(_ request: V2RefreshRequest) throws -> V2AuthCredentials {
        calls += 1
        throw V2AuthTransportError.terminalRejection
    }
}

private actor BlockingRevocationScheduler: V2DeviceRevocationScheduling {
    let queue: V2DeviceRevocationStore
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(queue: V2DeviceRevocationStore) { self.queue = queue }
    func enqueue(_ intent: V2DeviceRevocationIntent) async throws {
        entered = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
        try await queue.enqueue(intent)
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
