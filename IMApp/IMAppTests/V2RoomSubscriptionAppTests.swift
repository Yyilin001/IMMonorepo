import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

actor AppSubscriptionWire: V2ClientGroupEventSubscriptionTransport, V2ClientLiveActivityTransport, V2GroupEventAvailabilityHintSource, V2LiveActivityEventSource {
    private var calls: [String] = []
    private var observers: [(String, Int, CheckedContinuation<Void, Never>)] = []
    private var groupWaiter: (UUID, CheckedContinuation<V2GroupEventAvailabilityHint, Error>)?
    private var activityWaiter: (UUID, CheckedContinuation<V2LiveActivityEvent, Error>)?
    private var pendingGroups: [V2GroupEventAvailabilityHint] = []
    private var pendingActivities: [V2LiveActivityEvent] = []
    private var failFirstRoomSubscription: Bool
    init(failFirstRoomSubscription: Bool = false) { self.failFirstRoomSubscription = failFirstRoomSubscription }
    private func record(_ name: String) {
        calls.append(name)
        let ready = observers.filter { $0.0 == name && count(name) >= $0.1 }
        observers.removeAll { $0.0 == name && count(name) >= $0.1 }
        for observer in ready { observer.2.resume() }
    }
    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }
    func waitFor(_ name: String, count expected: Int) async {
        if count(name) >= expected { return }
        await withCheckedContinuation { observers.append((name, expected, $0)) }
    }
    func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64) throws -> V2ClientGroupEventSubscription {
        record("subscribe-room")
        record("subscribe-room:" + roomID.rawValue)
        if failFirstRoomSubscription { failFirstRoomSubscription = false; throw V2TLSFrameConnectionError.connectionFailed }
        return try .init(roomID: roomID, highWatermark: 4)
    }
    func unsubscribeFromGroupEvents(roomID: RoomID) { record("unsubscribe-room"); record("unsubscribe-room:" + roomID.rawValue) }
    func subscribeTyping(roomID: RoomID) { record("subscribe-typing") }
    func unsubscribeTyping(roomID: RoomID) { record("unsubscribe-typing") }
    func setTyping(roomID: RoomID, isTyping: Bool) { record("set-typing") }
    func subscribePresence(roomID: RoomID) throws -> V2PresenceState {
        record("subscribe-presence")
        return .init(roomID: roomID, targetUserID: try .init("peer"), isOnline: true, expiresAt: Date().addingTimeInterval(60))
    }
    func unsubscribePresence(roomID: RoomID) { record("unsubscribe-presence") }
    func liveActivityPreferences() throws -> V2LiveActivityPreferences { throw CancellationError() }
    func setLiveActivityPreferences(operationID: LiveActivityPreferenceOperationID, allowsOnlinePresence: Bool, allowsTypingIndicators: Bool) throws -> V2LiveActivityPreferences { throw CancellationError() }
    func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        try Task.checkCancellation()
        if !pendingGroups.isEmpty { return pendingGroups.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if groupWaiter != nil { continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer) }
                else { groupWaiter = (id, continuation) }
            }
        }, onCancel: { Task { await self.cancelGroup(id) } })
    }
    func nextLiveActivityEvent() async throws -> V2LiveActivityEvent {
        try Task.checkCancellation()
        if !pendingActivities.isEmpty { return pendingActivities.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if activityWaiter != nil { continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer) }
                else { activityWaiter = (id, continuation) }
            }
        }, onCancel: { Task { await self.cancelActivity(id) } })
    }
    private func cancelGroup(_ id: UUID) { if groupWaiter?.0 == id { groupWaiter?.1.resume(throwing: CancellationError()); groupWaiter = nil } }
    private func cancelActivity(_ id: UUID) { if activityWaiter?.0 == id { activityWaiter?.1.resume(throwing: CancellationError()); activityWaiter = nil } }
    func emitGroup(room: RoomID, watermark: UInt64, events: [V2ClientGroupEvent] = []) {
        let hint = V2GroupEventAvailabilityHint(roomID: room, highWatermark: watermark, liveEvents: events)
        if let waiter = groupWaiter { groupWaiter = nil; waiter.1.resume(returning: hint) }
        else { pendingGroups.append(hint) }
    }
    func emitTyping(room: RoomID) throws {
        let event = V2LiveActivityEvent.typing(.init(roomID: room, userID: try .init("peer"), isTyping: true, expiresAt: Date().addingTimeInterval(60)))
        if let waiter = activityWaiter { activityWaiter = nil; waiter.1.resume(returning: event) }
        else { pendingActivities.append(event) }
    }
}

@Suite("App room subscription ownership", .timeLimit(.minutes(1)))
struct V2RoomSubscriptionAppTests {
    @Test("cancelling one grace waiter keeps both scene leases alive")
    func graceCancellationDoesNotUnsubscribe() async throws {
        let wire = AppSubscriptionWire()
        let owner = makeAppSubscriptionOwner(wire)
        let room = try RoomID("grace-room")
        let base = AppSubscriptionSync()
        let first = V2ScopedActiveRoomSynchronizer(roomID: room, owner: owner, base: base)
        let second = V2ScopedActiveRoomSynchronizer(roomID: room, owner: owner, base: base)
        _ = try await first.subscribe(roomID: room.rawValue)
        _ = try await second.subscribe(roomID: room.rawValue)
        let run = Task { try await owner.run(connectionID: UUID()) }
        _ = try await first.nextWake()
        _ = try await second.nextWake()
        let waiting = Task { try await first.nextWake() }
        try await Task.sleep(for: .milliseconds(10))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        let event = try appSubscriptionEvent(8)
        await wire.emitGroup(room: room, watermark: 8, events: [event])
        let wake = try await first.nextWake()
        #expect(wake.liveEvents == [event])
        #expect(try await first.applyLiveEvent(wake))
        await first.close()
        await wire.emitGroup(room: room, watermark: 9)
        var survivorWake = try await second.nextWake()
        while survivorWake.highWatermark != 9 { survivorWake = try await second.nextWake() }
        #expect(await wire.count("unsubscribe-room") == 0)
        await second.close()
        await wire.waitFor("unsubscribe-room", count: 1)
        run.cancel()
        _ = await run.result
    }

    @Test("an open adapter survives reconnect and rejects the previous generation payload")
    func reconnectWithoutRecreatingAdapter() async throws {
        let wire = AppSubscriptionWire()
        let owner = makeAppSubscriptionOwner(wire)
        let room = try RoomID("reconnect-room")
        let base = AppSubscriptionSync()
        let adapter = V2ScopedActiveRoomSynchronizer(roomID: room, owner: owner, base: base)
        _ = try await adapter.subscribe(roomID: room.rawValue)
        let oldID = UUID()
        let firstRun = Task { try await owner.run(connectionID: oldID) }
        _ = try await adapter.nextWake()
        await wire.emitGroup(room: room, watermark: 8, events: [try appSubscriptionEvent(8)])
        let oldWake = try await adapter.nextWake()
        let newID = UUID()
        let secondRun = Task { try await owner.run(connectionID: newID) }
        _ = await firstRun.result
        let recovery = try await adapter.nextWake()
        #expect(recovery.connectionID == newID)
        #expect(recovery.liveEvents.isEmpty)
        #expect(try await !adapter.applyLiveEvent(oldWake))
        #expect(await wire.count("subscribe-room") == 2)
        await adapter.close()
        secondRun.cancel()
        _ = await secondRun.result
    }

    @Test("membership revocation pauses an open adapter and rejoining restores it")
    func rejoinRetainsSceneIntent() async throws {
        let wire = AppSubscriptionWire()
        let authority = AppSubscriptionAuthority()
        let owner = V2RoomSubscriptionCoordinator(subscriptions: wire, activity: wire, groupEvents: wire, activityEvents: wire,
                                                   isAuthorized: { _ in await authority.allowed }, roomCursor: { _ in 3 })
        let room = try RoomID("rejoin-room")
        let base = AppSubscriptionSync()
        let adapter = V2ScopedActiveRoomSynchronizer(roomID: room, owner: owner, base: base)
        _ = try await adapter.subscribe(roomID: room.rawValue)
        let run = Task { try await owner.run(connectionID: UUID()) }
        _ = try await adapter.nextWake()
        await authority.set(false)
        await owner.authorityDidChange()
        _ = try await adapter.nextWake()
        #expect(try await adapter.synchronizeOnePage(roomID: room.rawValue) == .synchronized(appliedEventCount: 0, hasMore: false))
        #expect(await base.pulls() == 0)
        await authority.set(true)
        await owner.authorityDidChange()
        _ = try await adapter.nextWake()
        _ = try await adapter.synchronizeOnePage(roomID: room.rawValue)
        #expect(await base.pulls() == 1)
        #expect(await wire.count("subscribe-room") == 2)
        await adapter.close()
        run.cancel()
        _ = await run.result
    }

    @Test("periodic recovery strips an already-applied acceleration payload")
    func periodicRecoveryStillPulls() async throws {
        let wire = AppSubscriptionWire()
        let owner = makeAppSubscriptionOwner(wire, refreshInterval: .milliseconds(150))
        let room = try RoomID("periodic-room")
        let adapter = V2ScopedActiveRoomSynchronizer(roomID: room, owner: owner, base: AppSubscriptionSync())
        _ = try await adapter.subscribe(roomID: room.rawValue)
        let run = Task { try await owner.run(connectionID: UUID()) }
        _ = try await adapter.nextWake()
        await wire.emitGroup(room: room, watermark: 8, events: [try appSubscriptionEvent(8)])
        var live = try await adapter.nextWake()
        while live.liveEvents.isEmpty { live = try await adapter.nextWake() }
        #expect(try await adapter.applyLiveEvent(live))
        let recovery = try await adapter.nextWake()
        #expect(recovery.highWatermark == 8 && recovery.liveEvents.isEmpty)
        await adapter.close()
        run.cancel()
        _ = await run.result
    }
}

func makeAppSubscriptionOwner(_ wire: AppSubscriptionWire, refreshInterval: Duration = .seconds(30)) -> V2RoomSubscriptionCoordinator {
    .init(subscriptions: wire, activity: wire, groupEvents: wire, activityEvents: wire,
          isAuthorized: { _ in true }, roomCursor: { _ in 3 }, retryDelay: .milliseconds(1), refreshInterval: refreshInterval)
}

func appSubscriptionEvent(_ sequence: UInt64) throws -> V2ClientGroupEvent {
    try .init(sourceEventID: try .init(UUID().uuidString), roomSequence: sequence, projectionKind: "message", payload: Data([1]))
}

private actor AppSubscriptionAuthority {
    private(set) var allowed = true
    func set(_ value: Bool) { allowed = value }
}

private actor AppSubscriptionSync: V2ActiveHybridGroupSynchronizing {
    private var count = 0
    func pulls() -> Int { count }
    func subscribe(roomID: String) -> V2ActiveHybridGroupSubscriptionOutcome { .subscribed(highWatermark: 0) }
    func synchronizeOnePage(roomID: String) -> V2ActiveHybridGroupSyncOutcome { count += 1; return .synchronized(appliedEventCount: 0, hasMore: false) }
    func applyLiveEvent(_ wake: V2ActiveHybridGroupWake) -> Bool { !wake.liveEvents.isEmpty }
    func nextWake() async throws -> V2ActiveHybridGroupWake { throw CancellationError() }
    func unsubscribe(roomID: String) {}
}
