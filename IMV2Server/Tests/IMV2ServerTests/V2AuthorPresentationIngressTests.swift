import Foundation
import IMV2Core
import Synchronization
@testable import IMV2Server
import Testing

@Suite("Bounded committed-message author handoff", .timeLimit(.minutes(1)))
struct V2AuthorPresentationIngressTests {
    @Test("page samples cap events, bytes and distinct authors without including other event identities")
    func pageSampleBounds() throws {
        let room = RoomID(uuid: UUID()), users = (0..<20).map { _ in UserID(uuid: UUID()) }
        func entry(_ index: Int, payloadRoom: RoomID? = nil, sequence: UInt64? = nil,
                   kind: String = "message", type: String = "message.accepted", padding: Int = 0) throws -> V2GroupEventLogEntry {
            try .init(sourceEventID: EventID(uuid: UUID()), roomSequence: UInt64(index + 1), projectionKind: kind,
                payload: JSONSerialization.data(withJSONObject: ["event_type": type, "room_id": (payloadRoom ?? room).rawValue,
                    "room_sequence": sequence ?? UInt64(index + 1), "sender_user_id": users[index].rawValue,
                    "text": String(repeating: "x", count: padding), "media_ids": [UUID().uuidString]]))
        }
        let sample = try #require(V2AuthorPresentationPageSample(roomID: room, events: (0..<20).map { try entry($0) }))
        #expect(sample.events.count == 16)
        #expect(V2AuthorPresentationHints(page: sample)?.authors == Array(users.prefix(8)))
        let bounded = try #require(V2AuthorPresentationPageSample(roomID: room,
            events: [entry(0, padding: 33_000), entry(1, padding: 33_000), entry(2)]))
        #expect(bounded.events.count == 1)
        #expect(try V2AuthorPresentationPageSample(roomID: room, events: [entry(0, padding: 65_536)]) == nil)
        let wrong = try #require(V2AuthorPresentationPageSample(roomID: room, events: [
            entry(0, payloadRoom: RoomID(uuid: UUID())), entry(1, sequence: 9), entry(2, type: "message.edited"),
            entry(3, kind: "system"), entry(4)]))
        #expect(V2AuthorPresentationHints(page: wrong)?.authors == [users[4]])
        #expect(try V2AuthorPresentationPageSample(roomID: room, events: [entry(0, kind: "system")]) == nil)
    }

    @Test("ten thousand synchronous recipient offers stay bounded behind one held consumer")
    func burstAdmission() async throws {
        let consumer = HeldConsumer()
        let ingress = V2AuthorPresentationIngress(configuration: try .init(), consume: consumer.consume)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        #expect(ingress.submit(connectionID: UUID(), roomID: room, viewID: UUID(), authors: [author]))
        try await wait { await consumer.waiting }
        var accepted = 1
        for _ in 1..<10_000 {
            if ingress.submit(connectionID: UUID(), roomID: room, viewID: UUID(), authors: [author]) { accepted += 1 }
        }
        let stats = ingress.statistics()
        #expect(accepted == 256)
        #expect(stats.activeConsumers == 1 && stats.pendingOffers == 255 && stats.retainedKeys == 256)
        #expect(stats.chargedBytes == 256 * 192 && stats.rejected == 9_744)
        let close = Task { await ingress.close() }
        try await wait { ingress.statistics().closed }
        await consumer.release(); await close.value
        #expect(await consumer.offers.count == 1)
        #expect(ingress.statistics().retainedKeys == 0)
    }

    @Test("key and charged-byte admission limits are enforced independently of offer count", arguments: [false, true])
    func independentBudgets(bytes: Bool) async throws {
        let consumer = HeldConsumer()
        let ingress = V2AuthorPresentationIngress(configuration: try .init(maximumKeys: bytes ? 1_024 : 1,
            maximumChargedBytes: bytes ? 192 : 262_144), consume: consumer.consume)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        #expect(ingress.submit(connectionID: UUID(), roomID: room, viewID: UUID(), authors: [author]))
        try await wait { await consumer.waiting }
        #expect(!ingress.submit(connectionID: UUID(), roomID: room, viewID: UUID(), authors: [author]))
        #expect(ingress.statistics().pendingOffers == 0 && ingress.statistics().activeConsumers == 1)
        await consumer.release(); await ingress.close()
    }

    @Test("coalesces exact views while counting the actual consumer in all admission budgets")
    func boundedCoalescing() async throws {
        let consumer = HeldConsumer()
        let ingress = V2AuthorPresentationIngress(configuration: try .init(maximumOffers: 2, maximumKeys: 3,
            maximumChargedBytes: 448), consume: consumer.consume)
        let room = RoomID(uuid: UUID()), a = UUID(), b = UUID(), view = UUID()
        let users = (0..<3).map { _ in UserID(uuid: UUID()) }
        #expect(ingress.submit(connectionID: a, roomID: room, viewID: view, authors: [users[0]]))
        try await wait { await consumer.waiting }
        #expect(ingress.submit(connectionID: b, roomID: room, viewID: view, authors: [users[1]]))
        #expect(ingress.submit(connectionID: b, roomID: room, viewID: view, authors: [users[1], users[2]]))
        #expect(!ingress.submit(connectionID: UUID(), roomID: room, viewID: view, authors: [users[0]]))
        let held = ingress.statistics()
        #expect(held.activeConsumers == 1 && held.pendingOffers == 1 && held.retainedKeys == 3 && held.chargedBytes == 448)
        await consumer.release()
        try await wait { ingress.statistics().retainedKeys == 0 }
        #expect(await consumer.offers.count == 2)
        #expect(await Set(consumer.offers[1].authors) == Set(users.suffix(2)))
        await ingress.close()
    }

    @Test("close rejects new work, drops queued work and joins an uncancellable actual consumer")
    func closeDrains() async throws {
        let consumer = HeldConsumer(), completions = Count()
        let ingress = V2AuthorPresentationIngress(configuration: try .init(), consume: consumer.consume)
        let room = RoomID(uuid: UUID()), view = UUID(), author = UserID(uuid: UUID())
        #expect(ingress.submit(connectionID: UUID(), roomID: room, viewID: view, authors: [author]))
        try await wait { await consumer.waiting }
        #expect(ingress.submit(connectionID: UUID(), roomID: room, viewID: view, authors: [author]))
        let first = Task { await ingress.close(); await completions.add() }
        let second = Task { await ingress.close(); await completions.add() }
        try await wait { ingress.statistics().closed }
        #expect(ingress.statistics().activeConsumers == 1)
        #expect(ingress.statistics().retainedKeys == 1)
        #expect(ingress.statistics().pendingOffers == 0)
        #expect(!ingress.submit(connectionID: UUID(), roomID: room, viewID: view, authors: [author]))
        #expect(await completions.value == 0)
        await consumer.release(); await first.value; await second.value
        #expect(await completions.value == 2)
        #expect(await consumer.offers.count == 1)
        #expect(ingress.statistics().chargedBytes == 0)
    }

    @Test("expired queued hints are dropped without renewing their age on a merge")
    func staleQueue() async throws {
        let consumer = HeldConsumer()
        let ingress = V2AuthorPresentationIngress(configuration: try .init(lifetime: .milliseconds(80)), consume: consumer.consume)
        let room = RoomID(uuid: UUID()), view = UUID(), author = UserID(uuid: UUID()), second = UUID()
        #expect(ingress.submit(connectionID: UUID(), roomID: room, viewID: view, authors: [author]))
        try await wait { await consumer.waiting }
        #expect(ingress.submit(connectionID: second, roomID: room, viewID: view, authors: [author]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(ingress.submit(connectionID: second, roomID: room, viewID: view, authors: [author]))
        await consumer.release()
        try await wait { ingress.statistics().expired == 1 }
        #expect(await consumer.offers.count == 1)
        await ingress.close()
    }

    @Test("dispatcher rejects queued offers from a previous nonce or an exhausted ingress deadline")
    func viewAndDeadlineFence() async throws {
        let reads = Mutex(0)
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: { request, _ in
            reads.withLock { $0 += 1 }
            return try .init(serverNowUnixMilliseconds: 1, results: request.keys.map { .unavailable($0) })
        })
        let connection = UUID(), room = RoomID(uuid: UUID()), old = UUID(), next = UUID(), author = UserID(uuid: UUID())
        _ = try await dispatcher.register(connectionID: connection,
            identity: .init(userID: UserID(uuid: UUID()), deviceID: DeviceID(uuid: UUID()), capabilityProfile: "base"), send: { _, _ in false })
        #expect(await dispatcher.activateView(connectionID: connection, roomID: room, viewID: old))
        #expect(await dispatcher.activateView(connectionID: connection, roomID: room, viewID: next))
        #expect(!(await dispatcher.offer(connectionID: connection, roomID: room, viewID: old, authors: [author], deadline: .now + .seconds(1))))
        #expect(!(await dispatcher.offer(connectionID: connection, roomID: room, viewID: next, authors: [author], deadline: .now - .milliseconds(1))))
        #expect(reads.withLock { $0 } == 0)
        #expect(await dispatcher.offer(connectionID: connection, roomID: room, viewID: next, authors: [author], deadline: .now + .milliseconds(500)))
        try await wait { reads.withLock { $0 } == 1 }
        await dispatcher.close()
    }

    @Test("only matching group accepted-message identities become bounded author hints")
    func extraction() throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        func event(kind: String = "message", payloadRoom: RoomID? = nil, sequence: UInt64 = 1,
                   eventType: String = "message.accepted", group: Bool = true) throws -> V2DirectRoomLiveEvent {
            let payload = try JSONSerialization.data(withJSONObject: ["event_type": eventType,
                "room_id": (payloadRoom ?? room).rawValue, "room_sequence": sequence, "sender_user_id": user.rawValue])
            return .init(roomID: room, highWatermark: 1, sourceEventID: EventID(uuid: UUID()), roomSequence: 1,
                projectionKind: kind, payload: payload, recipientUserIDs: [], groupMembershipRevision: group ? 1 : nil)
        }
        #expect(try V2AuthorPresentationHints(events: [event(), event()])?.authors == [user])
        #expect(try V2AuthorPresentationHints(events: [event(payloadRoom: RoomID(uuid: UUID()))]) == nil)
        #expect(try V2AuthorPresentationHints(events: [event(sequence: 2)]) == nil)
        #expect(try V2AuthorPresentationHints(events: [event(eventType: "profile.changed")]) == nil)
        #expect(try V2AuthorPresentationHints(events: [event(kind: "system")]) == nil)
        #expect(try V2AuthorPresentationHints(events: [event(group: false)]) == nil)
    }
}

private actor Count { var value = 0; func add() { value += 1 } }
private actor HeldConsumer {
    var offers: [V2AuthorPresentationIngress.Offer] = []
    var continuation: CheckedContinuation<Void, Never>?
    var hold = true
    var waiting: Bool { continuation != nil }
    func consume(_ offer: V2AuthorPresentationIngress.Offer) async {
        offers.append(offer)
        if hold { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { hold = false; continuation?.resume(); continuation = nil }
}
private func wait(_ predicate: () async -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(3)
    while !(await predicate()) { guard .now < until else { throw CancellationError() }; try await Task.sleep(for: .milliseconds(1)) }
}
