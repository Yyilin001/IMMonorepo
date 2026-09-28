import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Foreground author page and real room subscription ownership", .timeLimit(.minutes(1)))
struct V2AuthorPresentationPageCoordinatorTests {
    @Test("cancelled pages retain their cleanup until the exact stop completes and preserve another room consumer")
    func stopDrainsBeforeClose() async throws {
        let f = Fixture(), activation = await f.profiles.activate()
        await f.wire.setHoldStop(true)
        let other = try await f.rooms.acquire(roomID: f.room, channels: [.roomEvents])
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(roomID: f.room, activation: activation) }
        try await wait { await f.wire.receiving }
        page.cancel()
        try await wait { await f.wire.stops.count == 1 }
        let completion = Completion()
        let close1 = Task { await f.pages.close(); await completion.finish() }
        let close2 = Task { await f.pages.close(); await completion.finish() }
        try await wait { await f.pages.diagnostics().closed }
        #expect(await f.wire.current == nil)
        #expect(await completion.count == 0)
        #expect(await f.wire.unsubscribedRooms == 0)
        await f.wire.releaseStop()
        _ = await page.result; await close1.value; await close2.value
        #expect(await completion.count == 2)
        #expect(await f.wire.stops == f.wire.ended)
        #expect(await f.wire.unsubscribedRooms == 0)
        await f.rooms.release(roomID: f.room, consumerID: other.id)
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }

    @Test("ordinary ACK precedes author access; delta satisfies HTTP and renewal keeps the live page grant")
    func renewalAndIngest() async throws {
        let f = Fixture(lifetime: .milliseconds(180), holdOrdinary: true)
        let activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let page = Task { try await f.pages.run(roomID: f.room, activation: activation) }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        try await wait { await f.wire.ordinaryCalls == 1 }
        #expect(await f.wire.views.isEmpty)
        await f.wire.releaseOrdinary()
        try await wait { await f.wire.subscribed.count == 1 }
        try await f.wire.emit(f.value(revision: 1))
        #expect(try await demand.value?.view.revision.rawValue == 1)
        try await wait { await f.wire.subscribed.count >= 2 }
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation)?.view.revision.rawValue == 1)
        let views = await f.wire.views
        #expect(views[0].viewID != views[1].viewID)
        #expect(await f.wire.maximumReceivers == 1)
        #expect(await f.wire.cursors.allSatisfy { $0 == 7 })
        page.cancel(); _ = await page.result
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("page replacement and concurrent close retain a non-cooperative subscription until its actual ACK")
    func replacementDrainsActualSubscription() async throws {
        let f = Fixture(holdAuthor: true)
        let first = await f.profiles.activate(), second = await f.profiles.activate()
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let a = Task { try await f.pages.run(roomID: f.room, activation: first) }
        try await wait { await f.wire.subscribed.count == 1 }
        let b = Task { try await f.pages.run(roomID: f.room, activation: second) }
        try await wait { await f.wire.cancelledAuthorRequests == 1 }
        #expect(await f.wire.views.count == 1)
        let completion = Completion()
        let close1 = Task { await f.pages.close(); await completion.finish() }
        let close2 = Task { await f.pages.close(); await completion.finish() }
        try await wait { await f.pages.diagnostics().closed }
        await #expect(throws: (any Error).self) { try await f.pages.run(roomID: f.room, activation: second) }
        #expect(await completion.count == 0)
        await f.wire.releaseAuthor()
        _ = await a.result; _ = await b.result
        await close1.value; await close2.value
        #expect(await completion.count == 2)
        #expect(await f.wire.views.count == 1)
        #expect(await f.wire.ended.count == 1)
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }

    @Test("reconnect and membership revocation end the old nonce while keeping the visible room intent")
    func reconnectAndRevocation() async throws {
        let f = Fixture(), activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let page = Task { try await f.pages.run(roomID: f.room, activation: activation) }
        let firstID = UUID(), secondID = UUID()
        let first = Task { try await f.rooms.run(connectionID: firstID) }
        try await wait { await f.wire.subscribed.count == 1 }
        try await f.wire.emit(f.value(revision: 1)); _ = try await demand.value
        first.cancel(); _ = await first.result
        try await wait { await f.wire.ended.count == 1 }
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil }
        let second = Task { try await f.rooms.run(connectionID: secondID) }
        try await wait { await f.wire.subscribed.count == 2 }
        try await f.wire.emit(f.value(revision: 2))
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation)?.view.revision.rawValue == 2 }
        #expect(await f.wire.generations == [firstID, secondID])
        await f.wire.setAuthorized(false); await f.rooms.authorityDidChange()
        try await wait { await f.wire.ended.count == 2 }
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil }
        await f.wire.setAuthorized(true); await f.rooms.authorityDidChange()
        try await wait { await f.wire.subscribed.count == 3 }
        page.cancel(); _ = await page.result
        second.cancel(); _ = await second.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("a denied supplement revokes the shared room intent until authority is reconsidered")
    func deniedSubscribe() async throws {
        let f = Fixture(denyAuthor: true), activation = await f.profiles.activate()
        let otherScene = try await f.rooms.acquire(roomID: f.room, channels: [.roomEvents])
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(roomID: f.room, activation: activation) }
        var snapshots = otherScene.updates.makeAsyncIterator()
        var revoked = false
        while let value = await snapshots.next() { if value.state == .revoked { revoked = true; break } }
        #expect(revoked)
        #expect(await f.wire.views.count == 1)
        try await wait { await f.wire.ended.count == 1 }
        await f.wire.setDenyAuthor(false); await f.rooms.authorityDidChange()
        try await wait { await f.wire.subscribed.count == 2 }
        page.cancel(); _ = await page.result
        await f.rooms.release(roomID: f.room, consumerID: otherScene.id)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("an unnegotiated connection is tried once and retried only after a new connection")
    func noCapability() async throws {
        let f = Fixture(unsupported: true), activation = await f.profiles.activate()
        let page = Task { try await f.pages.run(roomID: f.room, activation: activation) }
        let first = Task { try await f.rooms.run(connectionID: UUID()) }
        try await wait { await f.wire.begins == 1 }
        for _ in 0..<4 { await f.rooms.requestReconciliation() }
        #expect(await f.wire.begins == 1)
        let next = Task { try await f.rooms.run(connectionID: UUID()) }
        _ = await first.result
        try await wait { await f.wire.begins == 2 }
        #expect(await f.wire.subscribed.isEmpty)
        page.cancel(); _ = await page.result
        next.cancel(); _ = await next.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("a non-cooperative receiver holds close and cannot publish its delayed delta after cancellation")
    func delayedReceive() async throws {
        let f = Fixture(holdReceive: true), activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(roomID: f.room, activation: activation) }
        try await wait { await f.wire.receiving }
        let completion = Completion()
        let closing = Task { await f.pages.close(); await completion.finish() }
        try await wait { await f.wire.cancelledReceivers == 1 }
        #expect(await completion.count == 0)
        try await f.wire.emit(f.value(revision: 4))
        await closing.value; _ = await page.result
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil)
        await f.profiles.deactivate(activation); _ = await demand.result
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }

    @Test("a cancelled page's late retry-after delays its replacement on the same account")
    func lateThrottle() async throws {
        let f = Fixture(holdAuthor: true)
        let a = await f.profiles.activate(), b = await f.profiles.activate()
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let first = Task { try await f.pages.run(roomID: f.room, activation: a) }
        try await wait { await f.wire.subscribed.count == 1 }
        let replacement = Task { try await f.pages.run(roomID: f.room, activation: b) }
        try await wait { await f.wire.cancelledAuthorRequests == 1 }
        await f.wire.failNextAuthor(.server(code: "RATE_LIMITED", retryable: true, retryAfterSeconds: 1, currentRevision: nil))
        await f.wire.releaseAuthor()
        _ = await first.result
        try await wait { await f.wire.subscribed.count == 2 }
        let failureAt = try #require(await f.wire.failureAt), views = await f.wire.views
        #expect(views[1].started >= failureAt + .seconds(1))
        replacement.cancel(); _ = await replacement.result
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("close revokes visible grants before a non-cooperative receiver finishes")
    func earlyRevocationDuringDrain() async throws {
        let f = Fixture(holdReceive: true), activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(roomID: f.room, activation: activation) }
        try await wait { await f.wire.receiving }
        try await f.wire.emit(f.value(revision: 1)); _ = try await demand.value
        try await wait { await f.wire.receiving }
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) != nil)
        let completion = Completion()
        let closing = Task { await f.pages.close(); await completion.finish() }
        try await wait { await f.wire.cancelledReceivers == 1 }
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil }
        #expect(await completion.count == 0)
        try await f.wire.emit(f.value(revision: 2))
        await closing.value; _ = await page.result
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil)
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }

    @Test("a buffered subscription snapshot cannot hide permission loss and recovery on the same connection")
    func coalescedAuthorityGenerations() async throws {
        let f = Fixture(holdReceive: true), activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(roomID: f.room, activation: activation) }
        try await wait { await f.wire.receiving }
        await f.wire.setAuthorized(false); await f.rooms.authorityDidChange()
        try await wait { await f.wire.cancelledReceivers == 1 }
        try await wait { await f.wire.unsubscribedRooms == 1 }
        await f.wire.setAuthorized(true); await f.rooms.authorityDidChange()
        try await wait { await f.wire.ordinaryCalls == 2 }
        // The consumer is still draining its old non-cooperative receiver while
        // the snapshot stream retains only the newest, subscribed value.
        try await f.wire.emit(f.value(revision: 1))
        try await wait { await f.wire.subscribed.count == 2 }
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil)
        #expect(await f.profiles.diagnostics().waitingConsumers == 1)
        try await f.wire.emit(f.value(revision: 2))
        #expect(try await demand.value?.view.revision.rawValue == 2)
        await f.wire.makeReceiverCooperative()
        page.cancel(); _ = await page.result
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }
}

private struct Fixture {
    let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
    let wire: PageWire
    let profiles: V2ProfilePresentationRepository
    let rooms: V2RoomSubscriptionCoordinator
    let pages: V2AuthorPresentationPageCoordinator
    var key: V2ProfileViewLookupKey { .init(userID: author, context: .room(room)) }
    init(lifetime: Duration = .seconds(30), holdOrdinary: Bool = false, holdAuthor: Bool = false,
         denyAuthor: Bool = false, unsupported: Bool = false, holdReceive: Bool = false) {
        let wire = PageWire(lifetime: lifetime, holdOrdinary: holdOrdinary, holdAuthor: holdAuthor,
                            denyAuthor: denyAuthor, unsupported: unsupported, holdReceive: holdReceive)
        self.wire = wire
        let profiles = V2ProfilePresentationRepository(actorUserID: actor, deviceID: device, reader: SlowHTTP())
        self.profiles = profiles
        let rooms = V2RoomSubscriptionCoordinator(subscriptions: wire, activity: wire, groupEvents: wire,
            activityEvents: wire, isAuthorized: { _ in await wire.authorized }, roomCursor: { _ in 7 }, retryDelay: .milliseconds(5))
        self.rooms = rooms
        pages = .init(rooms: rooms, source: wire, subscriptions: wire, profiles: profiles, roomCursor: { _ in 7 },
            renewalLead: { .milliseconds(20) }, retryDelay: .milliseconds(5))
    }
    func value(revision: UInt64) throws -> V2AuthorizedProfilePresentation {
        let date = Date(timeIntervalSince1970: 2_000_000_000), rev = try #require(V2ProfileRevision(rawValue: revision))
        let view = try V2ProfileView(userID: author,
            publicIdentity: .init(userID: author, handle: .init("author"), displayName: "Author \(revision)", accountKind: .regular),
            avatar: nil, state: .active, revision: rev, visibilityRevision: rev)
        return try .init(view: view, lease: .init(actorUserID: actor, deviceID: device, key: key,
            profileRevision: rev, visibilityRevision: rev, contextRevision: revision,
            observedAt: date, validUntil: date.addingTimeInterval(120)))
    }
}
private struct SlowHTTP: V2ProfilePresentationReading {
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        try await Task.sleep(for: .seconds(60)); throw CancellationError()
    }
}
private actor Completion { var count = 0; func finish() { count += 1 } }
private struct WaitExpired: Error {}
private func wait(_ predicate: () async -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(3)
    while !(await predicate()) { guard .now < until else { throw WaitExpired() }; try await Task.sleep(for: .milliseconds(1)) }
}

private actor PageWire: V2AuthorPresentationSource, V2ClientAuthorPresentationSubscriptionTransport,
    V2ClientGroupEventSubscriptionTransport, V2ClientLiveActivityTransport,
    V2GroupEventAvailabilityHintSource, V2LiveActivityEventSource {
    let lifetime: Duration, unsupported: Bool
    var holdReceive: Bool
    var authorized = true, denyAuthor: Bool
    var nextAuthorError: V2RealtimeTransportError?, failureAt: ContinuousClock.Instant?
    var holdOrdinary: Bool, holdAuthor: Bool
    var ordinaryWaiter: CheckedContinuation<Void, Never>?, authorWaiter: CheckedContinuation<Void, Never>?
    var holdStop = false, stops: [UUID] = []
    var stopWaiter: CheckedContinuation<Void, Never>?
    var waiter: (UUID, CheckedContinuation<V2ReceivedAuthorPresentationDelta, Error>)?
    var pending: [V2ReceivedAuthorPresentationDelta] = []
    var current: V2AuthorPresentationView?
    var views: [V2AuthorPresentationView] = [], subscribed: [UUID] = [], ended: [UUID] = [], generations: [UUID?] = [], cursors: [UInt64] = []
    var ordinaryCalls = 0, begins = 0, cancelledAuthorRequests = 0, cancelledReceivers = 0, maximumReceivers = 0, unsubscribedRooms = 0
    var receiving: Bool { waiter != nil }
    init(lifetime: Duration, holdOrdinary: Bool, holdAuthor: Bool, denyAuthor: Bool, unsupported: Bool, holdReceive: Bool) {
        self.lifetime = lifetime; self.holdOrdinary = holdOrdinary; self.holdAuthor = holdAuthor
        self.denyAuthor = denyAuthor; self.unsupported = unsupported; self.holdReceive = holdReceive
    }
    func setAuthorized(_ value: Bool) { authorized = value }
    func setHoldStop(_ value: Bool) { holdStop = value }
    func releaseStop() { holdStop = false; stopWaiter?.resume(); stopWaiter = nil }
    func setDenyAuthor(_ value: Bool) { denyAuthor = value }
    func failNextAuthor(_ error: V2RealtimeTransportError) { nextAuthorError = error }
    func makeReceiverCooperative() { holdReceive = false }
    func releaseOrdinary() { holdOrdinary = false; ordinaryWaiter?.resume(); ordinaryWaiter = nil }
    func releaseAuthor() { holdAuthor = false; authorWaiter?.resume(); authorWaiter = nil }
    func beginAuthorPresentationView(roomID: RoomID) throws -> V2AuthorPresentationView {
        begins += 1
        if unsupported { throw V2TLSFrameConnectionError.notConnected }
        #expect(current == nil)
        let now = ContinuousClock.now
        let view = V2AuthorPresentationView(streamID: UUID(), viewID: UUID(), roomID: roomID, renewBy: now + lifetime, started: now)
        current = view; views.append(view); generations.append(V2ConnectionRequestScope.connectionID)
        return view
    }
    func endAuthorPresentationView(_ view: V2AuthorPresentationView) {
        ended.append(view.viewID)
        if current == view { current = nil; pending = []; waiter?.1.resume(throwing: CancellationError()); waiter = nil }
    }
    func stopAuthorPresentation(_ view: V2AuthorPresentationView) async throws {
        try Task.checkCancellation()
        #expect(ended.contains(view.viewID))
        #expect(V2ConnectionRequestScope.connectionID != nil)
        stops.append(view.viewID)
        if holdStop { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64) async throws -> V2ClientGroupEventSubscription {
        ordinaryCalls += 1
        if holdOrdinary { await withCheckedContinuation { ordinaryWaiter = $0 } }
        return try .init(roomID: roomID, highWatermark: afterRoomSequence)
    }
    func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64,
                                authorPresentationView: V2AuthorPresentationView?) async throws -> V2ClientGroupEventSubscription {
        let view = try #require(authorPresentationView)
        #expect(current == view); #expect(ordinaryCalls > 0)
        subscribed.append(view.viewID); cursors.append(afterRoomSequence)
        if holdAuthor {
            await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { authorWaiter = $0 }
            }, onCancel: { Task { await self.noteCancelledAuthor() } })
        }
        if denyAuthor { throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil) }
        if let error = nextAuthorError { nextAuthorError = nil; failureAt = .now; throw error }
        return try .init(roomID: roomID, highWatermark: afterRoomSequence)
    }
    private func noteCancelledAuthor() { cancelledAuthorRequests += 1 }
    func nextAuthorPresentationDelta(for view: V2AuthorPresentationView) async throws -> V2ReceivedAuthorPresentationDelta {
        try Task.checkCancellation()
        guard current == view else { throw V2ProfilePresentationError.inactive }
        if !pending.isEmpty { return pending.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                #expect(waiter == nil); maximumReceivers = max(maximumReceivers, 1)
                waiter = (id, continuation)
            }
        }, onCancel: { Task { await self.cancelReceiver(id) } })
    }
    private func cancelReceiver(_ id: UUID) {
        guard waiter?.0 == id else { return }
        cancelledReceivers += 1
        if !holdReceive { waiter?.1.resume(throwing: CancellationError()); waiter = nil }
    }
    func emit(_ value: V2AuthorizedProfilePresentation) throws {
        let view = try #require(current)
        let delta = V2ReceivedAuthorPresentationDelta(view: view, entries: [
            .presentation(value, avatar: nil, presentationDeadline: view.started + .seconds(60), avatarDeadline: nil)
        ])
        if let waiting = waiter { waiter = nil; waiting.1.resume(returning: delta) } else { pending.append(delta) }
    }
    func unsubscribeFromGroupEvents(roomID: RoomID) { unsubscribedRooms += 1 }
    func subscribeTyping(roomID: RoomID) {}
    func unsubscribeTyping(roomID: RoomID) {}
    func setTyping(roomID: RoomID, isTyping: Bool) {}
    func subscribePresence(roomID: RoomID) throws -> V2PresenceState { throw CancellationError() }
    func unsubscribePresence(roomID: RoomID) {}
    func liveActivityPreferences() throws -> V2LiveActivityPreferences { throw CancellationError() }

    func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        try await Task.sleep(for: .seconds(60)); throw CancellationError()
    }
    func nextLiveActivityEvent() async throws -> V2LiveActivityEvent {
        try await Task.sleep(for: .seconds(60)); throw CancellationError()
    }
}
