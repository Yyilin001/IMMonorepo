@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Bounded committed-message author handoff", .timeLimit(.minutes(1)))
struct V2AuthorPresentationIngressTests {
    @Test("live and history hints use the validated full edit's original sender", arguments: 0...12)
    func completeEditAuthor(mode: Int) throws {
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        let bytes = try AuthorPresentationMessageFixtures.edited(room: room, author: author)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var replacement = try #require(object["replacement"] as? [String: Any])
        var state = try #require(replacement["state"] as? [String: Any])
        switch mode {
        case 1: object["sender_user_id"] = UUID().uuidString
        case 2: object["sender_user_id"] = UUID().uuidString
        case 3: state.removeValue(forKey: "reply_to_message_id")
        case 4: object["room_id"] = UUID().uuidString
        case 5: object["room_sequence"] = 3
        case 6: object["message_revision"] = 3
        case 7: object["text"] = "different"
        case 8: replacement["schema_version"] = 2
        case 9: state["sender_user_id"] = "invalid"
        case 10: object["message_id"] = UUID().uuidString
        case 11: object["room_sequence"] = 1
        case 12: object["event_type"] = "message.withdrawn"
        default: break
        }
        replacement["state"] = state; object["replacement"] = replacement
        if mode == 2 { object.removeValue(forKey: "replacement") }
        let payload = try JSONSerialization.data(withJSONObject: object)
        let expected: [UserID]? = mode <= 1 ? [author] : nil
        for direct in [false, true] {
            let event = V2DirectRoomLiveEvent(roomID: room, highWatermark: 2, sourceEventID: .init(uuid: UUID()),
                roomSequence: 2, projectionKind: "message", payload: payload,
                recipientUserIDs: direct ? [author] : [], groupMembershipRevision: direct ? nil : 1)
            let hints = direct ? V2AuthorPresentationHints(directEvent: event) : V2AuthorPresentationHints(events: [event])
            #expect(hints?.authors == expected)
        }
        let sample = try #require(V2AuthorPresentationPageSample(roomID: room, events: [
            try .init(sourceEventID: .init(uuid: UUID()), roomSequence: 2, projectionKind: "message", payload: payload)
        ]))
        #expect(V2AuthorPresentationHints(page: sample)?.authors == expected)
    }

    @Test("nickname changes coalesce by room and author; overflow keeps one bounded recovery obligation")
    func nicknameOverflow() async throws {
        let consumer = HeldConsumer(), changes = Mutex<[V2AuthorGroupNicknameChange]>([]), resets = Mutex(0), rooms = Mutex<[RoomID]>([])
        let ingress = V2AuthorPresentationIngress(configuration: try .init(maximumOffers: 4), consume: consumer.consume,
            consumeChange: { change in changes.withLock { $0.append(change) } },
            consumeRoomReset: { room in rooms.withLock { $0.append(room) } },
            recoverOverflow: { resets.withLock { $0 += 1 } })
        let room = RoomID(uuid: UUID()), secondRoom = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        #expect(ingress.submit(connectionID: UUID(), roomID: room, viewID: UUID(), authors: [author]))
        try await wait { await consumer.waiting }
        let first = try V2AuthorGroupNicknameChange(roomID: room, userID: author, revision: 2)
        let newer = try V2AuthorGroupNicknameChange(roomID: room, userID: author, revision: 3)
        let second = try V2AuthorGroupNicknameChange(roomID: secondRoom, userID: author, revision: 1)
        #expect(ingress.submitNicknameChange(first))
        #expect(ingress.submitNicknameChange(newer))
        #expect(ingress.submitNicknameChange(first))
        #expect(ingress.submitNicknameChange(second))
        #expect(ingress.submitRoomReset(room))
        #expect(ingress.submitRoomReset(room))
        for _ in 0..<1_000 {
            #expect(try !ingress.submitNicknameChange(.init(roomID: room, userID: .init(uuid: UUID()), revision: 1)))
        }
        let held = ingress.statistics()
        #expect(held.pendingChanges == 2 && held.pendingRoomResets == 1 && held.retainedKeys == 4 && held.chargedBytes == 768)
        #expect(held.resetPending && held.rejected == 1_000 && held.activeConsumers == 1)
        await consumer.release()
        try await wait { ingress.statistics().retainedKeys == 0 && ingress.statistics().activeConsumers == 0 }
        #expect(changes.withLock { $0 } == [newer, second])
        #expect(rooms.withLock { $0 } == [room])
        #expect(resets.withLock { $0 } == 1 && !ingress.statistics().resetPending)
        await ingress.close()
    }

    @Test("nickname and message queues share key and byte budgets", arguments: [false, true])
    func nicknameSharedBudgets(bytes: Bool) async throws {
        let consumer = HeldConsumer()
        let ingress = V2AuthorPresentationIngress(configuration: try .init(maximumKeys: bytes ? 1_024 : 1,
            maximumChargedBytes: bytes ? 192 : 262_144), consume: consumer.consume)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        #expect(ingress.submit(connectionID: UUID(), roomID: room, viewID: UUID(), authors: [author]))
        try await wait { await consumer.waiting }
        #expect(try !ingress.submitNicknameChange(.init(roomID: room, userID: author, revision: 1)))
        #expect(!ingress.submitRoomReset(room))
        #expect(ingress.statistics().pendingChanges == 0 && ingress.statistics().resetPending)
        #expect(ingress.statistics().retainedKeys == 1 && ingress.statistics().chargedBytes == 192)
        await consumer.release(); await ingress.close()
    }

    @Test("shutdown retains an actual nickname consumer until it exits and drops queued recovery")
    func nicknameClose() async throws {
        let consumer = HeldNicknameConsumer(), completed = Count()
        let ingress = V2AuthorPresentationIngress(configuration: try .init(maximumOffers: 3), consume: { _ in },
            consumeChange: consumer.consume)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        #expect(try ingress.submitNicknameChange(.init(roomID: room, userID: author, revision: 1)))
        try await wait { await consumer.waiting }
        #expect(try ingress.submitNicknameChange(.init(roomID: room, userID: author, revision: 2)))
        #expect(ingress.submitRoomReset(room))
        #expect(try !ingress.submitNicknameChange(.init(roomID: .init(uuid: UUID()), userID: author, revision: 1)))
        let closing = Task { await ingress.close(); await completed.add() }
        try await wait { ingress.statistics().closed }
        let held = ingress.statistics()
        #expect(held.pendingChanges == 0 && held.pendingRoomResets == 0 && !held.resetPending && held.activeConsumers == 1)
        #expect(held.retainedKeys == 1 && held.chargedBytes == 192)
        #expect(await completed.value == 0)
        #expect(try !ingress.submitNicknameChange(.init(roomID: room, userID: author, revision: 3)))
        await consumer.release(); await closing.value
        #expect(await consumer.revisions == [1])
        #expect(ingress.statistics().retainedKeys == 0 && ingress.statistics().chargedBytes == 0)
    }

    @Test("nickname invalidations require a bounded, matching committed room event", arguments: 0...8)
    func nicknameExtraction(mode: Int) throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let payload = try JSONSerialization.data(withJSONObject: ["event_type": mode == 1 ? "group.created" : "group.nickname_changed",
            "room_id": (mode == 2 ? RoomID(uuid: UUID()) : room).rawValue,
            "room_sequence": mode == 3 ? 2 : 1, "target_user_id": mode == 4 ? "invalid" : user.rawValue,
            "revision": mode == 5 ? 0 : 7, "padding": String(repeating: "x", count: mode == 8 ? 65_536 : 0)])
        let event = V2DirectRoomLiveEvent(roomID: room, highWatermark: 1, sourceEventID: .init(uuid: UUID()),
            roomSequence: 1, projectionKind: mode == 6 ? "message" : "group_capability", payload: payload,
            recipientUserIDs: [], groupMembershipRevision: mode == 7 ? nil : 1)
        #expect(try V2AuthorGroupNicknameChange(event: event) == (mode == 0 ? .init(roomID: room, userID: user, revision: 7) : nil))
    }

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
        _ = try await dispatcher.registerFixture(connectionID: connection,
            identity: .init(userID: UserID(uuid: UUID()), deviceID: DeviceID(uuid: UUID()), capabilityProfile: "base"), send: { _, _ in false })
        #expect(await dispatcher.activateRoomFixture(connectionID: connection, roomID: room, viewID: old))
        #expect(await dispatcher.activateRoomFixture(connectionID: connection, roomID: room, viewID: next))
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
private actor HeldNicknameConsumer {
    var revisions: [UInt64] = []
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func consume(_ change: V2AuthorGroupNicknameChange) async {
        revisions.append(change.revision)
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
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
