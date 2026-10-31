#if canImport(Network) && canImport(Security)
import Foundation
import IMV2Core
import Synchronization
@testable import IMV2ClientKit
import Testing

@Suite("Author supplements on the authenticated connection", .timeLimit(.minutes(1)))
struct V2AuthorPresentationWireTests {
    @Test("visible interests replace the complete set and cannot escape the current page")
    func interestsRoundTrip() async throws {
        let peer = AuthorWirePeer(), connection = try connection(peer)
        let session = try await login(connection, peer: peer)
        let view = try await connection.beginAuthorPresentationView(roomID: peer.room)
        let subscribing = Task { try await connection.request(subscribe(view, requestID: 3)) }
        await peer.waitForSubscription(3)
        try await peer.replySubscription(3, includeDelta: false)
        _ = try await subscribing.value
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let interest = try V2AuthorPresentationInterests(streamID: view.streamID, viewID: view.viewID, sequence: 1,
            keys: [.init(userID: peer.author, context: .room(peer.room)), .init(userID: peer.author, context: .relationship)])
        try await transport.replaceAuthorPresentationInterests(interest)
        let clearing = try V2AuthorPresentationInterests(streamID: view.streamID, viewID: view.viewID,
            roomID: view.roomID, sequence: 2, userIDs: [])
        try await transport.replaceAuthorPresentationInterests(clearing)
        #expect(await peer.interests.map { $0.keys.map(\.userID) } == [[peer.author.rawValue, peer.author.rawValue], []])
        await connection.endAuthorPresentationView(view)
        await #expect(throws: V2TLSFrameConnectionError.unexpectedResponse) {
            try await transport.replaceAuthorPresentationInterests(interest)
        }
        #expect(await peer.interests.count == 2)
        await connection.disconnect()
    }
    @Test("retained-entry receipt round trips on its exact live connection and page")
    func receiptRoundTrip() async throws {
        let peer = AuthorWirePeer(), connection = try connection(peer)
        let session = try await login(connection, peer: peer)
        let view = try await connection.beginAuthorPresentationView(roomID: peer.room)
        let subscribeTask = Task { try await connection.request(subscribe(view, requestID: 3)) }
        await peer.waitForSubscription(3)
        try await peer.replySubscription(3, includeDelta: false)
        _ = try await subscribeTask.value
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let receipt = try V2AuthorPresentationReceipt(streamID: view.streamID, viewID: view.viewID, sequence: 7,
            keys: [.init(userID: peer.author, context: .room(peer.room)), .init(userID: peer.author, context: .relationship)],
            minimumRemainingMilliseconds: 120_000)
        try await transport.acknowledgeAuthorPresentation(receipt)
        #expect(await peer.receipts.count == 1)
        #expect(await peer.receipts.first?.sequence == 7)
        #expect(await peer.receipts.first?.keys.map(\.userID) == [peer.author.rawValue, peer.author.rawValue])
        #expect(await peer.receipts.first?.hasMinimumRemainingMilliseconds == true)
        #expect(await peer.receipts.first?.minimumRemainingMilliseconds == 120_000)
        await connection.endAuthorPresentationView(view)
        await #expect(throws: V2TLSFrameConnectionError.unexpectedResponse) {
            try await transport.acknowledgeAuthorPresentation(receipt)
        }
        #expect(await peer.receipts.count == 1)
        await connection.disconnect()
    }

    @Test("a pulled attachment page and its coalesced author delta keep independent cursors and consumers")
    func pulledPageAndDelta() async throws {
        let peer = AuthorWirePeer(supplementOnPull: true), connection = try connection(peer)
        let session = try await login(connection, peer: peer)
        let view = try await connection.beginAuthorPresentationView(roomID: peer.room)
        let subscribeTask = Task { try await connection.request(subscribe(view, requestID: 3)) }
        await peer.waitForSubscription(3)
        try await peer.replySubscription(3, includeDelta: false)
        _ = try await subscribeTask.value
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let page = try await transport.pullGroupEvents(roomID: peer.room, afterRoomSequence: 7, pageSize: 20)
        let delta = try await connection.nextAuthorPresentationDelta(for: view)
        #expect(page.roomID == peer.room && page.nextRoomSequence == 8 && page.events.count == 1)
        #expect(page.events.first?.roomSequence == 8 && page.events.first?.projectionKind == "message")
        let body = try #require(page.events.first?.payload)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((fields["media_ids"] as? [String])?.count == 1)
        #expect(fields["authorPresentationDelta"] == nil)
        #expect(delta.view == view && delta.entries.count == 1)
        guard case .unavailable(let key, _) = delta.entries.first else { throw V2RealtimeTransportError.unexpectedResponse }
        #expect(key.key.userID == peer.author && key.key.context == .room(peer.room))
        await connection.endAuthorPresentationView(view)
        await connection.disconnect()
    }

    @Test("cleanup waiting for an old socket cannot send into its replacement connection")
    func cleanupCannotCrossConnection() async throws {
        let old = AuthorWirePeer(holdAuthorSend: true), next = AuthorWirePeer()
        let peers = Mutex([old, next])
        let connection = V2TLSFrameConnection(connectionFactory: {
            AuthorWireBytes(peer: peers.withLock { $0.removeFirst() })
        }, frameLimits: try limits(), supportsAuthorPresentationDelta: true)
        let firstSession = try await login(connection, peer: old)
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: firstSession.protocolVersion)
        let view = try await connection.beginAuthorPresentationView(roomID: old.room)
        let subscribe = Task { try await transport.startAuthorPresentation(view) }
        try await wireWait { await old.authorSendStarted }
        subscribe.cancel(); _ = await subscribe.result
        await connection.endAuthorPresentationView(view)
        let cleanup = Task {
            try await V2ConnectionRequestScope.$connectionID.withValue(firstSession.connectionID) {
                try await transport.stopAuthorPresentation(view)
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let disconnect = Task { await connection.disconnect() }
        try await wireWait { await old.closed }
        let nextSession = try await login(connection, peer: next)
        #expect(nextSession.connectionID != firstSession.connectionID)
        await old.releaseAuthorSend()
        await #expect(throws: V2TLSFrameConnectionError.connectionClosed) { try await cleanup.value }
        await disconnect.value
        #expect(await old.stops.isEmpty)
        #expect(await next.stops.isEmpty)
        let current = try await connection.beginAuthorPresentationView(roomID: next.room)
        #expect(current.streamID == next.streamID)
        await connection.disconnect()
    }

    @Test("nonce stop follows the actual cancelled subscribe socket write")
    func cancelledSendBeforeStop() async throws {
        let peer = AuthorWirePeer(holdAuthorSend: true), connection = try connection(peer)
        let session = try await login(connection, peer: peer)
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let view = try await connection.beginAuthorPresentationView(roomID: peer.room)
        let pending = Task { try await transport.startAuthorPresentation(view) }
        try await wireWait { await peer.authorSendStarted }
        pending.cancel(); _ = await pending.result
        await connection.endAuthorPresentationView(view)
        let cleanup = Task { try await transport.stopAuthorPresentation(view) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await peer.stops.isEmpty)
        await peer.releaseAuthorSend()
        await peer.waitForSubscription(1)
        try await peer.replySubscription(1)
        try await cleanup.value
        #expect(await peer.events == ["subscribe", "end"])
        #expect(await peer.stops.first?.viewID == view.viewID.uuidString)
        await #expect(throws: V2ProfilePresentationError.inactive) {
            _ = try await connection.nextAuthorPresentationDelta(for: view)
        }
        await connection.disconnect()
    }

    @Test("stop rejects a response that does not echo the same stream and nonce", arguments: [0, 1])
    func invalidStopEcho(field: Int) async throws {
        let peer = AuthorWirePeer(stopMismatch: field), connection = try connection(peer)
        let session = try await login(connection, peer: peer)
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let view = try await connection.beginAuthorPresentationView(roomID: peer.room)
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            try await transport.stopAuthorPresentation(view)
        }
        await connection.disconnect()
    }

    @Test("coalesced subscribe response and delta install the nonce before reader delivery")
    func coalescedDelta() async throws {
        let peer = AuthorWirePeer(), connection = try connection(peer)
        let session = try await login(connection, peer: peer)
        #expect(session.authorPresentationStreamID == peer.streamID)
        let view = try await connection.beginAuthorPresentationView(roomID: peer.room)
        let pending = Task { try await connection.request(subscribe(view, requestID: 3)) }
        await peer.waitForSubscription(3)
        try await peer.replySubscription(3)
        _ = try await pending.value
        let delta = try await connection.nextAuthorPresentationDelta(for: view)
        #expect(delta.view == view && delta.entries.count == 1)
        await connection.endAuthorPresentationView(view)
        await #expect(throws: V2ProfilePresentationError.inactive) {
            _ = try await connection.nextAuthorPresentationDelta(for: view)
        }
        await connection.disconnect()
    }

    @Test("cancelled old subscribe cannot reactivate a replaced page on the same socket")
    func lateCancelledPage() async throws {
        let peer = AuthorWirePeer(), connection = try connection(peer)
        _ = try await login(connection, peer: peer)
        let old = try await connection.beginAuthorPresentationView(roomID: peer.room)
        let pending = Task { try await connection.request(subscribe(old, requestID: 3)) }
        await peer.waitForSubscription(3)
        pending.cancel(); _ = await pending.result
        let next = try await connection.beginAuthorPresentationView(roomID: peer.room)
        let nextRequest = Task { try await connection.request(subscribe(next, requestID: 4)) }
        await peer.waitForSubscription(4)
        try await peer.replySubscription(3)
        try await peer.replySubscription(4)
        _ = try await nextRequest.value
        let result = try await connection.nextAuthorPresentationDelta(for: next)
        #expect(result.view == next)
        await connection.endAuthorPresentationView(old)
        let waiting = Task { try await connection.nextAuthorPresentationDelta(for: next) }
        await connection.disconnect()
        await #expect(throws: (any Error).self) { _ = try await waiting.value }
    }

    @Test("the page owner consumes coalesced deltas through actual protobuf and authenticated connection owners")
    func pageThroughWire() async throws {
        let peer = AuthorWirePeer(), connection = try connection(peer)
        let session = try await login(connection, peer: peer)
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let rooms = V2RoomSubscriptionCoordinator(subscriptions: transport, activity: transport,
            groupEvents: connection, activityEvents: connection, isAuthorized: { _ in true }, roomCursor: { _ in 7 })
        let profiles = V2ProfilePresentationRepository(actorUserID: peer.user, deviceID: peer.device, reader: WireProfileReader())
        let pages = V2AuthorPresentationPageCoordinator(rooms: rooms, source: connection,
            subscriptions: transport, profiles: profiles)
        let other = try await rooms.acquire(roomID: peer.room, channels: [.roomEvents])
        let activation = await profiles.activate(), key = V2ProfileViewLookupKey(userID: peer.author, context: .room(peer.room))
        let demand = Task { try await profiles.presentation(for: key, activation: activation) }
        while await profiles.diagnostics().waitingConsumers != 1 { try await Task.sleep(for: .milliseconds(1)) }
        let connectionID = try #require(session.connectionID)
        let runtime = Task { try await rooms.run(connectionID: connectionID) }
        let page = Task { try await pages.run(messageRoomID: peer.room, activation: activation) }
        await peer.waitForSubscription(1)
        await peer.waitForSubscription(2)
        let authorRequest = try #require(await peer.subscriptions.first {
            if case .authorPresentationStart = $0.value.body { true } else { false }
        })
        let roomRequest = try #require(await peer.subscriptions.first {
            if case .groupEventSubscribe = $0.value.body { true } else { false }
        })
        try await peer.replySubscription(authorRequest.key)
        try await peer.replySubscription(roomRequest.key, includeDelta: false)
        #expect(try await demand.value == nil)
        page.cancel(); _ = await page.result
        #expect(await peer.stops.count == 1)
        #expect(await peer.stops.first?.viewID == authorRequest.value.authorPresentationStart.viewID)
        #expect(await peer.unsubscribes == 0)
        await rooms.release(roomID: peer.room, consumerID: other.id)
        runtime.cancel(); _ = await runtime.result
        await pages.close(); await profiles.close(); await connection.disconnect()
    }

    @Test("unrequested negotiation and inconsistent authentication echoes fail closed", arguments: [0, 1])
    func badNegotiation(mode: Int) async throws {
        let peer = AuthorWirePeer(mismatch: mode == 1)
        let connection = try connection(peer, offered: mode != 0)
        await #expect(throws: (any Error).self) { _ = try await login(connection, peer: peer) }
        await connection.disconnect()
    }

    @Test("ordinary room subscriptions preserve an independent author view")
    func independentRooms() async throws {
        let peer = AuthorWirePeer(), connection = try connection(peer)
        _ = try await login(connection, peer: peer)
        let view = try await connection.beginAuthorPresentationView(roomID: peer.room)
        let pending = Task { try await connection.request(subscribe(view, requestID: 3)) }
        await peer.waitForSubscription(3)
        try await peer.replySubscription(3, includeDelta: false)
        _ = try await pending.value
        for (index, room) in [RoomID(uuid: UUID()), peer.room].enumerated() {
            let requestID = UInt64(index + 4)
            var envelope = IMV2Envelope(); envelope.requestID = requestID; envelope.protocolVersion = IMV2ProtocolVersion.current
            envelope.groupEventSubscribe.roomID = room.rawValue.lowercased()
            let frame = try V2ProtobufFrameCodec.encode(envelope, frameVersion: UInt8(IMV2ProtocolVersion.current))
            let ordinary = Task { try await connection.request(frame) }
            await peer.waitForSubscription(requestID)
            try await peer.replySubscription(requestID, includeDelta: false)
            _ = try await ordinary.value
            try await peer.pushPayload(payload(peer: peer, view: view.viewID, sequence: UInt64(index + 1)))
            #expect(try await connection.nextAuthorPresentationDelta(for: view).view == view)
        }
        await connection.disconnect()
    }

    @Test("no server opt-in preserves the ordinary connection")
    func noServerCapability() async throws {
        let peer = AuthorWirePeer(select: false), connection = try connection(peer)
        let session = try await login(connection, peer: peer)
        #expect(session.authorPresentationStreamID == nil)
        await #expect(throws: V2TLSFrameConnectionError.notConnected) {
            _ = try await connection.beginAuthorPresentationView(roomID: peer.room)
        }
        await connection.disconnect()
    }

    @Test("oversized pushed payload closes its generation and releases the author waiter")
    func oversizedFrame() async throws {
        let peer = AuthorWirePeer(), connection = try connection(peer)
        _ = try await login(connection, peer: peer)
        let view = try await connection.beginAuthorPresentationView(roomID: peer.room)
        let pending = Task { try await connection.request(subscribe(view, requestID: 3)) }
        await peer.waitForSubscription(3)
        try await peer.replySubscription(3, includeDelta: false)
        _ = try await pending.value
        let waiter = Task { try await connection.nextAuthorPresentationDelta(for: view) }
        try await peer.pushPayload(Data(repeating: 32, count: 32_769))
        await #expect(throws: (any Error).self) { _ = try await waiter.value }
        await connection.disconnect()
    }

    @Test("a list-only inbox accepts full contexts and rejects a mismatched start echo")
    func listViewAndStartBinding() throws {
        let peer = AuthorWirePeer()
        var inbox = V2AuthorPresentationInbox(streamID: peer.streamID, actorUserID: peer.user, deviceID: peer.device)
        let view = try inbox.begin(messageRoomIDs: [])
        var start = IMV2AuthorPresentationStart(); start.streamID = view.streamID.uuidString; start.viewID = view.viewID.uuidString
        #expect(try inbox.requestedView(start) == view)
        for field in 0..<3 {
            var invalid = start
            if field == 0 { invalid.streamID = UUID().uuidString }
            if field == 1 { invalid.viewID = UUID().uuidString }
            if field == 2 { invalid.messageRoomIds = [peer.room.rawValue] }
            #expect(throws: V2TLSFrameConnectionError.unexpectedResponse) { try inbox.confirm(view, response: invalid) }
        }
        try inbox.confirm(view, response: start)
        let keys: [V2ProfileViewLookupKey] = [.init(userID: peer.author, context: .room(peer.room)),
            .init(userID: peer.author, context: .relationship), .init(userID: peer.author, context: .groupJoinReview(peer.room))]
        let delta = try V2AuthorPresentationDelta(streamID: view.streamID, viewID: view.viewID, sequence: 1,
            actorUserID: peer.user, deviceID: peer.device, serverViewAgeMilliseconds: 0,
            batch: .init(serverNowUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000), results: keys.map { .unavailable($0) }))
        try inbox.accept(delta.encoded())
        let next = try inbox.next(for: view)
        let received = try #require(next)
        let actual = received.entries.compactMap { entry -> V2ProfileViewLookupKey? in
            if case .unavailable(let denial, _) = entry { return denial.key }; return nil
        }
        #expect(actual == keys)
    }

    @Test("disposable inbox bounds both frames and raw bytes and clears on page change")
    func inboxBudgets() throws {
        let peer = AuthorWirePeer()
        var inbox = V2AuthorPresentationInbox(streamID: peer.streamID, actorUserID: peer.user, deviceID: peer.device)
        let view = try inbox.begin(messageRoomIDs: [peer.room])
        var response = IMV2AuthorPresentationStart(); response.messageRoomIds = [peer.room.rawValue]
        response.streamID = view.streamID.uuidString; response.viewID = view.viewID.uuidString
        try inbox.confirm(view, response: response)
        for sequence in 1...50 {
            let raw = try payload(peer: peer, view: view.viewID, sequence: UInt64(sequence))
            var json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            json["padding"] = String(repeating: "x", count: 24_000)
            try inbox.accept(JSONSerialization.data(withJSONObject: json))
            #expect(inbox.queuedBytes <= V2AuthorPresentationInbox.maximumBytes)
        }
        var count = 0
        while try inbox.next(for: view) != nil { count += 1 }
        #expect(count == 2)
        try inbox.accept(payload(peer: peer, view: view.viewID, sequence: 51))
        let next = try inbox.begin(messageRoomIDs: [peer.room])
        #expect(inbox.queuedBytes == 0)
        #expect(try inbox.next(for: next) == nil)
    }

    private func connection(_ peer: AuthorWirePeer, offered: Bool = true) throws -> V2TLSFrameConnection {
        .init(connectionFactory: { AuthorWireBytes(peer: peer) }, frameLimits: try limits(),
              supportsAuthorPresentationDelta: offered)
    }
    private func login(_ connection: V2TLSFrameConnection, peer: AuthorWirePeer) async throws -> V2AuthenticatedClientSession {
        try await connection.connectAndAuthenticate(accessToken: "test", deviceID: peer.device, supportedCapabilityProfiles: ["base"])
    }
}

private func limits() throws -> V2FrameLimits {
    try .init(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
}
private func subscribe(_ view: V2AuthorPresentationView, requestID: UInt64) throws -> V2Frame {
    var envelope = IMV2Envelope(); envelope.requestID = requestID; envelope.protocolVersion = IMV2ProtocolVersion.current
    envelope.authorPresentationStart.messageRoomIds = view.messageRoomIDs.map(\.rawValue)
    envelope.authorPresentationStart.streamID = view.streamID.uuidString
    envelope.authorPresentationStart.viewID = view.viewID.uuidString
    return try V2ProtobufFrameCodec.encode(envelope, frameVersion: UInt8(IMV2ProtocolVersion.current))
}
private func payload(peer: AuthorWirePeer, view: UUID, sequence: UInt64 = 1) throws -> Data {
    try V2AuthorPresentationDelta(streamID: peer.streamID, viewID: view, sequence: sequence,
        actorUserID: peer.user, deviceID: peer.device, roomID: peer.room,
        batch: .init(serverNowUnixMilliseconds: 1, results: [.unavailable(.init(userID: peer.author, context: .room(peer.room)))])).encoded()
}
private struct AuthorWireBytes: V2TLSByteConnection {
    let peer: AuthorWirePeer
    func start() async throws {}
    func send(_ data: Data) async throws { try await peer.send(data) }
    func receive(maximumLength: Int) async throws -> Data { try await peer.receive() }
    func cancel() { Task { await peer.cancel() } }
}
private struct WireProfileReader: V2ProfilePresentationReading {
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        try await Task.sleep(for: .seconds(60)); throw CancellationError()
    }
}
private actor AuthorWirePeer {
    let streamID = UUID(), user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
    let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
    let select: Bool, mismatch: Bool
    var subscriptions: [UInt64: IMV2Envelope] = [:]
    var stops: [IMV2AuthorPresentationEnd] = []
    var receipts: [IMV2AuthorPresentationReceipt] = []
    var interests: [IMV2AuthorPresentationInterests] = []
    var events: [String] = [], unsubscribes = 0
    var holdAuthorSend: Bool, authorSendStarted = false
    var authorSendWaiter: CheckedContinuation<Void, Never>?
    let stopMismatch: Int?
    let supplementOnPull: Bool
    var observers: [(UInt64, CheckedContinuation<Void, Never>)] = []
    var queue: [Data] = [], waiter: CheckedContinuation<Data, Error>?, closed = false
    init(select: Bool = true, mismatch: Bool = false, holdAuthorSend: Bool = false, stopMismatch: Int? = nil,
         supplementOnPull: Bool = false) {
        self.select = select; self.mismatch = mismatch; self.holdAuthorSend = holdAuthorSend; self.stopMismatch = stopMismatch
        self.supplementOnPull = supplementOnPull
    }
    func releaseAuthorSend() { holdAuthorSend = false; authorSendWaiter?.resume(); authorSendWaiter = nil }
    func send(_ bytes: Data) async throws {
        var decoder = V2FrameDecoder(limits: try limits())
        let frame = try #require(decoder.append(bytes).first), request = try V2ProtobufFrameCodec.decode(frame)
        var response = IMV2Envelope(); response.requestID = request.requestID; response.protocolVersion = IMV2ProtocolVersion.current
        switch request.body {
        case .clientHello:
            response.serverHello.selectedProtocolVersion = IMV2ProtocolVersion.current
            response.serverHello.selectedCapabilityProfile = "base"
            response.serverHello.authorPresentationStreamID = select ? streamID.uuidString : ""
        case .authenticate:
            response.authenticated.userID = user.rawValue; response.authenticated.deviceID = device.rawValue
            response.authenticated.selectedCapabilityProfile = "base"
            response.authenticated.authorPresentationStreamID = select ? (mismatch ? UUID().uuidString : streamID.uuidString) : ""
        case .presencePublicationControl(let control):
            response.presencePublicationControlled.mode = control.mode
        case .authorPresentationStart:
            authorSendStarted = true
            if holdAuthorSend { await withCheckedContinuation { authorSendWaiter = $0 } }
            events.append("subscribe")
            subscriptions[request.requestID] = request
            for observer in observers where observer.0 == request.requestID { observer.1.resume() }
            observers.removeAll { $0.0 == request.requestID }; return
        case .groupEventSubscribe:
            events.append("subscribe")
            subscriptions[request.requestID] = request
            for observer in observers where observer.0 == request.requestID { observer.1.resume() }
            observers.removeAll { $0.0 == request.requestID }; return
        case .authorPresentationReceipt(let receipt):
            receipts.append(receipt)
            response.authorPresentationReceipted = receipt
        case .authorPresentationInterests(let value):
            interests.append(value)
            response.authorPresentationInterestsReceived = value
        case .authorPresentationEnd(let end):
            events.append("end")
            stops.append(end)
            response.authorPresentationEnded.streamID = stopMismatch == 0 ? UUID().uuidString : end.streamID
            response.authorPresentationEnded.viewID = stopMismatch == 1 ? UUID().uuidString : end.viewID
        case .groupEventUnsubscribe:
            unsubscribes += 1; response.acknowledged = .init()
        case .groupEventPull(let pull) where supplementOnPull:
            response.groupEventPage.roomID = pull.roomID
            response.groupEventPage.nextRoomSequence = pull.afterRoomSequence + 1
            var event = IMV2GroupEvent(); event.sourceEventID = UUID().uuidString
            event.roomSequence = pull.afterRoomSequence + 1; event.projectionKind = "message"
            event.payload = try JSONSerialization.data(withJSONObject: ["event_type": "message.accepted",
                "room_id": pull.roomID, "room_sequence": event.roomSequence, "sender_user_id": author.rawValue,
                "media_ids": [UUID().uuidString]])
            response.groupEventPage.events = [event]
            let subscribed = try #require(subscriptions.values.first { if case .authorPresentationStart = $0.body { true } else { false } })
            var delta = IMV2Envelope(); delta.protocolVersion = IMV2ProtocolVersion.current
            delta.authorPresentationDelta.payload = try payload(peer: self,
                view: #require(UUID(uuidString: subscribed.authorPresentationStart.viewID)))
            var bytes = try encode(response); bytes.append(try encode(delta)); push(bytes); return
        default: response.acknowledged = .init()
        }
        push(try encode(response))
    }
    func waitForSubscription(_ id: UInt64) async {
        if subscriptions[id] != nil { return }
        await withCheckedContinuation { observers.append((id, $0)) }
    }
    func replySubscription(_ id: UInt64, includeDelta: Bool = true) throws {
        let request = try #require(subscriptions[id])
        var response = IMV2Envelope(); response.requestID = id; response.protocolVersion = IMV2ProtocolVersion.current
        if case .authorPresentationStart(let start) = request.body { response.authorPresentationStarted = start }
        else { response.groupEventSubscribed.roomID = request.groupEventSubscribe.roomID }
        var bytes = try encode(response)
        if includeDelta {
            var delta = IMV2Envelope(); delta.protocolVersion = IMV2ProtocolVersion.current
            delta.authorPresentationDelta.payload = try payload(peer: self, view: #require(UUID(uuidString: request.authorPresentationStart.viewID)))
            bytes.append(try encode(delta))
        }
        push(bytes)
    }
    func pushPayload(_ bytes: Data) throws {
        var envelope = IMV2Envelope(); envelope.protocolVersion = IMV2ProtocolVersion.current
        envelope.authorPresentationDelta.payload = bytes; push(try encode(envelope))
    }
    func encode(_ envelope: IMV2Envelope) throws -> Data {
        try V2FrameCodec.encode(V2ProtobufFrameCodec.encode(envelope, frameVersion: UInt8(IMV2ProtocolVersion.current)), limits: limits())
    }
    func push(_ bytes: Data) {
        if let waiter { self.waiter = nil; waiter.resume(returning: bytes) } else { queue.append(bytes) }
    }
    func receive() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw V2TLSFrameConnectionError.connectionClosed }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func cancel() { closed = true; waiter?.resume(throwing: V2TLSFrameConnectionError.connectionClosed); waiter = nil }
}
private func wireWait(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard .now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(1))
    }
}
#endif
