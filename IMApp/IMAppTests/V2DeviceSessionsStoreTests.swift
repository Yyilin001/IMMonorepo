import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2DeviceSessionsStoreTests {
    @Test("saved remote revocation survives page task cancellation and applies only a matched proof")
    func revokesRemoteSession() async throws {
        let current = DeviceID(uuid: UUID()), remote = DeviceID(uuid: UUID())
        let manager = DeviceSessionStoreManager(sessions: [
            .init(deviceID: current, deviceName: "Current", platform: "iOS", createdAt: .distantPast, lastActiveAt: .distantPast, isCurrentDevice: true),
            .init(deviceID: remote, deviceName: "Remote", platform: "iOS", createdAt: .distantPast, lastActiveAt: .distantPast, isCurrentDevice: false)])
        let operations = try fixtureOperations(targets: [remote], current: current)
        let store = V2DeviceSessionsStore(manager: manager, operations: operations)
        await store.refresh()
        let command = try #require(store.proposal(selection: .device(remote)))
        await store.confirm(command)
        #expect(store.sessions.count == 2)
        let observer = Task { await store.observeRevocations() }
        let worker = Task { try await operations.run() }
        defer { observer.cancel(); worker.cancel() }
        for _ in 0..<10_000 { if store.sessions.count == 1 { break }; await Task.yield() }
        #expect(store.sessions.map(\.deviceID) == [current])
        #expect(store.revocations.first?.command.operationID == command.operationID)
    }
    @Test("unknown original revocation blocks replacement identity")
    func unavailableSessionIsIdempotentForUI() async throws {
        let remote = DeviceID(uuid: UUID())
        let operations = try fixtureOperations(targets: [remote])
        let manager = DeviceSessionStoreManager(sessions: [try device(remote.rawValue, name: "Remote")])
        let store = V2DeviceSessionsStore(manager: manager, operations: operations)
        await store.refresh()
        let command = try #require(store.proposal(selection: .device(remote)))
        await store.confirm(command)
        let observer = Task { await store.observeRevocations() }; defer { observer.cancel() }
        for _ in 0..<10_000 { if !store.revocations.isEmpty { break }; await Task.yield() }
        await store.refresh()
        #expect(store.proposal(selection: .device(remote)) == nil)
        #expect(store.revocations.first?.command == command)
    }

    @Test("a page that finishes after refresh cannot overwrite the refreshed snapshot")
    func stalePageCannotOverwriteRefresh() async throws {
        let initial = try device("00000000-0000-0000-0000-000000000621", name: "Initial")
        let stale = try device("00000000-0000-0000-0000-000000000622", name: "Stale")
        let refreshed = try device("00000000-0000-0000-0000-000000000623", name: "Refreshed")
        let manager = RacingDeviceSessionStoreManager(
            initial: .init(sessions: [initial], nextCursor: "old-cursor"),
            refreshed: .init(sessions: [refreshed], nextCursor: "new-cursor"),
            stalePage: .init(sessions: [stale], nextCursor: "stale-next")
        )
        let store = V2DeviceSessionsStore(manager: manager, operations: try fixtureOperations())

        await store.refresh()
        let staleLoad = Task { await store.loadMore() }
        await manager.waitUntilStalePageIsRequested()
        await store.refresh()
        await manager.finishStalePage()
        await staleLoad.value

        #expect(store.sessions.map(\.deviceID) == [refreshed.deviceID])
        #expect(store.nextCursor == "new-cursor")
        #expect(!store.isLoadingMore)
    }

    @Test("pagination deduplicates identities within the returned page")
    func pageIdentityIsStable() async throws {
        let initial = try device("00000000-0000-0000-0000-000000000631", name: "Initial")
        let next = try device("00000000-0000-0000-0000-000000000632", name: "Next")
        let manager = PagedDeviceSessionStoreManager(
            first: .init(sessions: [initial], nextCursor: "next"),
            next: .init(sessions: [next, next], nextCursor: nil)
        )
        let store = V2DeviceSessionsStore(manager: manager, operations: try fixtureOperations())

        await store.refresh()
        await store.loadMore()

        #expect(store.sessions.map(\.deviceID) == [initial.deviceID, next.deviceID])
    }

    @Test("refresh failure retains the last confirmed snapshot, including an empty one", arguments: [false, true])
    func failedRefreshRetainsSnapshot(empty: Bool) async throws {
        let values = empty ? [] : [try device(UUID().uuidString, name: "Saved")]
        let manager = FailingRefreshDeviceManager(sessions: values)
        let store = V2DeviceSessionsStore(manager: manager, operations: try fixtureOperations())
        await store.refresh()
        await store.refresh()
        #expect(store.state == .loaded)
        #expect(store.sessions == values)
        #expect(store.feedback != nil)
    }

    @Test("a stale pagination error cannot replace newer successful feedback")
    func stalePageFailureCannotOverwriteRefresh() async throws {
        let original = try device(UUID().uuidString, name: "Original")
        let fresh = try device(UUID().uuidString, name: "Fresh")
        let manager = RacingDeviceSessionStoreManager(initial: .init(sessions: [original], nextCursor: "old"),
            refreshed: .init(sessions: [fresh], nextCursor: "new"), stalePage: .init(sessions: [], nextCursor: nil),
            staleError: URLError(.networkConnectionLost))
        let store = V2DeviceSessionsStore(manager: manager, operations: try fixtureOperations())
        await store.refresh()
        let page = Task { await store.loadMore() }
        await manager.waitUntilStalePageIsRequested()
        await store.refresh()
        await manager.finishStalePage()
        await page.value
        #expect(store.sessions == [fresh])
        #expect(store.feedback == nil)
        #expect(store.nextCursor == "new")
    }

    @Test("a read started before revocation cannot resurrect removed devices", arguments: [false, true])
    func confirmedRevocationFencesEarlierReads(all: Bool) async throws {
        let remote = try device(UUID().uuidString, name: "Revoked")
        let manager = PausedRefreshDeviceManager(sessions: [remote])
        let operations = try fixtureOperations(targets: [remote.deviceID])
        let store = V2DeviceSessionsStore(manager: manager, operations: operations)
        await store.refresh()
        let command = try #require(store.proposal(selection: all ? .allObservedOthers : .device(remote.deviceID)))
        await store.confirm(command)
        let observer = Task { await store.observeRevocations() }; defer { observer.cancel() }
        let stale = Task { await store.refresh() }
        await manager.waitForRead()
        let worker = Task { try await operations.run() }; defer { worker.cancel() }
        for _ in 0..<10_000 { if store.revocations.first?.receipt != nil { break }; await Task.yield() }
        await manager.releaseRead(); await stale.value
        #expect(store.sessions.isEmpty)
        #expect(store.state == .loaded)
    }

    @Test("closed device page ignores a late read failure and cannot restore management")
    func closedPageRejectsLateFeedback() async throws {
        let remote = try device(UUID().uuidString, name: "Original")
        let manager = RacingDeviceSessionStoreManager(initial: .init(sessions: [remote], nextCursor: "old"),
            refreshed: .init(sessions: [remote], nextCursor: nil), stalePage: .init(sessions: [], nextCursor: nil),
            staleError: URLError(.networkConnectionLost))
        let store = V2DeviceSessionsStore(manager: manager, operations: try fixtureOperations(targets: [remote.deviceID]))
        await store.refresh()
        #expect(store.canManageSessions)
        let page = Task { await store.loadMore() }
        await manager.waitUntilStalePageIsRequested()
        await store.close()
        await manager.finishStalePage()
        await page.value
        await store.refresh()
        await store.resumeRevocation(UUID())
        #expect(store.feedback == nil && store.sessions.isEmpty && store.revocations.isEmpty)
        #expect(!store.canManageSessions && !store.isMutating && !store.isLoadingMore)
        #expect(store.state == .failed && store.nextCursor == nil)
        #expect(store.proposal(selection: .device(remote.deviceID)) == nil)
    }

    private func fixtureOperations(targets: [DeviceID] = [], current: DeviceID = .init(uuid: UUID())) throws -> V2RemoteDeviceRevocationService {
        let actor = UserID(uuid: UUID()), now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let baseline = try V2RemoteDeviceRevocationBaseline(id: UUID(), actorUserID: actor, currentDeviceID: current,
            targetDeviceIDs: targets.sorted { $0.rawValue < $1.rawValue }, issuedAtMilliseconds: now, expiresAtMilliseconds: now + 120_000)
        return V2RemoteDeviceRevocationService(accountID: actor, currentDeviceID: current,
            storage: DeviceRevocationFixtureMetadata(), client: DeviceRevocationFixtureClient(value: baseline))
    }

    private func device(_ id: String, name: String) throws -> V2ClientDeviceSession {
        .init(
            deviceID: try DeviceID(id),
            deviceName: name,
            platform: "iOS",
            createdAt: .distantPast,
            lastActiveAt: .distantPast,
            isCurrentDevice: false
        )
    }
}

private actor DeviceSessionStoreManager: V2ClientDeviceSessionManaging {
    struct RevokeCall: Sendable { let deviceID: DeviceID; let operationID: UUID }
    let storedSessions: [V2ClientDeviceSession]
    let revokeError: V2ClientDeviceSessionError?
    private var recorded: RevokeCall?
    init(sessions: [V2ClientDeviceSession], revokeError: V2ClientDeviceSessionError? = nil) {
        storedSessions = sessions; self.revokeError = revokeError
    }
    func list(cursor _: String?, pageSize _: Int) -> V2ClientDeviceSessionPage {
        .init(sessions: storedSessions, nextCursor: nil)
    }



}

private actor PagedDeviceSessionStoreManager: V2ClientDeviceSessionManaging {
    let first: V2ClientDeviceSessionPage
    let next: V2ClientDeviceSessionPage

    init(first: V2ClientDeviceSessionPage, next: V2ClientDeviceSessionPage) {
        self.first = first
        self.next = next
    }

    func list(cursor: String?, pageSize _: Int) -> V2ClientDeviceSessionPage {
        cursor == nil ? first : next
    }



}

private actor RacingDeviceSessionStoreManager: V2ClientDeviceSessionManaging {
    let initial: V2ClientDeviceSessionPage
    let refreshed: V2ClientDeviceSessionPage
    let stalePage: V2ClientDeviceSessionPage
    private var firstPageCount = 0
    private var stalePageContinuation: CheckedContinuation<V2ClientDeviceSessionPage, any Error>?
    private let staleError: (any Error)?
    private var staleRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        initial: V2ClientDeviceSessionPage,
        refreshed: V2ClientDeviceSessionPage,
        stalePage: V2ClientDeviceSessionPage,
        staleError: (any Error)? = nil
    ) {
        self.initial = initial
        self.refreshed = refreshed
        self.stalePage = stalePage
        self.staleError = staleError
    }

    func list(cursor: String?, pageSize _: Int) async throws -> V2ClientDeviceSessionPage {
        if cursor == nil {
            firstPageCount += 1
            return firstPageCount == 1 ? initial : refreshed
        }
        return try await withCheckedThrowingContinuation { continuation in
            stalePageContinuation = continuation
            let waiters = staleRequestWaiters
            staleRequestWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilStalePageIsRequested() async {
        guard stalePageContinuation == nil else { return }
        await withCheckedContinuation { staleRequestWaiters.append($0) }
    }

    func finishStalePage() {
        if let staleError { stalePageContinuation?.resume(throwing: staleError) }
        else { stalePageContinuation?.resume(returning: stalePage) }
        stalePageContinuation = nil
    }



}

private actor FailingRefreshDeviceManager: V2ClientDeviceSessionManaging {
    let sessions: [V2ClientDeviceSession]
    private var reads = 0
    init(sessions: [V2ClientDeviceSession]) { self.sessions = sessions }
    func list(cursor: String?, pageSize: Int) throws -> V2ClientDeviceSessionPage {
        reads += 1
        if reads > 1 { throw URLError(.notConnectedToInternet) }
        return .init(sessions: sessions, nextCursor: nil)
    }


}

private actor PausedRefreshDeviceManager: V2ClientDeviceSessionManaging {
    let sessions: [V2ClientDeviceSession]
    private var reads = 0
    private var pending: CheckedContinuation<V2ClientDeviceSessionPage, Never>?
    private var requested: CheckedContinuation<Void, Never>?
    init(sessions: [V2ClientDeviceSession]) { self.sessions = sessions }
    func list(cursor: String?, pageSize: Int) async -> V2ClientDeviceSessionPage {
        reads += 1
        if reads == 1 { return .init(sessions: sessions, nextCursor: "older") }
        return await withCheckedContinuation { continuation in
            pending = continuation
            requested?.resume(); requested = nil
        }
    }
    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { requested = $0 }
    }
    func releaseRead() { pending?.resume(returning: .init(sessions: sessions, nextCursor: "stale")); pending = nil }


}

private final class DeviceRevocationFixtureMetadata: V2RemoteDeviceRevocationMetadataStoring, @unchecked Sendable {
    private let lock = NSLock(); private var data: Data?
    func read() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ data: Data) { lock.lock(); defer { lock.unlock() }; self.data = data }
}
private struct DeviceRevocationFixtureClient: V2RemoteDeviceRevocationClient {
    let value: V2RemoteDeviceRevocationBaseline
    func baseline() -> V2RemoteDeviceRevocationBaseline { value }
    func submit(_ command: V2RemoteDeviceRevocationCommand) throws -> V2RemoteDeviceRevocationResult {
        .receipt(try .init(command: command, outcome: .revoked, resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000)))
    }
    func recover(_ command: V2RemoteDeviceRevocationCommand, action: V2RemoteDeviceRevocationRecoveryRequest.Action) throws -> V2RemoteDeviceRevocationResult {
        .receipt(try .init(command: command, outcome: .closed, resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000)))
    }
}
