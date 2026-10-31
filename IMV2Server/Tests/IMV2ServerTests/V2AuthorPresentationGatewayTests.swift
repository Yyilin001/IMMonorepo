@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2ActorContracts
import NIOCore
import NIOEmbedded
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("Negotiated author supplements through Gateway", .timeLimit(.minutes(1)))
struct V2AuthorPresentationGatewayTests {
    @Test("visible interest is registered before its receipt; removal bypasses exhausted domain admission")
    func visibleInterestContract() async throws {
        let gate = SwitchAdmission(), f = try Fixture(admission: gate)
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let stream = try #require(await f.login()), view = UUID()
        _ = try await f.stream.receive(f.subscribe(view))
        var request = IMV2Envelope(); request.requestID = 4
        request.authorPresentationInterests.streamID = stream.uuidString
        request.authorPresentationInterests.viewID = view.uuidString
        request.authorPresentationInterests.sequence = 1
        request.authorPresentationInterests.keys = [profileWireKey(user: f.author, room: f.room)]
        let expected = request.authorPresentationInterests
        _ = try await f.stream.receive(f.encode(request)) { response in
            let decoded = try f.decode(response)
            #expect(decoded.authorPresentationInterestsReceived == expected)
            #expect(await f.dispatcher.visibleSubscriptions(for: f.author).count == 1)
        }
        gate.allowed.withLock { $0 = false }
        request.requestID = 5; request.authorPresentationInterests.sequence = 2
        let denied = try await f.stream.receive(f.encode(request))
        #expect(try f.decode(#require(denied.first)).error.code == "RATE_LIMITED")
        request.requestID = 6; request.authorPresentationInterests.sequence = 3
        request.authorPresentationInterests.keys = []
        let cleared = try await f.stream.receive(f.encode(request))
        #expect(try f.decode(#require(cleared.first)).authorPresentationInterestsReceived.keys.isEmpty)
        #expect(await f.dispatcher.visibleSubscriptions(for: f.author).isEmpty)
        #expect(f.commands.count == 1)
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("malformed, foreign and server-only interest frames cannot register watchers", arguments: 0...5)
    func invalidInterests(mode: Int) async throws {
        let f = try Fixture()
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let stream = try #require(await f.login())
        var request = IMV2Envelope(); request.requestID = 3
        request.authorPresentationInterests.streamID = (mode == 0 ? UUID() : stream).uuidString
        request.authorPresentationInterests.viewID = mode == 1 ? "invalid" : UUID().uuidString
        request.authorPresentationInterests.sequence = mode == 2 ? 0 : 1
        request.authorPresentationInterests.keys = [profileWireKey(user: f.author, room: f.room)]
        if mode == 3 { request.authorPresentationInterests.keys.append(profileWireKey(user: f.author, room: f.room)) }
        if mode == 4 { request.authorPresentationInterests.keys = (0..<129).map { _ in profileWireKey(user: .init(uuid: UUID()), room: f.room) } }
        if mode == 5 { request.authorPresentationInterestsReceived = request.authorPresentationInterests }
        await #expect(throws: (any Error).self) { _ = try await f.stream.receive(f.encode(request)) }
        #expect(await f.dispatcher.statistics().visibleInterests == 0)
        #expect(f.commands.count == 0)
        await f.dispatcher.close()
    }
    @Test("Owner accepted and complete edited bodies offer authors only while membership remains valid",
          arguments: [false, true], [false, true])
    func ownerBodyAuthorSupplement(direct: Bool, edited: Bool) async throws {
        let f = try Fixture(withIngress: true), bodies = Mutex(0), supplements = Mutex(0)
        let authority = V2GatewayRoomSubscriptionAuthority()
        let ownerIngress = try await f.configureRoomIngress(authority: authority)
        let transport = try await V2GatewayForegroundChannelFixture(record: { _ in bodies.withLock { $0 += 1 } })
        defer { transport.finish() }
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: transport.writer, authorPresentationWriter: { write in
                await transport.writeAuthor(write) { supplements.withLock { $0 += 1 } }
            }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        let fence = try await f.installOwnerBaseline(ownerIngress)
        let event: V2DirectRoomLiveEvent
        if edited {
            event = try .init(roomID: f.room, highWatermark: 2, sourceEventID: .init(uuid: UUID()),
                roomSequence: 2, projectionKind: "message",
                payload: AuthorPresentationMessageFixtures.edited(room: f.room, author: f.author),
                recipientUserIDs: direct ? [f.user, f.author] : [], groupMembershipRevision: direct ? nil : 0)
        } else { event = try direct ? f.directEvent(recipients: [f.user, f.author]) : f.groupEvent(revision: 0) }
        let body = V2RealtimeRoomEvent(roomID: f.room, highWatermark: event.highWatermark,
            sourceEventID: event.sourceEventID, roomSequence: event.roomSequence, projectionKind: event.projectionKind,
            payload: event.payload, recipientUserIDs: event.recipientUserIDs,
            groupMembershipRevision: event.groupMembershipRevision)
        #expect(await ownerIngress.applyRoomSubscription(.init(fence: fence, deliverySequence: 2,
            authorizationSequence: 1, payload: .event(body, members: [.init(userID: f.user, memberRevision: 0)])), authenticatedServiceID: "owner",
            sourceShardID: "rooms") == .appliedThrough(2))
        try await wait { supplements.withLock { $0 == 1 } }
        #expect(bodies.withLock { $0 == 1 })
        #expect(f.reads.count == 1)
        #expect(await ownerIngress.applyRoomSubscription(.init(fence: fence, deliverySequence: 3,
            authorizationSequence: 2, payload: .revoke(userID: f.user, memberRevision: 0)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(3))
        let next = event.roomSequence + 1
        let late = V2RealtimeRoomEvent(roomID: f.room, highWatermark: next,
            sourceEventID: EventID(uuid: UUID()), roomSequence: next, projectionKind: body.projectionKind,
            payload: try JSONSerialization.data(withJSONObject: ["event_type": "message.accepted",
                "room_id": f.room.rawValue, "room_sequence": next, "sender_user_id": f.author.rawValue]),
            recipientUserIDs: body.recipientUserIDs,
            groupMembershipRevision: body.groupMembershipRevision)
        #expect(await ownerIngress.applyRoomSubscription(.init(fence: fence, deliverySequence: 4,
            authorizationSequence: 2, payload: .event(late, members: [.init(userID: f.user, memberRevision: 0)])), authenticatedServiceID: "owner",
            sourceShardID: "rooms") == .appliedThrough(4))
        #expect(bodies.withLock { $0 == 1 })
        #expect(f.reads.count == 1)
        try await f.stream.finish(); await f.registry.shutdownRealtimeRecovery(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("authorized ordinary and prepared attachment pages write their body before a bounded author supplement", arguments: [false, true])
    func pageAuthorsFollowBody(prepared: Bool) async throws {
        let users = (0..<80).map { _ in UserID(uuid: UUID()) }, output = Mutex<[Data]>([])
        let f = try Fixture(withIngress: true, preparedPages: prepared, page: { request in
            try authorPage(room: request.roomID, users: [users[0]] + users)
        })
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { write in
            write.enqueueIfCurrent { output.withLock { $0.append(write.bytes) } }
        }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        _ = try await f.stream.receive(f.pull()) { bytes in
            let page = try f.decode(bytes).groupEventPage
            #expect(page.events.count == 81)
            #expect(f.reads.count == 0)
            #expect(output.withLock { $0.isEmpty })
        }
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        let frame = try #require(output.withLock { $0.first })
        let delta = try V2AuthorPresentationDelta.decode(f.decode(frame).authorPresentationDelta.payload)
        #expect(Set(delta.batch.results.map { $0.key.userID }) == Set(users.prefix(8)))
        #expect(f.reads.count == 1)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("ordinary and prepared recovery pages supplement a full edit without its original accepted event", arguments: [false, true])
    func editedPageAuthorsFollowBody(prepared: Bool) async throws {
        let author = UserID(uuid: UUID()), output = Mutex<[Data]>([])
        let f = try Fixture(withIngress: true, preparedPages: prepared, page: { request in
            var response = IMV2Envelope(); response.groupEventPage.roomID = request.roomID
            response.groupEventPage.nextRoomSequence = 2
            var event = IMV2GroupEvent(); event.sourceEventID = UUID().uuidString
            event.roomSequence = 2; event.projectionKind = "message"
            event.payload = try AuthorPresentationMessageFixtures.edited(room: RoomID(request.roomID), author: author)
            response.groupEventPage.events = [event]
            return response
        })
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { write in
            write.enqueueIfCurrent { output.withLock { $0.append(write.bytes) } }
        }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        _ = try await f.stream.receive(f.pull()) { bytes in
            let page = try f.decode(bytes).groupEventPage
            #expect(page.events.count == 1 && page.events.first?.roomSequence == 2)
            #expect(f.reads.count == 0 && output.withLock { $0.isEmpty })
        }
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        let frame = try #require(output.withLock { $0.first })
        let delta = try V2AuthorPresentationDelta.decode(f.decode(frame).authorPresentationDelta.payload)
        #expect(delta.batch.results.map(\.key) == [.init(userID: author, context: .room(f.room))])
        #expect(f.reads.count == 1)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("latest-visible recovery supplements only selected rooms after its response is written")
    func latestVisibleAuthorsFollowBody() async throws {
        let author = UserID(uuid: UUID()), extraRooms = (0..<99).map { _ in RoomID(uuid: UUID()) }
        let output = Mutex<[Data]>([])
        let f = try Fixture(withIngress: true, latest: { request in authorLatestPage(rooms: request.roomIds, author: author) })
        let selected = [f.room] + Array(extraRooms.prefix(7))
        // Selected rooms at the end must not be lost behind off-screen rooms.
        let requested = Array(extraRooms.dropFirst(7)) + selected
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { write in
            write.enqueueIfCurrent { output.withLock { $0.append(write.bytes) } }
        }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID(), messageRooms: selected))
        _ = try await f.stream.receive(f.latest(rooms: requested)) { bytes in
            let page = try f.decode(bytes).roomLatestVisibleBatchResult
            #expect(page.rooms.count == 100)
            #expect(f.reads.count == 0 && output.withLock { $0.isEmpty })
        }
        let expected = Set(selected.map { V2ProfileViewLookupKey(userID: author, context: .room($0)) })
        func receivedKeys() throws -> [V2ProfileViewLookupKey] {
            try output.withLock { $0 }.flatMap { bytes in
                try V2AuthorPresentationDelta.decode(f.decode(bytes).authorPresentationDelta.payload).batch.results.map(\.key)
            }
        }
        try await wait { (try? Set(receivedKeys())) == expected }
        #expect(try receivedKeys().count == 8)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("latest-visible recovery cannot cross a replacement view during reading or writing", arguments: [false, true])
    func latestVisibleCannotCrossView(writing: Bool) async throws {
        let held = HeldIngress(), author = UserID(uuid: UUID())
        let f = try Fixture(withIngress: true, latest: { request in
            if !writing { await held.hold() }
            return authorLatestPage(rooms: request.roomIds, author: author)
        })
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        let pull = Task { try await f.stream.receive(f.latest(rooms: [f.room])) { _ in if writing { await held.hold() } } }
        try await wait { await held.waiting }
        _ = try await f.stream.receive(f.subscribe(UUID()))
        await held.release(); _ = try await pull.value
        #expect(f.reads.count == 0 && f.ingress?.statistics().retainedKeys == 0)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("ineligible, deferred, malformed and unwritten latest-visible results produce no author reads", arguments: 0...14)
    func latestVisibleAdmission(mode: Int) async throws {
        let author = UserID(uuid: UUID())
        let f = try Fixture(withIngress: true, latest: { request in
            if mode == 2 { var denied = IMV2Envelope(); denied.error.code = "FORBIDDEN"; return denied }
            var response = authorLatestPage(rooms: request.roomIds, author: author)
            switch mode {
            case 3: response.roomLatestVisibleBatchResult.rooms[0].roomID = UUID().uuidString
            case 5: response.roomLatestVisibleBatchResult.rooms[0].unavailable = .init()
            case 6: response.roomLatestVisibleBatchResult.rooms[0].retry.retryAfterSeconds = 1
            case 7: response.roomLatestVisibleBatchResult.rooms[0].snapshot.clearLatest()
            case 8: response.roomLatestVisibleBatchResult.rooms[0].snapshot.latest.senderUserID = "invalid"
            case 9: response.roomLatestVisibleBatchResult.rooms[0].snapshot.latest.roomSequence = 11
            case 10: response.roomLatestVisibleBatchResult.rooms.append(response.roomLatestVisibleBatchResult.rooms[0])
            case 11: response.roomLatestVisibleBatchResult.rooms[0].snapshot.ownerEpoch = UInt64.max
            case 12: response.roomLatestVisibleBatchResult.rooms[0].snapshot.latest.messageRevision = 0
            case 13: response.roomLatestVisibleBatchResult.rooms[0].snapshot.latest.messageID = "invalid"
            default: break
            }
            return response
        })
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        _ = try await f.login(offered: mode != 0)
        if mode >= 2 { _ = try await f.stream.receive(f.subscribe(UUID())) }
        do {
            let room = mode == 14 ? RoomID(uuid: UUID()) : f.room
            _ = try await f.stream.receive(f.latest(rooms: [room])) { _ in if mode == 4 { throw WaitExpired() } }
            #expect(mode != 4)
        } catch { #expect(mode == 4) }
        #expect(f.reads.count == 0 && f.ingress?.statistics().retainedKeys == 0)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("a page cannot cross a replacement view while its handler or response writer is suspended", arguments: [false, true])
    func pageCannotCrossView(writing: Bool) async throws {
        let held = HeldIngress(), user = UserID(uuid: UUID())
        let f = try Fixture(withIngress: true, page: { request in
            if !writing { await held.hold() }
            return try authorPage(room: request.roomID, users: [user])
        })
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        let pull = Task { try await f.stream.receive(f.pull()) { _ in if writing { await held.hold() } } }
        try await wait { await held.waiting }
        _ = try await f.stream.receive(f.subscribe(UUID()))
        await held.release(); _ = try await pull.value
        #expect(f.reads.count == 0)
        #expect(f.ingress?.statistics().retainedKeys == 0)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("unselected, denied, other-room and failed-write pages create no author work", arguments: 0...4)
    func pageAdmission(mode: Int) async throws {
        let user = UserID(uuid: UUID())
        let f = try Fixture(withIngress: true, page: { request in
            if mode == 2 { var denied = IMV2Envelope(); denied.error.code = "FORBIDDEN"; return denied }
            return try authorPage(room: mode == 3 ? UUID().uuidString : request.roomID, users: [user])
        })
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        _ = try await f.login(offered: mode != 0)
        if mode >= 2 { _ = try await f.stream.receive(f.subscribe(UUID())) }
        do {
            _ = try await f.stream.receive(f.pull()) { _ in if mode == 4 { throw WaitExpired() } }
            #expect(mode != 4)
        } catch { #expect(mode == 4) }
        #expect(f.reads.count == 0)
        #expect(f.ingress?.statistics().retainedKeys == 0)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("exhausting optional author registrations preserves authentication, room subscribe and heartbeat")
    func optionalRegistrationCapacity() async throws {
        let first = try Fixture(maximumAuthorConnections: 1)
        let second = try Fixture(sharedDispatcher: first.dispatcher)
        for f in [first, second] {
            #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
            #expect(try await f.login() != nil)
            let response = try await f.stream.receive(f.subscribe(UUID()))
            #expect(try f.decode(#require(response.first)).groupEventSubscribed.roomID == f.room.rawValue)
            if f.connectionID == second.connectionID {
                let unavailable = try f.decode(#require(response.last)).error
                #expect(unavailable.code == "AUTHOR_PRESENTATION_UNAVAILABLE" && unavailable.retryable)
            } else {
                #expect(try f.decode(#require(response.last)).authorPresentationStarted.viewID.isEmpty == false)
            }
        }
        #expect(await first.dispatcher.statistics().connections == 1)
        #expect(!(await first.dispatcher.offer(connectionID: second.connectionID, roomID: second.room, authors: [second.author])))
        var heartbeat = IMV2Envelope(); heartbeat.requestID = 4; heartbeat.heartbeat = .init()
        let response = try await second.stream.receive(second.encode(heartbeat))
        #expect(try second.decode(#require(response.first)).heartbeatAck.serverTimeMs > 0)
        try await first.stream.finish(); try await second.stream.finish()
        await first.dispatcher.close()
    }

    @Test("ingress installation is startup-only, once-only, and rejects an already closed owner")
    func startupIngressInstallation() async throws {
        let f = try Fixture(withIngress: true), ingress = try #require(f.ingress)
        await #expect(throws: V2ResourceProviderError.configurationInvalid) {
            try await f.registry.installAuthorPresentationIngress(ingress)
        }
        let ordinary = try Fixture()
        #expect(await ordinary.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }))
        _ = try await ordinary.login(offered: false)
        try await ordinary.stream.finish()
        await #expect(throws: V2ResourceProviderError.configurationInvalid) {
            try await ordinary.registry.installAuthorPresentationIngress(ingress)
        }
        let fresh = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        try await fresh.installAuthorPresentationIngress(ingress)
        await ingress.close()
        let late = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        await #expect(throws: V2ResourceProviderError.configurationInvalid) { try await late.installAuthorPresentationIngress(ingress) }
        await ordinary.dispatcher.close(); await f.dispatcher.close()
    }

    @Test("actual NIO author writes wait for no body backlog even after the socket becomes writable", arguments: [false, true])
    func nioBodyBacklog(direct: Bool) async throws {
        let f = try Fixture(withIngress: true), channel = NIOAsyncTestingChannel()
        let owner = try await f.configureRoomIngress(authority: V2GatewayRoomSubscriptionAuthority())
        try await channel.testingEventLoop.executeInContext {
            let handler = try V2NIOGatewayChannelHandler(stream: f.stream,
                maximumQueuedInboundBytes: 65_536, maximumQueuedInboundChunks: 4,
                authenticationTimeoutMilliseconds: 60_000, idleTimeoutMilliseconds: 60_000,
                transportMetrics: V2GatewayTransportMetrics())
            try channel.pipeline.syncOperations.addHandler(handler)
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        do {
            try await wait { await f.stream.supportsRequiredNotifications() }
            _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
            let fence = try await f.installOwnerBaseline(owner)
            let event = try direct ? f.directEvent(recipients: [f.user, f.author]) : f.groupEvent(revision: 0)
            let prepared = try #require(direct
                ? V2PreparedGatewayGroupEventAvailable(roomID: f.room, highWatermark: 1, directEvent: event, frameLimits: f.limits)
                : V2PreparedGatewayGroupEventAvailable(groupEvents: [event], frameLimits: f.limits))
            let bodyWriter = try #require(f.stream.prepareNIOGroupEventAvailable(prepared)).writer
            channel.isWritable = false
            #expect(await owner.applyRoomSubscription(.init(fence: fence, deliverySequence: 2, authorizationSequence: 1,
                payload: .event(V2RealtimeRoomEvent(event), members: [.init(userID: f.user, memberRevision: 0)])),
                authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
            try await wait { await f.dispatcher.statistics().reading == 0 && f.reads.count == 1 }
            try await wait { f.dispatcher.readDiagnostics.snapshot().outcomes[.writeDeferred, default: 0] > 0 }
            try await channel.testingEventLoop.executeInContext {}
            #expect(bodyWriter.hasPendingFrames)
            let deferred = f.dispatcher.readDiagnostics.snapshot().outcomes[.writeDeferred, default: 0]
            channel.isWritable = true
            // Do not resume the FIFO yet. A writable socket alone is insufficient
            // for a retry to overtake the body, or to trigger another authority read.
            try await wait { f.dispatcher.readDiagnostics.snapshot().outcomes[.writeDeferred, default: 0] > deferred }
            #expect(await f.reads.count == 1)
            #expect(await f.dispatcher.statistics().deliveredFrames == 0)
            #expect(await f.dispatcher.statistics().outputBytes > 0)
            #expect(try await f.readBusinessOutbound(channel) == nil)
            #expect(channel.isActive)
            bodyWriter.resumeAfterWritabilityChange()
            try await wait { !bodyWriter.hasPendingFrames }
            try await channel.testingEventLoop.executeInContext {}
            let body = try #require(await f.readBusinessOutbound(channel))
            let notification = try f.decode(Data(body.readableBytesView)).groupEventAvailable
            #expect(!notification.eventPayload.isEmpty)
            #expect(notification.highWatermark == 1)
            try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
            #expect(await f.reads.count == 1)
            let authors = try #require(await f.readBusinessOutbound(channel))
            #expect(try f.decode(Data(authors.readableBytesView)).authorPresentationDelta.payload.isEmpty == false)
        } catch {
            try? await f.stream.finish(); await f.registry.shutdownRealtimeRecovery(); await f.ingress?.close(); await f.dispatcher.close()
            _ = try? await channel.finish(); throw error
        }
        try await f.stream.finish(); await f.registry.shutdownRealtimeRecovery(); await f.ingress?.close(); await f.dispatcher.close()
        _ = try await channel.finish()
    }

    @Test("authorized committed group delivery hands off author hints after the shared body")
    func committedGroupDelivery() async throws {
        let f = try Fixture(withIngress: true), order = Mutex<[String]>([])
        let owner = try await f.configureRoomIngress(authority: V2GatewayRoomSubscriptionAuthority())
        let transport = try await V2GatewayForegroundChannelFixture(record: { _ in order.withLock { $0.append("body") } })
        defer { transport.finish() }
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: transport.writer, authorPresentationWriter: { write in
                await transport.writeAuthor(write) { order.withLock { $0.append("author") } }
            }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        let fence = try await f.installOwnerBaseline(owner)
        // The Owner's recipient membership must match the installed tenure.
        // A stale recipient cannot offer either body or author work.
        #expect(await owner.applyRoomSubscription(.init(fence: fence, deliverySequence: 2, authorizationSequence: 1,
            payload: .event(V2RealtimeRoomEvent(try f.groupEvent(revision: 1)),
                members: [.init(userID: f.user, memberRevision: 1)])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        #expect(order.withLock { $0.isEmpty })
        #expect(f.ingress?.statistics().retainedKeys == 0)
        let event = V2RealtimeRoomEvent(roomID: f.room, highWatermark: 2,
            sourceEventID: EventID(uuid: UUID()), roomSequence: 2, projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: ["event_type": "message.accepted",
                "room_id": f.room.rawValue, "room_sequence": 2, "sender_user_id": f.author.rawValue]),
            recipientUserIDs: [], groupMembershipRevision: 0)
        #expect(await owner.applyRoomSubscription(.init(fence: fence, deliverySequence: 3, authorizationSequence: 1,
            payload: .event(event, members: [.init(userID: f.user, memberRevision: 0)])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(3))
        transport.drain()
        #expect(order.withLock { $0.first } == "body")
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        #expect(order.withLock { $0 } == ["body", "author"])
        #expect(f.reads.count == 1)
        try await f.stream.finish(); await f.registry.shutdownRealtimeRecovery(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("committed nickname events invalidate visible authors through the owned Gateway ingress without a new message")
    func committedNicknameDelivery() async throws {
        let f = try Fixture(withIngress: true)
        let owner = try await f.configureRoomIngress(authority: V2GatewayRoomSubscriptionAuthority())
        let transport = try await V2GatewayForegroundChannelFixture(record: { _ in })
        defer { transport.finish() }
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: transport.writer, authorPresentationWriter: { write in await transport.writeAuthor(write) {} }))
        let streamID = try #require(await f.login()), viewID = UUID()
        _ = try await f.stream.receive(f.subscribe(viewID))
        let fence = try await f.installOwnerBaseline(owner)
        try await wait { f.ingress?.statistics().pendingRoomResets == 0 && f.ingress?.statistics().activeConsumers == 0 }
        #expect(await f.dispatcher.replaceVisibleInterests(connectionID: f.connectionID,
            interests: try .init(streamID: streamID, viewID: viewID, roomID: f.room, sequence: 1, userIDs: [f.author])))
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        await f.dispatcher.acknowledge(connectionID: f.connectionID, receipt: try .init(streamID: streamID,
            viewID: viewID, roomID: f.room, sequence: 1, userIDs: [f.author]))
        let event = V2RealtimeRoomEvent(roomID: f.room, highWatermark: 1, sourceEventID: .init(uuid: UUID()),
            roomSequence: 1, projectionKind: "group_capability",
            payload: try JSONSerialization.data(withJSONObject: ["event_type": "group.nickname_changed",
                "room_id": f.room.rawValue, "room_sequence": 1, "target_user_id": f.author.rawValue, "revision": 2]),
            recipientUserIDs: [], groupMembershipRevision: 0)
        let update = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 2, authorizationSequence: 1,
            payload: .event(event, members: [.init(userID: f.user, memberRevision: 0)]))
        #expect(await owner.applyRoomSubscription(update, authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        try await wait { f.ingress?.statistics().pendingChanges == 0 && f.ingress?.statistics().activeConsumers == 0 }
        // Production's owned source worker performs this bounded retry tick.
        await f.dispatcher.retryVisibleProfiles()
        transport.drain()
        try await wait { await f.dispatcher.statistics().deliveredFrames == 2 }
        #expect(f.reads.count == 2)
        await f.dispatcher.acknowledge(connectionID: f.connectionID, receipt: try .init(streamID: streamID,
            viewID: viewID, roomID: f.room, sequence: 2, userIDs: [f.author]))
        // Replayed source delivery cannot manufacture another content version.
        #expect(await owner.applyRoomSubscription(update, authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        #expect(f.reads.count == 2)
        try await f.stream.finish(); await f.registry.shutdownRealtimeRecovery(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("Owner direct delivery offers authors only for exact recipients and non-excluded devices")
    func committedDirectDelivery() async throws {
        let f = try Fixture(withIngress: true), order = Mutex<[String]>([])
        let owner = try await f.configureRoomIngress(authority: V2GatewayRoomSubscriptionAuthority())
        let transport = try await V2GatewayForegroundChannelFixture(record: { _ in order.withLock { $0.append("body") } })
        defer { transport.finish() }
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: transport.writer, authorPresentationWriter: { write in
                await transport.writeAuthor(write) { order.withLock { $0.append("author") } }
            }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        let fence = try await f.installOwnerBaseline(owner)
        func deliver(_ sequence: UInt64, recipients: Set<UserID>, excluded: UUID? = nil) async throws {
            let event = V2RealtimeRoomEvent(roomID: f.room, highWatermark: sequence,
                sourceEventID: EventID(uuid: UUID()), roomSequence: sequence, projectionKind: "message",
                payload: try JSONSerialization.data(withJSONObject: ["event_type": "message.accepted",
                    "room_id": f.room.rawValue, "room_sequence": sequence, "sender_user_id": f.author.rawValue]),
                recipientUserIDs: recipients, excludedConnectionID: excluded)
            #expect(await owner.applyRoomSubscription(.init(fence: fence, deliverySequence: sequence + 1,
                authorizationSequence: 1, payload: .event(event, members: [.init(userID: f.user, memberRevision: 0)])),
                authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(sequence + 1))
        }
        try await deliver(1, recipients: [f.author])
        try await deliver(2, recipients: [f.user, f.author], excluded: f.connectionID)
        #expect(order.withLock { $0.isEmpty })
        #expect(f.reads.count == 0)
        #expect(f.ingress?.statistics().retainedKeys == 0)
        try await deliver(3, recipients: [f.user, f.author])
        transport.drain()
        #expect(order.withLock { $0.first } == "body")
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        #expect(order.withLock { $0 } == ["body", "author"])
        #expect(f.reads.count == 1)
        try await f.stream.finish(); await f.registry.shutdownRealtimeRecovery(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("async transport completes prepared and ordinary bodies before optional author work", arguments: [false, true])
    func asyncTransportBodyOrdering(prepared: Bool) async throws {
        let f = try Fixture(withIngress: true), order = Mutex<[String]>([])
        let attached = await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { bytes in
            if let envelope = try? f.decode(bytes), case .groupEventAvailable = envelope.body {
                #expect(envelope.groupEventAvailable.roomSequence == 1)
                order.withLock { $0.append("body") }
            }
        }, authorPresentationWriter: { write in
            write.enqueueIfCurrent { order.withLock { $0.append("author") } }
        })
        #expect(attached)
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        let event = try f.directEvent(recipients: [f.user, f.author])
        let accepted: Bool
        if prepared {
            let frame = try #require(V2PreparedGatewayGroupEventAvailable(roomID: f.room,
                highWatermark: 1, directEvent: event, frameLimits: f.limits))
            accepted = await f.stream.sendGroupEventAvailable(frame)
        } else {
            accepted = await f.stream.sendGroupEventAvailable(roomID: f.room, highWatermark: 1, directEvent: event)
        }
        #expect(accepted)
        #expect(order.withLock { $0 } == ["body"])
        f.stream.offerAuthorPresentation(try #require(V2AuthorPresentationHints(directEvent: event)),
            to: try #require(f.ingress))
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        #expect(order.withLock { $0 } == ["body", "author"])
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("a saturated optional ingress neither waits nor rejects shared body delivery", arguments: [false, true])
    func ingressCannotBlockBody(direct: Bool) async throws {
        let held = HeldIngress()
        let ingress = V2AuthorPresentationIngress(configuration: try .init(maximumOffers: 1), consume: held.consume)
        #expect(ingress.submit(connectionID: UUID(), roomID: RoomID(uuid: UUID()), viewID: UUID(), authors: [UserID(uuid: UUID())]))
        try await wait { await held.waiting }
        let f = try Fixture(providedIngress: ingress), bodies = Mutex(0)
        let owner = try await f.configureRoomIngress(authority: V2GatewayRoomSubscriptionAuthority())
        let transport = try await V2GatewayForegroundChannelFixture(record: { _ in bodies.withLock { $0 += 1 } })
        defer { transport.finish() }
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: transport.writer, authorPresentationWriter: { _ in false }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        let fence = try await f.installOwnerBaseline(owner)
        let event = try direct ? f.directEvent(recipients: [f.user, f.author]) : f.groupEvent(revision: 0)
        #expect(await owner.applyRoomSubscription(.init(fence: fence, deliverySequence: 2, authorizationSequence: 1,
            payload: .event(V2RealtimeRoomEvent(event), members: [.init(userID: f.user, memberRevision: 0)])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        transport.drain()
        #expect(bodies.withLock { $0 } == 1)
        // The baseline reset and the message hint both hit the same held
        // capacity; the reset survives as a fixed-size recovery obligation.
        #expect(ingress.statistics().rejected == 2 && ingress.statistics().resetPending)
        #expect(ingress.statistics().activeConsumers == 1)
        #expect(f.reads.count == 0)
        await held.release(); try await f.stream.finish(); await f.registry.shutdownRealtimeRecovery()
        await ingress.close(); await f.dispatcher.close()
    }

    @Test("receipt is scoped to an authenticated stream and requires no domain query")
    func receiptContract() async throws {
        let gate = SwitchAdmission(), f = try Fixture(admission: gate)
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let stream = try #require(await f.login()), view = UUID()
        _ = try await f.stream.receive(f.subscribe(view))
        gate.allowed.withLock { $0 = false }
        var request = IMV2Envelope(); request.requestID = 4
        request.authorPresentationReceipt.streamID = stream.uuidString
        request.authorPresentationReceipt.viewID = view.uuidString
        request.authorPresentationReceipt.minimumRemainingMilliseconds = 120_000
        request.authorPresentationReceipt.sequence = 1
        request.authorPresentationReceipt.keys = [profileWireKey(user: f.author, room: f.room)]
        let frames = try await f.stream.receive(f.encode(request))
        #expect(try f.decode(#require(frames.first)).authorPresentationReceipted == request.authorPresentationReceipt)
        #expect(f.commands.count == 1)
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("foreign, malformed and wrong-direction receipts are rejected", arguments: 0...7)
    func invalidReceipt(mode: Int) async throws {
        let f = try Fixture()
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let stream = try #require(await f.login())
        var request = IMV2Envelope(); request.requestID = 3
        request.authorPresentationReceipt.streamID = (mode == 0 ? UUID() : stream).uuidString
        request.authorPresentationReceipt.viewID = mode == 1 ? "invalid" : UUID().uuidString
        request.authorPresentationReceipt.minimumRemainingMilliseconds = 120_000
        request.authorPresentationReceipt.sequence = mode == 2 ? 0 : 1
        request.authorPresentationReceipt.keys = mode == 3 ? [] : [profileWireKey(user: f.author, room: f.room)]
        if mode == 4 { request.authorPresentationReceipt.keys.append(profileWireKey(user: f.author, room: f.room)) }
        if mode == 6 { request.authorPresentationReceipt.clearMinimumRemainingMilliseconds() }
        if mode == 7 { request.authorPresentationReceipt.minimumRemainingMilliseconds = .max }
        if mode == 5 { request.authorPresentationReceipted = request.authorPresentationReceipt }
        await #expect(throws: (any Error).self) { _ = try await f.stream.receive(f.encode(request)) }
        #expect(f.commands.count == 0)
        await f.dispatcher.close()
    }

    @Test("exact nonce cleanup bypasses domain admission and preserves the room subscription")
    func conditionalStop() async throws {
        let gate = SwitchAdmission(), f = try Fixture(admission: gate)
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let streamID = try #require(await f.login()), old = UUID(), current = UUID()
        _ = try await f.stream.receive(f.subscribe(old))
        _ = try await f.stream.receive(f.subscribe(current))
        #expect(await f.registry.activeForegroundGroupMetrics().viewers == 1)
        gate.allowed.withLock { $0 = false }
        for nonce in [old, UUID()] {
            _ = try await f.stream.receive(f.end(streamID, view: nonce))
            #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        }
        _ = try await f.stream.receive(f.end(streamID, view: current)) { bytes in
            let ended = try f.decode(bytes).authorPresentationEnded
            #expect(ended.streamID == streamID.uuidString)
            #expect(ended.viewID == current.uuidString)
            #expect(!(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author])))
        }
        // Repeated cleanup is a harmless acknowledgement, including after all
        // ordinary command tokens are exhausted. No room owner is called.
        _ = try await f.stream.receive(f.end(streamID, view: current))
        #expect(f.commands.count == 2)
        #expect(await f.registry.activeForegroundGroupMetrics().viewers == 1)
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("unnegotiated, foreign, malformed and wrong-direction end frames are rejected", arguments: [0, 1, 2, 3, 4])
    func invalidStop(mode: Int) async throws {
        let f = try Fixture()
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let stream = try await f.login(offered: mode != 0)
        var request = IMV2Envelope(); request.requestID = 3
        request.authorPresentationEnd.streamID = (mode == 1 ? UUID() : stream ?? UUID()).uuidString
        if mode == 2 { request.authorPresentationEnd.streamID = "bad" }
        request.authorPresentationEnd.viewID = mode == 3 ? "bad" : UUID().uuidString
        if mode == 4 { request.authorPresentationEnded = .init() }
        await #expect(throws: V2GatewaySessionError.unsupportedCommand) { _ = try await f.stream.receive(f.encode(request)) }
        #expect(f.commands.count == 0)
        await f.dispatcher.close()
    }

    @Test("capability requires both peers, authenticated UUID device and current wire", arguments: [false, true])
    func negotiation(offered: Bool) async throws {
        let f = try Fixture()
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let streamID = try await f.login(offered: offered)
        #expect((streamID != nil) == offered)
        #expect(await f.dispatcher.statistics().connections == (offered ? 1 : 0))
        try await f.stream.finish()
        #expect(await f.session.authenticatedAuthorPresentationStreamID() == nil)
        #expect(await f.dispatcher.statistics().connections == 0)
        await f.dispatcher.close()
    }

    @Test("subscription echo is written before author work and leaving clears pending delivery")
    func authorizedSubscriptionLifecycle() async throws {
        let f = try Fixture(), delivered = Mutex<[Data]>([])
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { write in
            write.enqueueIfCurrent { delivered.withLock { $0.append(write.bytes) } }
        }))
        let streamID = try #require(await f.login())
        let viewID = UUID()
        let subscribe = try f.subscribe(viewID)
        _ = try await f.stream.receive(subscribe) { response in
            let envelope = try f.decode(response)
            if case .authorPresentationStarted(let started) = envelope.body {
                #expect(started.viewID == viewID.uuidString)
            } else { #expect(envelope.groupEventSubscribed.roomID == f.room.rawValue) }
            #expect(!(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author])))
        }
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        let bytes = try #require(delivered.withLock { $0.first })
        let envelope = try f.decode(bytes)
        #expect(envelope.requestID == 0)
        let delta = try V2AuthorPresentationDelta.decode(envelope.authorPresentationDelta.payload)
        #expect(delta.streamID == streamID && delta.viewID == viewID && delta.actorUserID == f.user)
        _ = try await f.stream.receive(f.end(streamID, view: viewID))
        #expect(!(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author])))
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("late optional writes retain their slot until actual completion and cannot survive replacement, stop or disconnect", arguments: [0, 1, 2])
    func lateWrite(mode: Int) async throws {
        let f = try Fixture(), held = HeldWrite()
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: held.send))
        let streamID = try #require(await f.login()), viewID = UUID()
        _ = try await f.stream.receive(f.subscribe(viewID))
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        try await wait { await held.pending }
        if mode == 0 { try await f.stream.finish() }
        else if mode == 2 { _ = try await f.stream.receive(f.end(streamID, view: viewID)) }
        else {
            _ = try await f.stream.receive(f.subscribe(UUID()))
        }
        #expect(await f.dispatcher.statistics().writing == 1)
        await held.release()
        try await wait { await f.dispatcher.statistics().writing == 0 }
        #expect(await held.enqueued == false)
        #expect(await f.dispatcher.statistics().deliveredFrames == 0)
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("starting a view does not read profiles or override a denied room subscription")
    func deniedSubscription() async throws {
        let f = try Fixture(deny: true)
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        _ = try await f.login()
        let response = try await f.stream.receive(f.subscribe(UUID()))
        #expect(try f.decode(#require(response.first)).error.code == "FORBIDDEN")
        guard case .authorPresentationStarted = try f.decode(#require(response.last)).body else {
            Issue.record("independent profile view did not start"); return
        }
        #expect(f.reads.count == 0)
        #expect(f.commands.count == 1)
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("ordinary room subscriptions and unsubscriptions preserve another room's selected author view")
    func independentRooms() async throws {
        let f = try Fixture()
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        _ = try await f.login()
        _ = try await f.stream.receive(f.subscribe(UUID()))
        let other = RoomID(uuid: UUID())
        var ordinary = IMV2Envelope(); ordinary.requestID = 4
        ordinary.groupEventSubscribe.roomID = other.rawValue
        _ = try await f.stream.receive(f.encode(ordinary))
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        var leave = IMV2Envelope(); leave.requestID = 5; leave.groupEventUnsubscribe.roomID = other.rawValue
        _ = try await f.stream.receive(f.encode(leave))
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        ordinary.requestID = 6; ordinary.groupEventSubscribe.roomID = f.room.rawValue.lowercased()
        _ = try await f.stream.receive(f.encode(ordinary))
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("unnegotiated nonces and client-origin author frames never reach the domain", arguments: [false, true])
    func wrongDirection(authorFrame: Bool) async throws {
        let f = try Fixture()
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }))
        _ = try await f.login(offered: false)
        let data: Data
        if authorFrame {
            var envelope = IMV2Envelope(); envelope.requestID = 3; envelope.authorPresentationDelta.payload = Data([1])
            data = try f.encode(envelope)
        } else { data = try f.subscribe(UUID()) }
        await #expect(throws: V2GatewaySessionError.unsupportedCommand) { _ = try await f.stream.receive(data) }
        #expect(f.reads.count == 0)
        await f.dispatcher.close()
    }

    @Test("NIO optional writes drop congestion without closing a healthy channel", arguments: [false, true])
    func nioOptionalWrite(congested: Bool) async throws {
        let f = try Fixture(), channel = NIOAsyncTestingChannel()
        try await channel.testingEventLoop.executeInContext {
            let handler = try V2NIOGatewayChannelHandler(stream: f.stream,
                maximumQueuedInboundBytes: 65_536, maximumQueuedInboundChunks: 4,
                authenticationTimeoutMilliseconds: 60_000, idleTimeoutMilliseconds: 60_000,
                transportMetrics: V2GatewayTransportMetrics())
            try channel.pipeline.syncOperations.addHandler(handler)
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        try await wait { await f.stream.supportsRequiredNotifications() }
        _ = try await f.login()
        _ = try await f.stream.receive(f.subscribe(UUID()))
        channel.isWritable = !congested
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        try await wait {
            let stats = await f.dispatcher.statistics()
            return f.reads.count == 1 && stats.reading == 0 && stats.writing == 0 && stats.outputBytes == 0
        }
        #expect(channel.isActive)
        let output = try await f.readBusinessOutbound(channel)
        #expect((output == nil) == congested)
        if let output { #expect(try f.decode(Data(output.readableBytesView)).authorPresentationDelta.payload.isEmpty == false) }
        _ = try await channel.finish(acceptAlreadyClosed: true)
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("enqueue permission is single-use, deadline bounded and invalidated by page replacement")
    func actualEnqueueFence() throws {
        let transport = V2AuthorPresentationTransport(), view = UUID(), count = Mutex(0)
        transport.activate(viewID: view)
        let preparedFirst = transport.prepare(bytes: Data([1]), viewID: view, deadline: .now + .seconds(1), sessionIsLive: { true })
        let first = try #require(preparedFirst)
        #expect(first.enqueueIfCurrent { count.withLock { $0 += 1 } })
        #expect(!first.enqueueIfCurrent { count.withLock { $0 += 1 } })
        let preparedLate = transport.prepare(bytes: Data([1]), viewID: view, deadline: .now + .seconds(1), sessionIsLive: { true })
        let late = try #require(preparedLate)
        transport.activate(viewID: UUID())
        #expect(!late.enqueueIfCurrent { count.withLock { $0 += 1 } })
        transport.activate(viewID: view)
        #expect(!late.enqueueIfCurrent { count.withLock { $0 += 1 } }) // same nonce cannot revive old generation
        for live in [false, true] {
            let prepared = transport.prepare(bytes: Data([1]), viewID: view,
                deadline: live ? .now : .now + .seconds(1), sessionIsLive: { live })
            let write = try #require(prepared)
            #expect(!write.enqueueIfCurrent { count.withLock { $0 += 1 } })
        }
        let preparedCancelled = transport.prepare(bytes: Data([1]), viewID: view, deadline: .now + .seconds(1), sessionIsLive: { true })
        let cancelled = try #require(preparedCancelled)
        cancelled.cancel()
        #expect(!cancelled.enqueueIfCurrent { count.withLock { $0 += 1 } })
        #expect(count.withLock { $0 } == 1)
        #expect(transport.prepare(bytes: Data(repeating: 0, count: V2AuthorPresentationDelta.maximumFrameBytes + 1),
            viewID: view, deadline: .now + .seconds(1), sessionIsLive: { true }) == nil)
    }

    @Test("author frame preparation validates the selected view together with the authenticated identity")
    func frameViewBinding() async throws {
        let f = try Fixture()
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let streamID = try #require(await f.login())
        let delta = try V2AuthorPresentationDelta(streamID: streamID, viewID: UUID(), sequence: 1,
            actorUserID: f.user, deviceID: f.device, roomID: f.room,
            batch: .init(serverNowUnixMilliseconds: 1, results: [.unavailable(.init(userID: f.author, context: .room(f.room)))]))
        let bytes = try delta.encoded()
        #expect(try await f.session.authorPresentationFrame(bytes, viewID: delta.viewID) != nil)
        await #expect(throws: V2GatewaySessionError.self) {
            _ = try await f.session.authorPresentationFrame(bytes, viewID: UUID())
        }
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("complete envelope budget and authenticated recipient are independently enforced")
    func frameBudget() async throws {
        let f = try Fixture(payloadLimit: 400)
        #expect(await f.stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let streamID = try #require(await f.login())
        let delta = try V2AuthorPresentationDelta(streamID: streamID, viewID: UUID(), sequence: 1,
            actorUserID: f.user, deviceID: f.device, roomID: f.room,
            batch: .init(serverNowUnixMilliseconds: 1, results: [.unavailable(.init(userID: f.author, context: .room(f.room)))]))
        await #expect(throws: (any Error).self) { _ = try await f.session.authorPresentationFrame(delta.encoded(), viewID: delta.viewID) }
        try await f.stream.finish()
        #expect(try await f.session.authorPresentationFrame(delta.encoded(), viewID: delta.viewID) == nil)
        await f.dispatcher.close()
    }
}

private final class Fixture: Sendable {
    let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
    let connectionID = UUID(), reads = ReadCounter(), commands = ReadCounter()
    let registry: V2DeviceConnectionRegistry
    let ingress: V2AuthorPresentationIngress?
    let session: V2GatewaySession, stream: V2GatewayByteStream, dispatcher: V2AuthorPresentationDispatcher
    let limits: V2FrameLimits
    private let roomIngressConfigured = Mutex(false)
    private let negotiatedStream = Mutex<UUID?>(nil)
    init(deny: Bool = false, payloadLimit: Int = 65_536,
         withIngress: Bool = false, providedIngress: V2AuthorPresentationIngress? = nil,
         preparedPages: Bool = false,
         page: (@Sendable (IMV2GroupEventPull) async throws -> IMV2Envelope)? = nil,
         latest: (@Sendable (IMV2RoomLatestVisibleBatch) async throws -> IMV2Envelope)? = nil,
         maximumAuthorConnections: Int = 10_000, sharedDispatcher: V2AuthorPresentationDispatcher? = nil,
         admission: any V2AuthenticatedGatewayCommandAdmitting = V2AllowingGatewayCommandAdmission()) throws {
        limits = try .init(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        session = .init(limits: try .init(maximumInFlightRequests: 4), authenticator: Auth(user: user),
            capabilityProfile: "base", maximumUncompressedPayloadBytes: payloadLimit,
            preparedGroupEventPageCache: preparedPages ? .init(configuration: .init(maximumEntries: 8, maximumBytes: 262_144, shardCount: 1)) : nil,
            supportsAuthorPresentationDelta: true, commandAdmission: admission)
        dispatcher = try sharedDispatcher ?? .init(configuration: .init(maximumConnections: maximumAuthorConnections, mergeDelay: .zero), read: { [reads] request, _ in
            reads.increment()
            return try .init(serverNowUnixMilliseconds: 1, results: request.keys.map { .unavailable($0) })
        })
        ingress = try providedIngress ?? (withIngress ? .init(configuration: .init(), dispatcher: dispatcher) : nil)
        registry = .init(foregroundFrameLimits: limits, authorPresentationIngress: ingress)
        let handler = Handler(deny: deny, commands: commands, page: page, latest: latest, registry: registry, connectionID: connectionID)
        stream = .init(frameLimits: limits, session: session, handler: handler, connectionID: connectionID,
                       registry: registry, authorPresentationDispatcher: dispatcher, authorPresentationIngress: ingress)
        handler.bind(stream)
    }
    func installOwnerBaseline(_ ingress: V2GatewayRoomSubscriptionIngress) async throws -> V2RoomSubscriptionFence {
        let fence = V2RoomSubscriptionFence(activation: .init(roomID: room,
            owner: try .init(shardID: "rooms", epoch: 0), activationEpoch: try .init(1),
            host: .init(hostID: try .init("author-owner"), incarnationID: UUID())),
            subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        try #require(await ingress.installTestSession(fence: fence, sourceShardID: "rooms", serviceID: "owner"))
        #expect(await ingress.applyRoomSubscription(.init(fence: fence, deliverySequence: 1, authorizationSequence: 1,
            payload: .baseline(members: [.init(userID: user, memberRevision: 0)])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
        return fence
    }
    func encode(_ value: IMV2Envelope, version: UInt8 = UInt8(IMV2ProtocolVersion.current)) throws -> Data {
        var envelope = value
        if version != 0 { envelope.protocolVersion = UInt32(version) }
        return try V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version), limits: limits)
    }
    func decode(_ bytes: Data) throws -> IMV2Envelope {
        var decoder = V2FrameDecoder(limits: limits)
        return try V2ServerProtobufFrameCodec.decode(#require(decoder.append(bytes).first))
    }
    // Authenticated coverage controls share the NIO FIFO with business frames.
    // Ignore only that explicit control kind; unexpected business output remains
    // visible to the body-ordering and optional-congestion assertions.
    func readBusinessOutbound(_ channel: NIOAsyncTestingChannel) async throws -> ByteBuffer? {
        while let output = try await channel.readOutbound(as: ByteBuffer.self) {
            let envelope = try decode(Data(output.readableBytesView))
            if case .realtimeCoverage = envelope.body { continue }
            return output
        }
        return nil
    }
    func configureRoomIngress(authority: V2GatewayRoomSubscriptionAuthority) async throws -> V2GatewayRoomSubscriptionIngress {
        let ingress = try await registry.configureRoomSubscriptionIngress(authority: authority)
        roomIngressConfigured.withLock { $0 = true }
        return ingress
    }
    func login(offered: Bool = true) async throws -> UUID? {
        if !roomIngressConfigured.withLock({ $0 }) {
            _ = try await configureRoomIngress(authority: .init())
        }
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.supportedProtocolVersions = [IMV2ProtocolVersion.current]
        hello.clientHello.supportedCapabilityProfiles = ["base"]; hello.clientHello.deviceID = device.rawValue
        hello.clientHello.supportsAuthorPresentationDelta = offered
        let first = try await stream.receive(encode(hello, version: 0))
        let selected = try decode(#require(first.first)).serverHello.authorPresentationStreamID
        var auth = IMV2Envelope(); auth.requestID = 2; auth.authenticate.accessToken = "test"; auth.authenticate.deviceID = device.rawValue
        let second = try await stream.receive(encode(auth))
        #expect(try decode(#require(second.first)).authenticated.authorPresentationStreamID == selected)
        let result = UUID(uuidString: selected)
        negotiatedStream.withLock { $0 = result }
        return result
    }
    func subscribe(_ view: UUID, messageRooms: [RoomID]? = nil) throws -> Data {
        let stream = negotiatedStream.withLock { $0 }
        var start = IMV2Envelope(); start.requestID = 3
        start.authorPresentationStart.streamID = (stream ?? UUID()).uuidString
        start.authorPresentationStart.viewID = view.uuidString
        start.authorPresentationStart.messageRoomIds = (messageRooms ?? [room]).map(\.rawValue)
        // Existing body-delivery fixtures need both independent subscriptions.
        // An unnegotiated start is tested alone, without any domain command.
        guard stream != nil else { return try encode(start) }
        var roomRequest = IMV2Envelope(); roomRequest.requestID = 10
        roomRequest.groupEventSubscribe.roomID = room.rawValue
        var bytes = try encode(roomRequest); bytes.append(try encode(start)); return bytes
    }
    func pull() throws -> Data {
        var envelope = IMV2Envelope(); envelope.requestID = 11
        envelope.groupEventPull.roomID = room.rawValue; envelope.groupEventPull.pageSize = 100
        return try encode(envelope)
    }
    func latest(rooms: [RoomID]) throws -> Data {
        var envelope = IMV2Envelope(); envelope.requestID = 12
        envelope.roomLatestVisibleBatch.roomIds = rooms.map(\.rawValue)
        return try encode(envelope)
    }
    func end(_ stream: UUID, view: UUID) throws -> Data {
        var request = IMV2Envelope(); request.requestID = 4
        request.authorPresentationEnd.streamID = stream.uuidString
        request.authorPresentationEnd.viewID = view.uuidString
        return try encode(request)
    }
    func directEvent(recipients: Set<UserID>, excluded: UUID? = nil) throws -> V2DirectRoomLiveEvent {
        let payload = try JSONSerialization.data(withJSONObject: ["event_type": "message.accepted",
            "room_id": room.rawValue, "room_sequence": 1, "sender_user_id": author.rawValue])
        return .init(roomID: room, highWatermark: 1, sourceEventID: EventID(uuid: UUID()), roomSequence: 1,
            projectionKind: "message", payload: payload, recipientUserIDs: recipients, excludedConnectionID: excluded)
    }
    func groupEvent(revision: UInt64) throws -> V2DirectRoomLiveEvent {
        let payload = try JSONSerialization.data(withJSONObject: ["event_type": "message.accepted",
            "room_id": room.rawValue, "room_sequence": 1, "sender_user_id": author.rawValue])
        return .init(roomID: room, highWatermark: 1, sourceEventID: EventID(uuid: UUID()), roomSequence: 1,
            projectionKind: "message", payload: payload, recipientUserIDs: [], groupMembershipRevision: revision)
    }
}
private actor HeldIngress {
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func consume(_ offer: V2AuthorPresentationIngress.Offer) async { await withCheckedContinuation { continuation = $0 } }
    func hold() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private struct Auth: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication { .init(userID: user, expiresAt: nil) }
}
private final class Handler: V2GatewayCommandHandler, V2PreparedGroupEventCommandHandling, Sendable {
    let deny: Bool
    let commands: ReadCounter
    let page: (@Sendable (IMV2GroupEventPull) async throws -> IMV2Envelope)?
    let latest: (@Sendable (IMV2RoomLatestVisibleBatch) async throws -> IMV2Envelope)?
    let registry: V2DeviceConnectionRegistry
    let connectionID: UUID
    private struct Connection: Sendable { weak var stream: V2GatewayByteStream? }
    private let connection = Mutex(Connection())
    init(deny: Bool, commands: ReadCounter,
         page: (@Sendable (IMV2GroupEventPull) async throws -> IMV2Envelope)?,
         latest: (@Sendable (IMV2RoomLatestVisibleBatch) async throws -> IMV2Envelope)?,
         registry: V2DeviceConnectionRegistry, connectionID: UUID) {
        self.deny = deny; self.commands = commands; self.page = page; self.latest = latest
        self.registry = registry; self.connectionID = connectionID
    }
    func bind(_ stream: V2GatewayByteStream) { connection.withLock { $0.stream = stream } }
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        commands.increment()
        var response = IMV2Envelope()
        switch envelope.body {
        case .groupEventSubscribe(let request):
            if deny { response.error.code = "FORBIDDEN" }
            else {
                // Author-only fixtures establish room interest at the Registry before acknowledging.
                let stream = try #require(connection.withLock { $0.stream })
                _ = try await registry.subscribeForegroundRoom(stream, connectionID: connectionID,
                    roomID: try RoomID(request.roomID))
                response.groupEventSubscribed.roomID = request.roomID
            }
        case .groupEventPull(let request):
            if let page { return try await page(request) }
        case .roomLatestVisibleBatch(let request):
            if let latest { return try await latest(request) }
        default: response.acknowledged = .init()
        }
        return response
    }
    func handlePreparedGroupEventPull(_ request: IMV2GroupEventPull, identity: V2AuthenticatedConnection,
        originatingConnectionID: UUID?, context: V2PreparedGroupEventCommandContext) async throws -> V2PreparedGroupEventGatewayResponse {
        guard let page else { throw WaitExpired() }
        var response = try await page(request)
        response.requestID = context.requestID; response.protocolVersion = UInt32(context.frameVersion)
        guard case .groupEventPage(let value) = response.body else { return .envelope(response) }
        let frame = try #require(try context.cache.frame(for: response, frameVersion: context.frameVersion,
            compression: context.compression, maximumUncompressedPayloadBytes: context.maximumUncompressedPayloadBytes,
            compressionThresholdBytes: context.compressionThresholdBytes, maximumExpansionRatio: context.maximumExpansionRatio))
        return .prepared(.init(frame: frame, roomID: try RoomID(value.roomID), nextRoomSequence: value.nextRoomSequence,
            hasMore: value.hasMore_p, authorSample: context.captureAuthorSample ? .init(page: value) : nil))
    }
}
private func authorLatestPage(rooms: [String], author: UserID) -> IMV2Envelope {
    var response = IMV2Envelope()
    response.roomLatestVisibleBatchResult.rooms = rooms.map { room in
        var item = IMV2RoomLatestVisibleResult(); item.roomID = room
        item.snapshot.ownerEpoch = 1; item.snapshot.viewerMembershipRevision = 1; item.snapshot.head = 10
        item.snapshot.latest.messageID = UUID().uuidString; item.snapshot.latest.senderUserID = author.rawValue
        item.snapshot.latest.roomSequence = 7; item.snapshot.latest.messageRevision = 2
        item.snapshot.latest.preview = "recovered message"; item.snapshot.latest.createdAtMs = 1_000
        return item
    }
    return response
}
private func authorPage(room: String, users: [UserID]) throws -> IMV2Envelope {
    var response = IMV2Envelope(); response.groupEventPage.roomID = room
    response.groupEventPage.nextRoomSequence = UInt64(users.count)
    response.groupEventPage.events = try users.enumerated().map { offset, user in
        var event = IMV2GroupEvent(); event.sourceEventID = UUID().uuidString
        event.roomSequence = UInt64(offset + 1); event.projectionKind = "message"
        event.payload = try JSONSerialization.data(withJSONObject: ["event_type": "message.accepted", "room_id": room,
            "room_sequence": offset + 1, "sender_user_id": user.rawValue,
            "media_ids": [UUID().uuidString], "reply_to_message_id": UUID().uuidString])
        return event
    }
    return response
}
private final class SwitchAdmission: V2AuthenticatedGatewayCommandAdmitting {
    let allowed = Mutex(true)
    func admit(identity: V2AuthenticatedConnection, cost: Int, now: Date) async -> Bool { allowed.withLock { $0 } }
}
private func wait(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard .now < deadline else { throw WaitExpired() }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private struct WaitExpired: Error {}

private final class ReadCounter: Sendable {
    let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

private actor HeldWrite {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var enqueued = false
    var pending: Bool { continuation != nil }
    func send(_ write: V2AuthorPresentationWrite) async -> Bool {
        await withCheckedContinuation { continuation = $0 }
        enqueued = write.enqueueIfCurrent {}
        return enqueued
    }
    func release() { continuation?.resume(); continuation = nil }
}

private func profileWireKey(user: UserID, room: RoomID) -> IMV2ProfilePresentationKey {
    var key = IMV2ProfilePresentationKey(); key.userID = user.rawValue; key.roomID = room.rawValue; return key
}
