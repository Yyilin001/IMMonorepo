import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2DeviceSessionsStoreTests {
    @Test("remote revoke removes only the selected non-current session")
    func revokesRemoteSession() async throws {
        let current = try DeviceID("00000000-0000-0000-0000-000000000601")
        let remote = try DeviceID("00000000-0000-0000-0000-000000000602")
        let manager = DeviceSessionStoreManager(sessions: [
            .init(deviceID: current, deviceName: "iPhone", platform: "iPhone", createdAt: .distantPast, lastActiveAt: .distantFuture, isCurrentDevice: true),
            .init(deviceID: remote, deviceName: "iPad", platform: "iPad", createdAt: .distantPast, lastActiveAt: .distantPast, isCurrentDevice: false)
        ])
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
        let store = V2DeviceSessionsStore(manager: manager, makeUUID: { operationID })

        await store.refresh()
        await store.revoke(try #require(store.sessions.first { $0.deviceID == remote }))

        #expect(store.sessions.map(\.deviceID) == [current])
        #expect(store.feedback == "已退出该设备。")
        let call = try #require(await manager.revokeCall())
        #expect(call.deviceID == remote)
        #expect(call.operationID == operationID)
    }

    @Test("already-removed device is treated as successful revoke")
    func unavailableSessionIsIdempotentForUI() async throws {
        let remote = try DeviceID("00000000-0000-0000-0000-000000000612")
        let manager = DeviceSessionStoreManager(sessions: [
            .init(deviceID: remote, deviceName: "iPad", platform: "iPad", createdAt: .distantPast, lastActiveAt: .distantPast, isCurrentDevice: false)
        ], revokeError: .sessionUnavailable)
        let store = V2DeviceSessionsStore(manager: manager)
        await store.refresh()
        await store.revoke(try #require(store.sessions.first))
        #expect(store.sessions.isEmpty)
        #expect(store.feedback == "该设备已退出。")
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
        let store = V2DeviceSessionsStore(manager: manager)

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
        let store = V2DeviceSessionsStore(manager: manager)

        await store.refresh()
        await store.loadMore()

        #expect(store.sessions.map(\.deviceID) == [initial.deviceID, next.deviceID])
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
    func revoke(deviceID: DeviceID, operationID: UUID) throws {
        if let revokeError { throw revokeError }
        recorded = .init(deviceID: deviceID, operationID: operationID)
    }
    func revokeOtherDevices(operationID _: UUID) {}
    func revokeCall() -> RevokeCall? { recorded }
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

    func revoke(deviceID _: DeviceID, operationID _: UUID) {}
    func revokeOtherDevices(operationID _: UUID) {}
}

private actor RacingDeviceSessionStoreManager: V2ClientDeviceSessionManaging {
    let initial: V2ClientDeviceSessionPage
    let refreshed: V2ClientDeviceSessionPage
    let stalePage: V2ClientDeviceSessionPage
    private var firstPageCount = 0
    private var stalePageContinuation: CheckedContinuation<V2ClientDeviceSessionPage, Never>?
    private var staleRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        initial: V2ClientDeviceSessionPage,
        refreshed: V2ClientDeviceSessionPage,
        stalePage: V2ClientDeviceSessionPage
    ) {
        self.initial = initial
        self.refreshed = refreshed
        self.stalePage = stalePage
    }

    func list(cursor: String?, pageSize _: Int) async -> V2ClientDeviceSessionPage {
        if cursor == nil {
            firstPageCount += 1
            return firstPageCount == 1 ? initial : refreshed
        }
        return await withCheckedContinuation { continuation in
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
        stalePageContinuation?.resume(returning: stalePage)
        stalePageContinuation = nil
    }

    func revoke(deviceID _: DeviceID, operationID _: UUID) {}
    func revokeOtherDevices(operationID _: UUID) {}
}
