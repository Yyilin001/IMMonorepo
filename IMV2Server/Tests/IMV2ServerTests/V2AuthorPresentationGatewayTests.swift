import Foundation
import IMV2Core
import NIOCore
import NIOEmbedded
import Synchronization
@testable import IMV2Server
import Testing

@Suite("Negotiated author supplements through Gateway", .timeLimit(.minutes(1)))
struct V2AuthorPresentationGatewayTests {
    @Test("authorized ordinary and prepared attachment pages write their body before a bounded author supplement", arguments: [false, true])
    func pageAuthorsFollowBody(prepared: Bool) async throws {
        let users = (0..<80).map { _ in UserID(uuid: UUID()) }, output = Mutex<[Data]>([])
        let f = try Fixture(withIngress: true, preparedPages: prepared, page: { request in
            try authorPage(room: request.roomID, users: [users[0]] + users)
        })
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { write in
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

    @Test("a page cannot cross a replacement view while its handler or response writer is suspended", arguments: [false, true])
    func pageCannotCrossView(writing: Bool) async throws {
        let held = HeldIngress(), user = UserID(uuid: UUID())
        let f = try Fixture(withIngress: true, page: { request in
            if !writing { await held.hold() }
            return try authorPage(room: request.roomID, users: [user])
        })
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
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
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
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
            #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
            #expect(try await f.login() != nil)
            let response = try await f.stream.receive(f.subscribe(UUID()))
            #expect(try f.decode(#require(response.first)).groupEventSubscribed.roomID == f.room.rawValue)
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
        #expect(await ordinary.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }))
        _ = try await ordinary.login(offered: false)
        try await ordinary.stream.finish()
        await #expect(throws: V2ResourceProviderError.configurationInvalid) {
            try await ordinary.registry.installAuthorPresentationIngress(ingress)
        }
        let fresh = V2DeviceConnectionRegistry()
        try await fresh.installAuthorPresentationIngress(ingress)
        await ingress.close()
        let late = V2DeviceConnectionRegistry()
        await #expect(throws: V2ResourceProviderError.configurationInvalid) { try await late.installAuthorPresentationIngress(ingress) }
        await ordinary.dispatcher.close(); await f.dispatcher.close()
    }

    @Test("actual NIO author writes wait for no body backlog even after the socket becomes writable", arguments: [false, true])
    func nioBodyBacklog(direct: Bool) async throws {
        let f = try Fixture(withIngress: true), channel = NIOAsyncTestingChannel()
        try await channel.testingEventLoop.executeInContext {
            let handler = try V2NIOGatewayChannelHandler(stream: f.stream,
                maximumQueuedInboundBytes: 65_536, maximumQueuedInboundChunks: 4,
                authenticationTimeoutMilliseconds: 60_000, idleTimeoutMilliseconds: 60_000,
                transportMetrics: V2GatewayTransportMetrics())
            try channel.pipeline.syncOperations.addHandler(handler)
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        try await wait { await f.stream.supportsRequiredNotifications() }
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        let event = try direct ? f.directEvent(recipients: [f.user, f.author]) : f.groupEvent(revision: 0)
        let prepared = try #require(direct
            ? V2PreparedGatewayGroupEventAvailable(roomID: f.room, highWatermark: 1, directEvent: event, frameLimits: f.limits)
            : V2PreparedGatewayGroupEventAvailable(groupEvents: [event], frameLimits: f.limits))
        let bodyWriter = try #require(f.stream.prepareNIOGroupEventAvailable(prepared)).writer
        channel.isWritable = false
        #expect(direct ? f.registry.submitForegroundDirectEvent(event) : f.registry.submitForegroundGroupEvents([event]))
        try await wait { await f.dispatcher.statistics().reading == 0 && f.reads.count == 1 }
        try await wait { await f.dispatcher.statistics().writing == 0 }
        try await channel.testingEventLoop.executeInContext {}
        #expect(bodyWriter.hasPendingFrames)
        channel.isWritable = true
        // Do not resume the FIFO yet. A writable socket alone is insufficient
        // for the optional path to overtake an already authorized body.
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        try await wait { await f.dispatcher.statistics().reading == 0 && f.reads.count == 2 }
        try await wait { await f.dispatcher.statistics().writing == 0 }
        #expect(await f.dispatcher.statistics().deliveredFrames == 0)
        #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
        #expect(channel.isActive)
        bodyWriter.resumeAfterWritabilityChange()
        try await wait { !bodyWriter.hasPendingFrames }
        try await channel.testingEventLoop.executeInContext {}
        let body = try #require(await channel.readOutbound(as: ByteBuffer.self))
        let notification = try f.decode(Data(body.readableBytesView)).groupEventAvailable
        #expect(direct ? !notification.eventPayload.isEmpty : notification.liveEvents.count == 1)
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        let authors = try #require(await channel.readOutbound(as: ByteBuffer.self))
        #expect(try f.decode(Data(authors.readableBytesView)).authorPresentationDelta.payload.isEmpty == false)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
        _ = try await channel.finish()
    }

    @Test("authorized committed group delivery hands off author hints after the shared body", arguments: [false, true])
    func committedGroupDelivery(synchronous: Bool) async throws {
        let f = try Fixture(withIngress: true), order = Mutex<[String]>([])
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: { _ in order.withLock { $0.append("body") } }, authorPresentationWriter: { write in
                write.enqueueIfCurrent { order.withLock { $0.append("author") } }
            }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        // The connection subscribed at revision 0; another commit revision is
        // neither a body recipient nor an author-hint recipient.
        #expect(f.registry.submitForegroundGroupEvents([try f.groupEvent(revision: 1)]))
        #expect(order.withLock { $0.isEmpty })
        #expect(f.ingress?.statistics().retainedKeys == 0)
        let event = try f.groupEvent(revision: 0)
        if synchronous { #expect(f.registry.submitForegroundGroupEvents([event])) }
        else { await f.registry.notifyForegroundGroupEvents([event]) }
        #expect(order.withLock { $0.first } == "body")
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        #expect(order.withLock { $0 } == ["body", "author"])
        #expect(f.reads.count == 1)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("direct author supplements follow body submission and exact recipient selection", arguments: ["fast", "async-prepared", "async-unprepared"])
    func committedDirectDelivery(path: String) async throws {
        let f = try Fixture(withIngress: true, preparedForeground: path != "async-unprepared")
        let order = Mutex<[String]>([])
        let writer: @Sendable (Data) async -> Void = { bytes in
            if let envelope = try? f.decode(bytes), case .groupEventAvailable = envelope.body {
                order.withLock { $0.append("body") }
            }
        }
        if path == "fast" {
            #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: writer,
                foregroundWriter: { _ in order.withLock { $0.append("body") } }, authorPresentationWriter: { write in
                    write.enqueueIfCurrent { order.withLock { $0.append("author") } }
                }))
        } else {
            #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: writer,
                authorPresentationWriter: { write in write.enqueueIfCurrent { order.withLock { $0.append("author") } } }))
        }
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        func deliver(_ event: V2DirectRoomLiveEvent) async {
            if path == "fast" { #expect(f.registry.submitForegroundDirectEvent(event)) }
            else { await f.registry.notifyForegroundDirectEvent(event) }
        }
        await deliver(try f.directEvent(recipients: [f.author]))
        await deliver(try f.directEvent(recipients: [f.user, f.author], excluded: f.connectionID))
        #expect(order.withLock { $0.isEmpty })
        #expect(f.reads.count == 0)
        #expect(f.ingress?.statistics().retainedKeys == 0)
        await deliver(try f.directEvent(recipients: [f.user, f.author]))
        #expect(order.withLock { $0.first } == "body")
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        #expect(order.withLock { $0 } == ["body", "author"])
        #expect(f.reads.count == 1)
        try await f.stream.finish(); await f.ingress?.close(); await f.dispatcher.close()
    }

    @Test("a saturated optional ingress neither waits nor rejects shared body delivery", arguments: [false, true])
    func ingressCannotBlockBody(direct: Bool) async throws {
        let held = HeldIngress()
        let ingress = V2AuthorPresentationIngress(configuration: try .init(maximumOffers: 1), consume: held.consume)
        #expect(ingress.submit(connectionID: UUID(), roomID: RoomID(uuid: UUID()), viewID: UUID(), authors: [UserID(uuid: UUID())]))
        try await wait { await held.waiting }
        let f = try Fixture(providedIngress: ingress), bodies = Mutex(0)
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: { _ in bodies.withLock { $0 += 1 } }, authorPresentationWriter: { _ in false }))
        _ = try await f.login(); _ = try await f.stream.receive(f.subscribe(UUID()))
        let event = try direct ? f.directEvent(recipients: [f.user, f.author]) : f.groupEvent(revision: 0)
        #expect(direct ? f.registry.submitForegroundDirectEvent(event) : f.registry.submitForegroundGroupEvents([event]))
        #expect(bodies.withLock { $0 } == 1)
        #expect(ingress.statistics().rejected == 1)
        #expect(ingress.statistics().activeConsumers == 1)
        #expect(f.reads.count == 0)
        await held.release(); try await f.stream.finish()
        await ingress.close(); await f.dispatcher.close()
    }

    @Test("exact nonce cleanup bypasses domain admission and preserves the room subscription")
    func conditionalStop() async throws {
        let gate = SwitchAdmission(), f = try Fixture(admission: gate)
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let streamID = try #require(await f.login()), old = UUID(), current = UUID()
        _ = try await f.stream.receive(f.subscribe(old))
        _ = try await f.stream.receive(f.subscribe(current))
        #expect(await f.registry.activeForegroundGroupMetrics().viewers == 1)
        gate.allowed.withLock { $0 = false }
        for (room, nonce) in [(f.room, old), (RoomID(uuid: UUID()), current)] {
            _ = try await f.stream.receive(f.end(streamID, room: room, view: nonce))
            #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        }
        _ = try await f.stream.receive(f.end(streamID, room: f.room, view: current)) { bytes in
            let ended = try f.decode(bytes).authorPresentationEnded
            #expect(ended.streamID == streamID.uuidString)
            #expect(ended.viewID == current.uuidString)
            #expect(!(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author])))
        }
        // Repeated cleanup is a harmless acknowledgement, including after all
        // ordinary command tokens are exhausted. No room owner is called.
        _ = try await f.stream.receive(f.end(streamID, room: f.room, view: current))
        #expect(f.commands.count == 2)
        #expect(await f.registry.activeForegroundGroupMetrics().viewers == 1)
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("unnegotiated, foreign, malformed and wrong-direction end frames are rejected", arguments: [0, 1, 2, 3, 4])
    func invalidStop(mode: Int) async throws {
        let f = try Fixture()
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let stream = try await f.login(offered: mode != 0)
        var request = IMV2Envelope(); request.requestID = 3
        request.authorPresentationEnd.streamID = (mode == 1 ? UUID() : stream ?? UUID()).uuidString
        request.authorPresentationEnd.roomID = mode == 2 ? "bad" : f.room.rawValue
        request.authorPresentationEnd.viewID = mode == 3 ? "bad" : UUID().uuidString
        if mode == 4 { request.authorPresentationEnded = .init() }
        await #expect(throws: V2GatewaySessionError.unsupportedCommand) { _ = try await f.stream.receive(f.encode(request)) }
        #expect(f.commands.count == 0)
        await f.dispatcher.close()
    }

    @Test("capability requires both peers, authenticated UUID device and current wire", arguments: [false, true])
    func negotiation(offered: Bool) async throws {
        let f = try Fixture()
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
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
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { write in
            write.enqueueIfCurrent { delivered.withLock { $0.append(write.bytes) } }
        }))
        let streamID = try #require(await f.login())
        let viewID = UUID()
        let subscribe = try f.subscribe(viewID)
        _ = try await f.stream.receive(subscribe) { response in
            let envelope = try f.decode(response)
            #expect(envelope.groupEventSubscribed.authorPresentationViewID == viewID.uuidString)
            #expect(!(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author])))
        }
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        try await wait { await f.dispatcher.statistics().deliveredFrames == 1 }
        let bytes = try #require(delivered.withLock { $0.first })
        let envelope = try f.decode(bytes)
        #expect(envelope.requestID == 0)
        let delta = try V2AuthorPresentationDelta.decode(envelope.authorPresentationDelta.payload)
        #expect(delta.streamID == streamID && delta.viewID == viewID && delta.actorUserID == f.user)
        var leave = IMV2Envelope(); leave.requestID = 4; leave.groupEventUnsubscribe.roomID = f.room.rawValue
        _ = try await f.stream.receive(f.encode(leave))
        #expect(!(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author])))
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("late optional writes retain their slot until actual completion and cannot survive leave, stop or disconnect", arguments: [0, 1, 2])
    func lateWrite(mode: Int) async throws {
        let f = try Fixture(), held = HeldWrite()
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: held.send))
        let streamID = try #require(await f.login()), viewID = UUID()
        _ = try await f.stream.receive(f.subscribe(viewID))
        #expect(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author]))
        try await wait { await held.pending }
        if mode == 0 { try await f.stream.finish() }
        else if mode == 2 { _ = try await f.stream.receive(f.end(streamID, room: f.room, view: viewID)) }
        else {
            var leave = IMV2Envelope(); leave.requestID = 4; leave.groupEventUnsubscribe.roomID = f.room.rawValue.lowercased()
            _ = try await f.stream.receive(f.encode(leave))
        }
        #expect(await f.dispatcher.statistics().writing == 1)
        await held.release()
        try await wait { await f.dispatcher.statistics().writing == 0 }
        #expect(await held.enqueued == false)
        #expect(await f.dispatcher.statistics().deliveredFrames == 0)
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("denied room subscriptions cannot activate author access")
    func deniedSubscription() async throws {
        let f = try Fixture(deny: true)
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        _ = try await f.login()
        let response = try await f.stream.receive(f.subscribe(UUID()))
        #expect(try f.decode(#require(response.first)).error.code == "FORBIDDEN")
        #expect(!(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author])))
        #expect(f.reads.count == 0)
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("ordinary room subscriptions and unsubscriptions preserve another room's selected author view")
    func independentRooms() async throws {
        let f = try Fixture()
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
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
        #expect(!(await f.dispatcher.offer(connectionID: f.connectionID, roomID: f.room, authors: [f.author])))
        try await f.stream.finish(); await f.dispatcher.close()
    }

    @Test("unnegotiated nonces and client-origin author frames never reach the domain", arguments: [false, true])
    func wrongDirection(authorFrame: Bool) async throws {
        let f = try Fixture()
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }))
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
        let output = try await channel.readOutbound(as: ByteBuffer.self)
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

    @Test("complete envelope budget and authenticated recipient are independently enforced")
    func frameBudget() async throws {
        let f = try Fixture(payloadLimit: 400)
        #expect(await f.stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in }, authorPresentationWriter: { _ in false }))
        let streamID = try #require(await f.login())
        let delta = try V2AuthorPresentationDelta(streamID: streamID, viewID: UUID(), sequence: 1,
            actorUserID: f.user, deviceID: f.device, roomID: f.room,
            batch: .init(serverNowUnixMilliseconds: 1, results: [.unavailable(.init(userID: f.author, context: .room(f.room)))]))
        await #expect(throws: (any Error).self) { _ = try await f.session.authorPresentationFrame(delta.encoded()) }
        try await f.stream.finish()
        #expect(try await f.session.authorPresentationFrame(delta.encoded()) == nil)
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
    init(deny: Bool = false, payloadLimit: Int = 65_536,
         withIngress: Bool = false, providedIngress: V2AuthorPresentationIngress? = nil,
         preparedPages: Bool = false, preparedForeground: Bool = true,
         page: (@Sendable (IMV2GroupEventPull) async throws -> IMV2Envelope)? = nil,
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
        registry = .init(foregroundFrameLimits: ingress == nil || !preparedForeground ? nil : limits, authorPresentationIngress: ingress)
        stream = .init(frameLimits: limits, session: session, handler: Handler(deny: deny, commands: commands, page: page), connectionID: connectionID,
                       registry: registry, authorPresentationDispatcher: dispatcher, authorPresentationIngress: ingress)
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
    func login(offered: Bool = true) async throws -> UUID? {
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.supportedProtocolVersions = [IMV2ProtocolVersion.current]
        hello.clientHello.supportedCapabilityProfiles = ["base"]; hello.clientHello.deviceID = device.rawValue
        hello.clientHello.supportsAuthorPresentationDelta = offered
        let first = try await stream.receive(encode(hello, version: 0))
        let selected = try decode(#require(first.first)).serverHello.authorPresentationStreamID
        var auth = IMV2Envelope(); auth.requestID = 2; auth.authenticate.accessToken = "test"; auth.authenticate.deviceID = device.rawValue
        let second = try await stream.receive(encode(auth))
        #expect(try decode(#require(second.first)).authenticated.authorPresentationStreamID == selected)
        return UUID(uuidString: selected)
    }
    func subscribe(_ view: UUID) throws -> Data {
        var envelope = IMV2Envelope(); envelope.requestID = 3; envelope.groupEventSubscribe.roomID = room.rawValue
        envelope.groupEventSubscribe.authorPresentationViewID = view.uuidString
        return try encode(envelope)
    }
    func pull() throws -> Data {
        var envelope = IMV2Envelope(); envelope.requestID = 11
        envelope.groupEventPull.roomID = room.rawValue; envelope.groupEventPull.pageSize = 100
        return try encode(envelope)
    }
    func end(_ stream: UUID, room: RoomID, view: UUID) throws -> Data {
        var request = IMV2Envelope(); request.requestID = 4
        request.authorPresentationEnd.streamID = stream.uuidString
        request.authorPresentationEnd.roomID = room.rawValue.lowercased()
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
private struct Handler: V2GatewayCommandHandler, V2PreparedGroupEventCommandHandling {
    let deny: Bool
    let commands: ReadCounter
    var page: (@Sendable (IMV2GroupEventPull) async throws -> IMV2Envelope)? = nil
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        commands.increment()
        var response = IMV2Envelope()
        switch envelope.body {
        case .groupEventSubscribe(let request):
            if deny { response.error.code = "FORBIDDEN" }
            else { response.groupEventSubscribed.roomID = request.roomID }
        case .groupEventPull(let request):
            if let page { return try await page(request) }
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
