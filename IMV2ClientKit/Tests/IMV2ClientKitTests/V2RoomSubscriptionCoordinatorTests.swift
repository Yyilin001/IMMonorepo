import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Runtime room subscription intents", .timeLimit(.minutes(1)))
struct V2RoomSubscriptionCoordinatorTests {
    @Test("account events are consumed without acquiring a foreground room")
    func accountDeliveryWithoutRoomIntent() async throws {
        let wire = SubscriptionWire()
        let received = AsyncStream<V2GroupEventAvailabilityHint>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let owner = V2RoomSubscriptionCoordinator(subscriptions: wire, activity: wire,
            groupEvents: wire, activityEvents: wire, isAuthorized: { _ in true }, roomCursor: { _ in 0 },
            receiveAccountEvent: { hint in received.continuation.yield(hint) })
        let run = Task { try await owner.run(connectionID: UUID()) }
        let room = RoomID(uuid: UUID())
        await wire.emitGroup(room: room, watermark: 1)
        var iterator = received.stream.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.roomID == room)
        #expect(await wire.count("subscribe-room") == 0)
        run.cancel()
        _ = await run.result
        received.continuation.finish()
    }

    @Test("installation has a fixed baseline and later hints do not reinstall it")
    func installedBaselineSurvivesHints() async throws {
        let wire = SubscriptionWire()
        let room = try RoomID("baseline-room")
        let cursor = SubscriptionCommittedCursor()
        let owner = V2RoomSubscriptionCoordinator(subscriptions: wire, activity: wire,
            groupEvents: wire, activityEvents: wire, isAuthorized: { _ in true },
            roomCursor: { _ in await cursor.read() }, retryDelay: .milliseconds(1))
        let lease = try await owner.acquire(roomID: room, channels: [.roomEvents])
        let run = Task { try await owner.run(connectionID: UUID()) }
        defer { run.cancel() }
        var snapshots = lease.updates.makeAsyncIterator()
        let installed = try await next(&snapshots) { $0.state == .subscribed }
        #expect(installed.baselineHead == 4)
        #expect(installed.appliedThrough == 3)
        #expect(!installed.isCaughtUp)
        await wire.emitGroup(room: room, watermark: 9)
        let dirty = try await next(&snapshots) { $0.wake?.highWatermark == 9 }
        #expect(dirty.baselineHead == installed.baselineHead)
        #expect(dirty.recoveryID == installed.recoveryID)
        #expect(dirty.state == .subscribed)
        #expect(await wire.count("subscribe-room") == 1)
        await cursor.commit(4)
        await owner.requestReconciliation()
        let caughtUp = try await next(&snapshots) { $0.isCaughtUp }
        #expect(caughtUp.baselineHead == 4)
        #expect(caughtUp.wake?.highWatermark == 9)
        #expect(await wire.count("subscribe-room") == 1)
        await owner.release(roomID: room, consumerID: lease.id)
        run.cancel()
        _ = await run.result
    }

    @Test("periodic activity refresh preserves the installed room recovery identity")
    func activityRefreshDoesNotScheduleHistoryPull() async throws {
        let wire = SubscriptionWire(), room = try RoomID("activity-refresh-room")
        let ticks = SubscriptionRefreshCounter()
        let owner = V2RoomSubscriptionCoordinator(subscriptions: wire, activity: wire,
            groupEvents: wire, activityEvents: wire, isAuthorized: { _ in await ticks.advance(); return true },
            roomCursor: { _ in 3 }, refreshInterval: .milliseconds(5))
        let lease = try await owner.acquire(roomID: room, channels: [.roomEvents])
        let run = Task { try await owner.run(connectionID: UUID()) }
        defer { run.cancel() }
        var snapshots = lease.updates.makeAsyncIterator()
        let installed = try await next(&snapshots) { $0.state == .subscribed }
        let identity = try #require(installed.recoveryID)
        let deadline = ContinuousClock.now + .seconds(3)
        while await ticks.count < 5 {
            guard ContinuousClock.now < deadline else { throw V2TLSFrameConnectionError.requestTimedOut }
            await Task.yield()
        }
        // Unchanged snapshots are intentionally deduplicated. A later real
        // watermark exposes the identity retained across the observed ticks.
        await wire.emitGroup(room: room, watermark: 9)
        let refreshed = try await next(&snapshots) { $0.wake?.highWatermark == 9 }
        #expect(refreshed.recoveryID == identity)
        #expect(refreshed.baselineHead == installed.baselineHead)
        #expect(await wire.count("subscribe-room") == 1)
        await owner.release(roomID: room, consumerID: lease.id)
        run.cancel(); _ = await run.result
    }

    @Test("two scenes share subscriptions and only the final token unsubscribes")
    func scenesShareWireSubscriptions() async throws {
        let wire = SubscriptionWire()
        let room = try RoomID("shared-room")
        let owner = makeOwner(wire)
        let first = try await owner.acquire(roomID: room, channels: [.roomEvents, .typing, .presence])
        let second = try await owner.acquire(roomID: room, channels: [.roomEvents, .typing, .presence])
        let generation = UUID()
        let run = Task { try await owner.run(connectionID: generation) }
        var snapshots = second.updates.makeAsyncIterator()
        _ = try await next(&snapshots) { $0.state == .subscribed }
        #expect(await wire.count("subscribe-room") == 1)
        #expect(await wire.count("subscribe-typing") == 1)
        #expect(await wire.count("subscribe-presence") == 1)
        await owner.release(roomID: room, consumerID: first.id)
        await wire.emitGroup(room: room, watermark: 7)
        _ = try await next(&snapshots) { $0.wake?.highWatermark == 7 }
        #expect(await wire.count("unsubscribe-room") == 0)
        await owner.release(roomID: room, consumerID: second.id)
        await wire.waitFor("unsubscribe-room", count: 1)
        run.cancel()
        _ = await run.result
        #expect(await wire.count("unsubscribe-room") == 1)
        #expect(await wire.generations().allSatisfy { $0 == generation })
    }

    @Test("reconnect retains the room intent and resets transient leases", arguments: [false, true])
    func reconnectReconcilesWithoutClosingScene(overlap: Bool) async throws {
        let wire = SubscriptionWire()
        let room = try RoomID("open-room")
        let owner = makeOwner(wire)
        let lease = try await owner.acquire(roomID: room, channels: [.roomEvents, .typing, .presence])
        let oldGeneration = UUID()
        let firstRun = Task { try await owner.run(connectionID: oldGeneration) }
        var snapshots = lease.updates.makeAsyncIterator()
        let first = try await next(&snapshots) { $0.state == .subscribed }
        try await wire.emitTyping(room: room)
        _ = try await next(&snapshots) { !$0.typing.isEmpty }
        if !overlap {
            firstRun.cancel()
            _ = await firstRun.result
            let offline = try await next(&snapshots) { $0.state == .offline }
            #expect(offline.baselineHead == nil && offline.appliedThrough == nil && !offline.isCaughtUp)
            #expect(offline.typing.isEmpty && offline.presence == nil && offline.wake == nil)
        }
        let newGeneration = UUID()
        let secondRun = Task { try await owner.run(connectionID: newGeneration) }
        _ = await firstRun.result
        let resumed = try await next(&snapshots) { $0.state == .subscribed && $0.connectionID == newGeneration }
        #expect(resumed.baselineHead == 4 && resumed.appliedThrough == 3 && !resumed.isCaughtUp)
        #expect(resumed.typing.isEmpty)
        #expect(resumed.recoveryID != first.recoveryID)
        #expect(await wire.count("subscribe-room") == 2)
        #expect(await wire.count("subscribe-presence") == 2)
        await owner.release(roomID: room, consumerID: lease.id)
        secondRun.cancel()
        _ = await secondRun.result
    }

    @Test("a failed subscription retries without another hint or another scene")
    func failedSubscribeKeepsIntent() async throws {
        let wire = SubscriptionWire(failFirstRoomSubscription: true)
        let owner = makeOwner(wire)
        let lease = try await owner.acquire(roomID: .init("retry-room"), channels: [.roomEvents])
        let run = Task { try await owner.run(connectionID: UUID()) }
        var snapshots = lease.updates.makeAsyncIterator()
        _ = try await next(&snapshots) { $0.state == .subscribed }
        #expect(await wire.count("subscribe-room") == 2)
        await owner.release(roomID: lease.roomID, consumerID: lease.id)
        run.cancel()
        _ = await run.result
    }

    @Test("authoritative membership loss removes subscriptions while the scene stays open")
    func membershipLossConverges() async throws {
        let authority = SubscriptionAuthority()
        let wire = SubscriptionWire()
        let owner = makeOwner(wire, authority: authority)
        let lease = try await owner.acquire(roomID: .init("revoked-room"), channels: [.roomEvents, .typing])
        let run = Task { try await owner.run(connectionID: UUID()) }
        var snapshots = lease.updates.makeAsyncIterator()
        _ = try await next(&snapshots) { $0.state == .subscribed }
        await authority.set(false)
        await owner.authorityDidChange()
        let revoked = try await next(&snapshots) { $0.state == .revoked }
        #expect(revoked.wake == nil && revoked.typing.isEmpty)
        #expect(await wire.count("unsubscribe-room") == 1)
        #expect(await wire.count("unsubscribe-typing") == 1)
        await authority.set(true)
        await owner.authorityDidChange()
        _ = try await next(&snapshots) { $0.state == .subscribed }
        #expect(await wire.count("subscribe-room") == 2)
        await owner.release(roomID: lease.roomID, consumerID: lease.id)
        run.cancel()
        _ = await run.result
    }

    @Test("releasing an old scene token twice cannot remove its replacement")
    func oldTokenDoesNotRemoveReplacement() async throws {
        let wire = SubscriptionWire()
        let owner = makeOwner(wire)
        let room = try RoomID("replacement-room")
        let old = try await owner.acquire(roomID: room, channels: [.roomEvents])
        let run = Task { try await owner.run(connectionID: UUID()) }
        var oldSnapshots = old.updates.makeAsyncIterator()
        _ = try await next(&oldSnapshots) { $0.state == .subscribed }
        let current = try await owner.acquire(roomID: room, channels: [.roomEvents])
        await owner.release(roomID: room, consumerID: old.id)
        await owner.release(roomID: room, consumerID: old.id)
        var snapshots = current.updates.makeAsyncIterator()
        await wire.emitGroup(room: room, watermark: 9)
        _ = try await next(&snapshots) { $0.wake?.highWatermark == 9 }
        #expect(await wire.count("unsubscribe-room") == 0)
        await owner.release(roomID: room, consumerID: current.id)
        run.cancel()
        _ = await run.result
    }

    @Test("old scene or connection typing renewals never reach the replacement wire")
    func typingRenewalsAreConnectionScoped() async throws {
        let wire = SubscriptionWire()
        let owner = makeOwner(wire)
        let room = try RoomID("outgoing-typing")
        let lease = try await owner.acquire(roomID: room, channels: [.typing])
        let oldID = UUID()
        let firstRun = Task { try await owner.run(connectionID: oldID) }
        var snapshots = lease.updates.makeAsyncIterator()
        _ = try await next(&snapshots) { $0.state == .subscribed }
        try await owner.setTyping(roomID: room, consumerID: lease.id, connectionID: oldID, isTyping: true)
        let newID = UUID()
        let secondRun = Task { try await owner.run(connectionID: newID) }
        _ = await firstRun.result
        _ = try await next(&snapshots) { $0.state == .subscribed && $0.connectionID == newID }
        await #expect(throws: CancellationError.self) {
            try await owner.setTyping(roomID: room, consumerID: lease.id, connectionID: oldID, isTyping: true)
        }
        await #expect(throws: CancellationError.self) {
            try await owner.setTyping(roomID: room, consumerID: UUID(), connectionID: newID, isTyping: false)
        }
        #expect(await wire.count("set-typing") == 1)
        try await owner.setTyping(roomID: room, consumerID: lease.id, connectionID: newID, isTyping: true)
        #expect(await wire.count("set-typing") == 2)
        #expect(await wire.generations().last == newID)
        await owner.release(roomID: room, consumerID: lease.id)
        secondRun.cancel()
        _ = await secondRun.result
    }

    @Test("a retained metadata snapshot does not suppress subsequent live payloads")
    func retainedMetadataPreservesFuturePayload() async throws {
        let wire = SubscriptionWire()
        let owner = makeOwner(wire)
        let room = try RoomID("payload-room")
        let lease = try await owner.acquire(roomID: room, channels: [.roomEvents])
        let run = Task { try await owner.run(connectionID: UUID()) }
        var snapshots = lease.updates.makeAsyncIterator()
        _ = try await next(&snapshots) { $0.state == .subscribed }
        let event = try V2ClientGroupEvent(sourceEventID: try .init(UUID().uuidString), roomSequence: 8, projectionKind: "message", payload: Data([1]))
        await wire.emitGroup(room: room, watermark: 8, events: [event])
        let payload = try await next(&snapshots) { $0.wake?.highWatermark == 8 }
        #expect(payload.wake?.liveEvents == [event])
        await wire.emitGroup(room: room, watermark: 9)
        _ = try await next(&snapshots) { $0.wake?.highWatermark == 9 }
        let later = try V2ClientGroupEvent(sourceEventID: try .init(UUID().uuidString), roomSequence: 10, projectionKind: "message", payload: Data([2]))
        await wire.emitGroup(room: room, watermark: 10, events: [later])
        let resumed = try await next(&snapshots) { $0.wake?.highWatermark == 10 }
        #expect(resumed.wake?.liveEvents == [later])
        await owner.release(roomID: room, consumerID: lease.id)
        run.cancel()
        _ = await run.result
    }

    @Test("closing a scene during a delayed ACK and reconnect cannot unsubscribe its replacement")
    func lateAcknowledgementDuringReplacement() async throws {
        let wire = SubscriptionWire(blockFirstRoomSubscription: true)
        let owner = makeOwner(wire)
        let room = try RoomID("delayed-room")
        let old = try await owner.acquire(roomID: room, channels: [.roomEvents])
        let firstRun = Task { try await owner.run(connectionID: UUID()) }
        await wire.waitFor("subscribe-room", count: 1)
        await owner.release(roomID: room, consumerID: old.id)
        let replacement = try await owner.acquire(roomID: room, channels: [.roomEvents])
        let secondID = UUID()
        let secondRun = Task { try await owner.run(connectionID: secondID) }
        // The wire ignores cancellation until the old reply is released.
        // Reconciliation must still check its generation after that await.
        firstRun.cancel()
        await wire.releaseRoomAcknowledgement()
        _ = await firstRun.result
        var snapshots = replacement.updates.makeAsyncIterator()
        _ = try await next(&snapshots) { $0.state == .subscribed && $0.connectionID == secondID }
        await owner.release(roomID: room, consumerID: old.id)
        #expect(await wire.count("subscribe-room") == 2)
        #expect(await wire.count("unsubscribe-room") == 0)
        await owner.release(roomID: room, consumerID: replacement.id)
        await wire.waitFor("unsubscribe-room", count: 1)
        #expect(await wire.generations().last == secondID)
        secondRun.cancel()
        _ = await secondRun.result
    }

    private func makeOwner(_ wire: SubscriptionWire, authority: SubscriptionAuthority = .init()) -> V2RoomSubscriptionCoordinator {
        .init(subscriptions: wire, activity: wire, groupEvents: wire, activityEvents: wire,
              isAuthorized: { _ in await authority.allowed() }, roomCursor: { _ in 3 }, retryDelay: .milliseconds(1))
    }
    private func next(_ iterator: inout AsyncStream<V2RoomSubscriptionSnapshot>.Iterator, matching: (V2RoomSubscriptionSnapshot) -> Bool) async throws -> V2RoomSubscriptionSnapshot {
        while let snapshot = await iterator.next() { if matching(snapshot) { return snapshot } }
        throw CancellationError()
    }
}

private actor SubscriptionAuthority {
    private var authorized = true
    func allowed() -> Bool { authorized }
    func set(_ value: Bool) { authorized = value }
}

private actor SubscriptionWire: V2ClientGroupEventSubscriptionTransport, V2ClientLiveActivityTransport, V2GroupEventAvailabilityHintSource, V2LiveActivityEventSource {
    private var calls: [(String, UUID?)] = []
    private var observers: [(String, Int, CheckedContinuation<Void, Never>)] = []
    private var groupWaiter: (UUID, CheckedContinuation<V2GroupEventAvailabilityHint, Error>)?
    private var activityWaiter: (UUID, CheckedContinuation<V2LiveActivityEvent, Error>)?
    private var pendingGroups: [V2GroupEventAvailabilityHint] = []
    private var pendingActivities: [V2LiveActivityEvent] = []
    private var failFirstRoomSubscription: Bool
    private let blockFirstRoomSubscription: Bool
    private var roomAcknowledgement: CheckedContinuation<Void, Never>?
    private var acknowledgementReleased = false
    init(failFirstRoomSubscription: Bool = false, blockFirstRoomSubscription: Bool = false) {
        self.failFirstRoomSubscription = failFirstRoomSubscription
        self.blockFirstRoomSubscription = blockFirstRoomSubscription
    }
    func releaseRoomAcknowledgement() {
        acknowledgementReleased = true
        roomAcknowledgement?.resume()
        roomAcknowledgement = nil
    }
    private func record(_ name: String) {
        calls.append((name, V2ConnectionRequestScope.connectionID))
        let ready = observers.filter { $0.0 == name && count(name) >= $0.1 }
        observers.removeAll { $0.0 == name && count(name) >= $0.1 }
        for observer in ready { observer.2.resume() }
    }
    func count(_ name: String) -> Int { calls.filter { $0.0 == name }.count }
    func generations() -> [UUID?] { calls.map(\.1) }
    func waitFor(_ name: String, count expected: Int) async {
        if count(name) >= expected { return }
        await withCheckedContinuation { observers.append((name, expected, $0)) }
    }
    func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64) async throws -> V2ClientGroupEventSubscription {
        record("subscribe-room")
        if blockFirstRoomSubscription, count("subscribe-room") == 1, !acknowledgementReleased {
            await withCheckedContinuation { roomAcknowledgement = $0 }
        }
        #expect(afterRoomSequence == 3)
        if failFirstRoomSubscription { failFirstRoomSubscription = false; throw V2TLSFrameConnectionError.connectionFailed }
        return try .init(roomID: roomID, highWatermark: 4)
    }
    func unsubscribeFromGroupEvents(roomID: RoomID) { record("unsubscribe-room") }
    func subscribeTyping(roomID: RoomID) { record("subscribe-typing") }
    func unsubscribeTyping(roomID: RoomID) { record("unsubscribe-typing") }
    func setTyping(roomID: RoomID, isTyping: Bool) { record("set-typing") }
    func subscribePresence(roomID: RoomID) throws -> V2PresenceState {
        record("subscribe-presence")
        return .init(roomID: roomID, targetUserID: try .init("peer"), isOnline: true, expiresAt: Date().addingTimeInterval(60))
    }
    func unsubscribePresence(roomID: RoomID) { record("unsubscribe-presence") }
    func liveActivityPreferences() throws -> V2LiveActivityPreferences { throw CancellationError() }

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

private actor SubscriptionCommittedCursor {
    private var value: UInt64 = 3
    func read() -> UInt64 { value }
    func commit(_ cursor: UInt64) { value = cursor }
}

private actor SubscriptionRefreshCounter {
    private(set) var count = 0
    func advance() { count += 1 }
}
