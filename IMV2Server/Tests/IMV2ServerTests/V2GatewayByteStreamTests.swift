@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Compression
import IMV2Core
import NIOCore
import NIOEmbedded
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

struct V2GatewayByteStreamTests {
    @Test("a slow send leaves heartbeat capacity and connection close drains it")
    func concurrentMessageSendDoesNotBlockHeartbeat() async throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let slow = SlowMessageSendCommandHandler()
        let budget = V2GatewayMessageSendBudget(maximumBytes: 4_194_304)
        let stream = V2GatewayByteStream(
            frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 4),
                           authenticator: ByteStreamAuthFake(), capabilityProfile: "base",
                           commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: slow, registry: V2DeviceConnectionRegistry(),
            messageSendBudget: budget, maximumConcurrentMessageSends: 1)
        let recorder = ConcurrentGatewayResponseRecorder()
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        hello.clientHello.supportsMessageSendOperations = true
        _ = try await stream.receive(encoded(hello, version: 0))
        var auth = IMV2Envelope()
        auth.requestID = 2
        auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "opaque"
        auth.authenticate.deviceID = hello.clientHello.deviceID
        _ = try await stream.receive(encoded(auth, version: version))
        let room = try RoomID("00000000-0000-0000-0000-000000000A03")
        let user = try UserID("user-a")
        let operation = try V2MessageSendOperationCommand(
            command: .init(roomID: room, senderUserID: user,
                           clientMessageID: .init(uuid: UUID()), text: "slow",
                           limits: .init(maxUTF8Bytes: 64)),
            firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000) + 60_000)
        var send = IMV2Envelope()
        send.requestID = 3
        send.protocolVersion = UInt32(version)
        send.messageSendOperation = try V2MessageSendOperationWireCodec.encode(command: operation)
        let write: @Sendable (V2Frame) async throws -> Void = { frame in await recorder.append(frame) }
        _ = try await stream.receiveFrames(encoded(send, version: version),
                                           concurrentMessageSendRespond: write, respond: write)
        for _ in 0..<10_000 {
            if await slow.started { break }
            await Task.yield()
        }
        #expect(await slow.started)
        var second = send
        second.requestID = 5
        _ = try await stream.receiveFrames(encoded(second, version: version),
                                           concurrentMessageSendRespond: write, respond: write)
        let rejected = try #require(await recorder.all().first)
        let busy = try V2ServerProtobufFrameCodec.decode(rejected)
        #expect(busy.requestID == 5 && busy.error.code == "SERVER_BUSY")
        #expect(busy.error.retryable && busy.error.retryAfterSeconds == 1)
        var heartbeat = IMV2Envelope()
        heartbeat.requestID = 4
        heartbeat.protocolVersion = UInt32(version)
        heartbeat.heartbeat = .init()
        let heartbeatResponse = try await stream.receive(encoded(heartbeat, version: version))
        #expect(try decode(#require(heartbeatResponse.first)).body != nil)
        try await stream.finish()
        #expect(await slow.cancelled)
        #expect(await recorder.count == 1)
        #expect(await budget.inFlightBytes() == 0)
    }
    @Test("NIO required notifications confirm writes or close failed channels", arguments: [0, 1, 2, 3])
    func nioRequiredNotificationWrite(mode: Int) async throws {
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: ByteStreamCommandFake(), registry: V2DeviceConnectionRegistry())
        let channel = NIOAsyncTestingChannel()
        let metrics = V2GatewayTransportMetrics()
        try await channel.testingEventLoop.executeInContext {
            let handler = try V2NIOGatewayChannelHandler(stream: stream, maximumQueuedInboundBytes: 4096,
                maximumQueuedInboundChunks: 4, authenticationTimeoutMilliseconds: 60_000,
                idleTimeoutMilliseconds: 60_000, transportMetrics: metrics)
            try channel.pipeline.syncOperations.addHandler(handler)
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        var ready = false
        for _ in 0..<10_000 {
            if await stream.supportsRequiredNotifications() { ready = true; break }
            await Task.yield()
        }
        #expect(ready)
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(protocolVersion)
        auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(auth, version: protocolVersion))
        if mode == 1 { channel.isWritable = false }
        if mode == 2 {
            try await channel.pipeline.addHandler(RequiredNotificationFailingWriter(), position: .first).get()
        }
        let stalled = RequiredNotificationStallingWriter()
        if mode == 3 {
            try await channel.pipeline.addHandler(stalled, position: .first).get()
        }
        let notification = V2AccountRoomNotification.resyncRequired(epoch: UUID())
        let written: Bool
        if mode == 3 {
            let send = Task { await stream.sendAccountRoomNotification(notification) }
            for _ in 0..<10_000 {
                if stalled.hasPending { break }
                await Task.yield()
            }
            #expect(stalled.hasPending)
            await channel.testingEventLoop.advanceTime(by: .seconds(11))
            written = await send.value
        } else { written = await stream.sendAccountRoomNotification(notification) }
        #expect(written == (mode == 0))
        if mode == 0 {
            let buffer = try #require(await channel.readOutbound(as: ByteBuffer.self))
            #expect(try decode(Data(buffer.readableBytesView)).body == notification.envelope().body)
        } else {
            try await channel.closeFuture.get()
            #expect(!channel.isActive)
            let reason: V2GatewayConnectionClosure = switch mode {
            case 1: .requiredNotificationBackpressure
            case 3: .requiredNotificationWriteTimeout
            default: .requestFailure
            }
            let snapshot = await metrics.gatewayTransportMetricsSnapshot()
            #expect(snapshot.closureCount(for: reason) == 1)
            #expect(V2GatewayConnectionClosure.allCases.reduce(UInt64(0)) {
                $0 + snapshot.closureCount(for: $1)
            } == 1)
        }
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    @Test("account notifications require authentication and an acknowledged writer", arguments: [false, true])
    func requiredNotificationWrite(written: Bool) async throws {
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: ByteStreamCommandFake(), registry: V2DeviceConnectionRegistry())
        let recorder = OutboundFrameRecorder()
        #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            requiredNotificationWriter: { bytes in
                await recorder.append(bytes)
                return written
            }))
        let epoch = UUID(), room = RoomID(uuid: UUID())
        let notification = V2AccountRoomNotification.changed(epoch: epoch, sequence: 1, roomID: room, highWatermark: 3)
        #expect(!(await stream.sendAccountRoomNotification(notification)))
        #expect(await recorder.all().isEmpty)
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(protocolVersion)
        auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(auth, version: protocolVersion))
        #expect(await stream.sendAccountRoomNotification(notification) == written)
        let frames = await recorder.all()
        let envelope = try decode(#require(frames.first))
        #expect(envelope.requestID == 0)
        #expect(envelope.accountRoomChanged.connectionEpoch == epoch.uuidString.lowercased())
        #expect(envelope.accountRoomChanged.highWatermark == 3)
        try await stream.finish()
        #expect(!(await stream.supportsRequiredNotifications()))
        #expect(!(await stream.sendAccountRoomNotification(notification)))
        #expect(!(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            requiredNotificationWriter: { _ in true })))
        #expect(await recorder.all().count == 1)
    }

    @Test("subscription responses match canonical UUID identity and preserve opaque spelling", arguments: ["group", "presence"])
    func canonicalSubscriptionIdentity(kind: String) async throws {
        for spelling in ["00000000-0000-0000-0000-abcdef123456", "00000000-0000-0000-0000-ABCDEF123456", "Room-A"] {
            let registry = V2DeviceConnectionRegistry()
            let room = try RoomID(spelling), subject = UserID(uuid: UUID())
            let stream = V2GatewayByteStream(
                frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
                session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(),
                    capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
                handler: CanonicalSubscriptionCommandFake(subject: subject), registry: registry)
            let recorder = OutboundFrameRecorder()
            await stream.setOutboundWriter { await recorder.append($0) }
            var hello = IMV2Envelope(); hello.requestID = 1
            hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(encoded(hello, version: 0))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(protocolVersion)
            auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
            _ = try await stream.receive(encoded(auth, version: protocolVersion))
            var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(protocolVersion)
            if kind == "group" { request.groupEventSubscribe.roomID = spelling }
            else { request.subscribePresence.roomID = spelling }
            let responses = try await stream.receive(encoded(request, version: protocolVersion))
            let response = try decode(#require(responses.first))
            #expect(response.requestID == 3)
            #expect((kind == "group" ? response.groupEventSubscribed.roomID : response.presenceSubscribed.roomID) == room.rawValue)
            if kind == "group" {
                await registry.notifyForegroundGroupAvailable(roomID: room, highWatermark: 9)
                if spelling == "Room-A" { await registry.notifyForegroundGroupAvailable(roomID: try .init("room-a"), highWatermark: 10) }
            } else {
                await registry.receivePresence(targetUserID: subject, isOnline: true, expiresAt: Date(timeIntervalSince1970: 1_750_000_006))
            }
            let notifications = await recorder.all()
            #expect(notifications.count == 1)
            let notification = try decode(#require(notifications.first))
            #expect((kind == "group" ? notification.groupEventAvailable.roomID : notification.presenceChanged.roomID) == room.rawValue)
            #expect(await stream.isAuthenticated())
            try await stream.finish()
        }
    }

    @Test("Subscription state changes only after a successful command acknowledgement", arguments: ["subscribe-typing", "unsubscribe-typing", "unsubscribe-presence", "unsubscribe-group"])
    func subscriptionResponseControlsState(kind: String) async throws {
        for hasPriorSubscription in kind == "subscribe-typing" ? [false, true] : [true] {
            let registry = V2DeviceConnectionRegistry(), connectionID = UUID()
            let handler = SubscriptionResponseCommandFake()
            let stream = V2GatewayByteStream(
                frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
                session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(),
                    capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
                handler: handler, connectionID: connectionID, registry: registry)
            let recorder = OutboundFrameRecorder()
            await stream.setOutboundWriter { await recorder.append($0) }
            var hello = IMV2Envelope(); hello.requestID = 1
            hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(encoded(hello, version: 0))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(protocolVersion)
            auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
            _ = try await stream.receive(encoded(auth, version: protocolVersion))
            let oldRoom = RoomID(uuid: UUID()), newRoom = RoomID(uuid: UUID()), subject = UserID(uuid: UUID())
            if hasPriorSubscription {
                switch kind {
                case "unsubscribe-group": await registry.subscribeForegroundGroup(stream, connectionID: connectionID, roomID: oldRoom)
                case "unsubscribe-presence": await registry.subscribePresence(stream, connectionID: connectionID, roomID: oldRoom, targetUserID: subject)
                default: await registry.subscribeTyping(stream, connectionID: connectionID, roomID: oldRoom)
                }
            }
            func publish() async {
                let expiry = Date(timeIntervalSince1970: 1_750_000_006)
                switch kind {
                case "unsubscribe-group":
                    await registry.notifyForegroundGroupAvailable(roomID: oldRoom, highWatermark: 1)
                    await registry.notifyForegroundGroupAvailable(roomID: newRoom, highWatermark: 1)
                case "unsubscribe-presence": await registry.receivePresence(targetUserID: subject, isOnline: true, expiresAt: expiry)
                default:
                    await registry.receiveTyping(.init(roomID: oldRoom, userID: subject, isTyping: true, expiresAt: expiry))
                    await registry.receiveTyping(.init(roomID: newRoom, userID: subject, isTyping: true, expiresAt: expiry))
                }
            }
            var command = IMV2Envelope(); command.requestID = 3; command.protocolVersion = UInt32(protocolVersion)
            switch kind {
            case "subscribe-typing": command.subscribeTyping.roomID = newRoom.rawValue
            case "unsubscribe-typing": command.unsubscribeTyping.roomID = oldRoom.rawValue
            case "unsubscribe-presence": command.unsubscribePresence.roomID = oldRoom.rawValue
            default: command.groupEventUnsubscribe.roomID = oldRoom.rawValue
            }
            var expectedRooms: [String] = []
            for failure in ["UNAVAILABLE", "RATE_LIMITED", "unexpected-response"] {
                await handler.setFailure(failure)
                let responses = try await stream.receive(encoded(command, version: protocolVersion))
                #expect(responses.count == 1)
                let response = try decode(#require(responses.first))
                #expect(response.requestID == command.requestID)
                if failure != "unexpected-response" { #expect(response.error.code == failure); #expect(response.error.retryable) }
                await publish()
                if hasPriorSubscription { expectedRooms.append(oldRoom.rawValue) }
                let rooms = try await recorder.all().map { bytes -> String in
                    let envelope = try decode(bytes)
                    switch kind {
                    case "unsubscribe-group": return envelope.groupEventAvailable.roomID
                    case "unsubscribe-presence": return envelope.presenceChanged.roomID
                    default: return envelope.typingStateChanged.roomID
                    }
                }
                #expect(rooms == expectedRooms)
                #expect(await stream.isAuthenticated())
                command.requestID += 1
            }
            await handler.setFailure(nil)
            let responses = try await stream.receive(encoded(command, version: protocolVersion))
            let response = try decode(#require(responses.first))
            guard case .acknowledged? = response.body else { Issue.record("Expected command acknowledgement"); try await stream.finish(); return }
            await publish()
            if kind == "subscribe-typing" { expectedRooms.append(newRoom.rawValue) }
            #expect(await recorder.count() == expectedRooms.count)
            if kind == "subscribe-typing" {
                let latest = try decode(#require(await recorder.all().last))
                #expect(latest.typingStateChanged.roomID == newRoom.rawValue)
            }
            try await stream.finish()
        }
    }

    @Test("Invalid presence and typing expiry emits no frame and preserves the authenticated stream")
    func notificationTimestampBoundary() async throws {
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(),
                           capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: ByteStreamCommandFake(), registry: V2DeviceConnectionRegistry())
        let recorder = OutboundFrameRecorder()
        await stream.setOutboundWriter { await recorder.append($0) }
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(protocolVersion)
        auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(auth, version: protocolVersion))
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int64.max) / 1_000] {
            let date = Date(timeIntervalSince1970: seconds)
            await stream.sendPresenceState(.init(roomID: room, targetUserID: user, isOnline: true, expiresAt: date))
            await stream.sendTypingState(.init(roomID: room, userID: user, isTyping: true, expiresAt: date))
        }
        #expect(await recorder.count() == 0)
        #expect(await stream.isAuthenticated())
        let date = Date(timeIntervalSince1970: 1_750_000_000.125)
        await stream.sendPresenceState(.init(roomID: room, targetUserID: user, isOnline: true, expiresAt: date))
        await stream.sendTypingState(.init(roomID: room, userID: user, isTyping: false, expiresAt: date))
        let frames = await recorder.all()
        #expect(frames.count == 2)
        let presence = try decode(#require(frames.first)), typing = try decode(#require(frames.last))
        #expect(presence.presenceChanged.expiresAtMs == 1_750_000_000_125)
        #expect(presence.presenceChanged.isOnline)
        #expect(typing.typingStateChanged.expiresAtMs == 1_750_000_000_125)
        #expect(!typing.typingStateChanged.isTyping)
        try await stream.finish()
    }

    @Test("credential rejection is flushed before close; infrastructure errors never revoke client credentials",
          arguments: [V2GatewayAuthenticationError.unauthenticated, .corruptPersistenceState])
    func authenticationFailureWireContract(failure: V2GatewayAuthenticationError) async throws {
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: RejectingByteStreamAuthenticator(failure: failure),
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission()
        )
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: session,
            handler: ByteStreamCommandFake(),
            registry: V2DeviceConnectionRegistry()
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "rejected-opaque-token"
        authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        let bytes = try encoded(authenticate, version: protocolVersion)
        var responses: [Data] = []
        do {
            // A second coalesced request must never execute after rejection.
            _ = try await stream.receive(bytes + bytes) { responses.append($0) }
            Issue.record("Authentication failure must close the stream")
        } catch {
            #expect(error as? V2GatewayAuthenticationError == failure)
        }
        if failure == .unauthenticated {
            #expect(responses.count == 1)
            let response = try decode(#require(responses.first))
            #expect(response.requestID == authenticate.requestID)
            #expect(response.protocolVersion == UInt32(protocolVersion))
            #expect(response.error.code == "UNAUTHENTICATED")
            #expect(!response.error.retryable)
            #expect(response.error.retryAfterSeconds == 0)
            #expect(response.error.currentRevision == 0)
        } else {
            #expect(responses.isEmpty)
        }
        #expect(await !stream.isAuthenticated())
        await #expect(throws: (any Error).self) {
            _ = try await stream.receive(bytes)
        }
    }

    @Test("NIO response encoding is byte-identical to the transport-neutral codec")
    func nioWireEncodingMatchesCoreCodec() throws {
        let limits = try V2FrameLimits(
            maximumPayloadBytes: 4_096,
            acceptedVersions: [0, protocolVersion]
        )
        let frame = V2Frame(
            version: protocolVersion,
            command: .messageAccepted,
            requestID: 0x0102_0304_0506_0708,
            payload: Data([0, 1, 2, 0xfe, 0xff])
        )
        try V2FrameCodec.validateForEncoding(frame, limits: limits)
        let expected = try V2FrameCodec.encode(frame, limits: limits)
        let actual = v2GatewayWireBuffer(frame, allocator: .init())

        #expect(Data(actual.readableBytesView) == expected)
    }

    @Test("transport callbacks cannot be reinstalled after the stream finishes")
    func finishPermanentlyDetachesTransportCallbacks() async throws {
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]),
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: ByteStreamAuthFake(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: ByteStreamCommandFake(),
            registry: V2DeviceConnectionRegistry()
        )
        #expect(await stream.attachTransport(
            deviceRevocationHandler: {}, outboundWriter: { _ in }
        ))

        try await stream.finish()

        #expect(await !stream.attachTransport(
            deviceRevocationHandler: {}, outboundWriter: { _ in }
        ))
    }

    @Test("foreground fast writer is protocol and transport lifecycle fenced")
    func foregroundFastWriterIsLifecycleFenced() async throws {
        let limits = try V2FrameLimits(
            maximumPayloadBytes: 4_096,
            acceptedVersions: [0, protocolVersion]
        )
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: limits)
        let connectionID = UUID()
        let stream = V2GatewayByteStream(
            frameLimits: limits,
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: ByteStreamAuthFake(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: ByteStreamCommandFake(),
            connectionID: connectionID,
            registry: registry
        )
        let fastRecorder = SynchronousFrameRecorder()
        let fallbackRecorder = OutboundFrameRecorder()
        #expect(await stream.attachTransport(
            deviceRevocationHandler: {},
            outboundWriter: { bytes in await fallbackRecorder.append(bytes) },
            foregroundWriter: { bytes in fastRecorder.append(bytes) }
        ))

        let roomID = try RoomID("00000000-0000-0000-0000-000000000cf1")
        let preAuthentication = try #require(V2PreparedGatewayGroupEventAvailable(
            roomID: roomID,
            highWatermark: 1,
            directEvent: nil,
            frameLimits: limits,
            protocolVersion: protocolVersion
        ))
        #expect(!stream.submitGroupEventAvailable(preAuthentication))
        #expect(fastRecorder.count == 0)

        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(authenticate, version: protocolVersion))
        await registry.subscribeForegroundGroup(
            stream,
            connectionID: connectionID,
            roomID: roomID
        )

        await registry.notifyForegroundGroupAvailable(roomID: roomID, highWatermark: 42)
        let fastFrame = try #require(fastRecorder.first)
        #expect(try decode(fastFrame).groupEventAvailable.highWatermark == 42)
        #expect(await fallbackRecorder.count() == 0)

        let direct = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 43,
            sourceEventID: .init("00000000-0000-0000-0000-000000000cf2"),
            roomSequence: 43,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [try .init("user-a")]
        )
        let localPublisher = V2LocalGroupEventWakePublisher(registry: registry)
        #expect(localPublisher.publishForegroundDirectEventImmediately(direct))
        let directFrame = try #require(fastRecorder.element(at: 1))
        #expect(try decode(directFrame).groupEventAvailable.eventPayload == direct.payload)
        #expect(await fallbackRecorder.count() == 0)

        try await stream.finish()
        #expect(!stream.submitGroupEventAvailable(preAuthentication))
        #expect(fastRecorder.count == 2)
    }

    @Test("NIO group batch submission retains authentication and transport lifecycle fences")
    func nioGroupBatchSubmissionIsLifecycleFenced() async throws {
        let limits = try V2FrameLimits(
            maximumPayloadBytes: 4_096,
            acceptedVersions: [0, protocolVersion]
        )
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: limits)
        let connectionID = UUID()
        let stream = V2GatewayByteStream(
            frameLimits: limits,
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: ByteStreamAuthFake(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: ByteStreamCommandFake(),
            connectionID: connectionID,
            registry: registry
        )
        let channel = EmbeddedChannel()
        _ = try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        let writer = V2NIOGatewayForegroundWriter(
            channel: channel,
            scheduler: .init()
        )
        #expect(await stream.attachNIOTransport(
            deviceRevocationHandler: {},
            outboundWriter: { _ in },
            foregroundWriter: writer
        ))

        let roomID = try RoomID("00000000-0000-0000-0000-000000000cf3")
        let prepared = try #require(V2PreparedGatewayGroupEventAvailable(
            roomID: roomID,
            highWatermark: 1,
            directEvent: nil,
            frameLimits: limits,
            protocolVersion: protocolVersion
        ))
        #expect(stream.prepareNIOGroupEventAvailable(prepared) == nil)

        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(authenticate, version: protocolVersion))
        await registry.subscribeForegroundGroup(
            stream,
            connectionID: connectionID,
            roomID: roomID
        )

        let direct = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 2,
            sourceEventID: .init("00000000-0000-0000-0000-000000000cf4"),
            roomSequence: 2,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [try .init("user-a")]
        )
        let publisher = V2LocalGroupEventWakePublisher(registry: registry)
        #expect(publisher.publishForegroundDirectEventImmediately(direct))
        channel.embeddedEventLoop.run()
        let outboundCandidate = try channel.readOutbound(as: ByteBuffer.self)
        let outbound = try #require(outboundCandidate)
        #expect(
            try decode(Data(outbound.readableBytesView))
                .groupEventAvailable.roomSequence == 2
        )

        try await stream.finish()
        #expect(stream.prepareNIOGroupEventAvailable(prepared) == nil)
        writer.finish()
        #expect(try channel.finish().isClean)
    }

    private let protocolVersion = UInt8(IMV2ProtocolVersion.current)

    @Test("fragmented bootstrap and authenticated frames preserve request correlation")
    func fragmentedFrames() async throws {
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(limits: try .init(maximumInFlightRequests: 2), authenticator: ByteStreamAuthFake(), capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission(), now: { Date(timeIntervalSince1970: 0) }),
            handler: ByteStreamCommandFake(),
            registry: V2DeviceConnectionRegistry()
        )

        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        let helloBytes = try V2FrameCodec.encode(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]))
        #expect(try await stream.receive(Data(helloBytes.prefix(5))).isEmpty)
        let helloResponses = try await stream.receive(Data(helloBytes.dropFirst(5)))
        #expect(helloResponses.count == 1)
        #expect(try decode(helloResponses[0]).serverHello.selectedCapabilityProfile == "base")

        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        let authResponses = try await stream.receive(encoded(authenticate, version: protocolVersion))
        #expect(try decode(authResponses[0]).authenticated.selectedCapabilityProfile == "base")

        var heartbeat = IMV2Envelope()
        heartbeat.requestID = 3
        heartbeat.protocolVersion = UInt32(protocolVersion)
        heartbeat.heartbeat = .init()
        heartbeat.heartbeat.clientTimeMs = 123
        let heartbeatResponses = try await stream.receive(encoded(heartbeat, version: protocolVersion))
        let heartbeatAck = try decode(try #require(heartbeatResponses.first))
        #expect(heartbeatAck.requestID == 3)
        #expect(heartbeatAck.heartbeatAck.serverTimeMs == 0)

        var pull = IMV2Envelope()
        pull.requestID = 4
        pull.protocolVersion = UInt32(protocolVersion)
        pull.syncPull = .init()
        let pullResponses = try await stream.receive(encoded(pull, version: protocolVersion))
        let response = try decode(try #require(pullResponses.first))
        #expect(response.requestID == 4)
        #expect(response.error.code == "UNAVAILABLE")
    }

    @Test("authenticated commands carry the exact transport origin")
    func authenticatedCommandsCarryTransportOrigin() async throws {
        let connectionID = UUID()
        let handler = OriginRecordingCommandFake()
        let stream = V2GatewayByteStream(
            frameLimits: try .init(
                maximumPayloadBytes: 4_096,
                acceptedVersions: [0, protocolVersion]
            ),
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: ByteStreamAuthFake(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: handler,
            connectionID: connectionID,
            registry: V2DeviceConnectionRegistry()
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))

        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(authenticate, version: protocolVersion))

        var command = IMV2Envelope()
        command.requestID = 3
        command.protocolVersion = UInt32(protocolVersion)
        command.groupEventUnsubscribe = .init()
        command.groupEventUnsubscribe.roomID = "00000000-0000-0000-0000-000000000cf8"
        _ = try await stream.receive(encoded(command, version: protocolVersion))

        #expect(await handler.origins() == [connectionID])
    }

    @Test("malformed framing closes the connection")
    func malformedFrameClosesSession() async throws {
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 128, acceptedVersions: [0, protocolVersion]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(), capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: ByteStreamCommandFake(),
            registry: V2DeviceConnectionRegistry()
        )
        await #expect(throws: V2FrameCodecError.invalidMagic) {
            try await stream.receive(Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        }
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        await #expect(throws: V2ConnectionStateError.unexpectedCommand) {
            try await stream.receive(encoded(hello, version: 0))
        }
    }

    @Test("declared frame limits are classified separately from generic request failures")
    func classifiesFrameLimitClosures() {
        #expect(v2GatewayClosureReason(for: V2FrameCodecError.declaredPayloadTooLarge(4_097)) == .frameLimitViolation)
        #expect(v2GatewayClosureReason(for: V2FrameCodecError.payloadTooLarge(4_097)) == .frameLimitViolation)
        #expect(v2GatewayClosureReason(for: V2FrameCodecError.tooManyFramesInBatch(257)) == .frameLimitViolation)
        #expect(v2GatewayClosureReason(for: V2FrameCodecError.invalidMagic) == .requestFailure)
    }

    @Test("a dense valid transport read drains in bounded FIFO batches")
    func drainsDenseCoalescedFramesWithoutClosing() async throws {
        let limits = try V2FrameLimits(
            maximumPayloadBytes: 4_096,
            maximumFramesPerAppend: 4,
            acceptedVersions: [0, protocolVersion]
        )
        let stream = V2GatewayByteStream(
            frameLimits: limits,
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: ByteStreamAuthFake(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: ByteStreamCommandFake(),
            registry: V2DeviceConnectionRegistry()
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(authenticate, version: protocolVersion))

        var denseWire = Data()
        for requestID in 3...7 {
            var heartbeat = IMV2Envelope()
            heartbeat.requestID = UInt64(requestID)
            heartbeat.protocolVersion = UInt32(protocolVersion)
            heartbeat.heartbeat = .init()
            denseWire.append(try encoded(heartbeat, version: protocolVersion))
        }
        let recorder = OutboundFrameRecorder()
        #expect(try await stream.receive(denseWire) { bytes in
            await recorder.append(bytes)
        })
        #expect(await recorder.count() == 4)
        #expect(!(try await stream.receive(Data()) { bytes in
            await recorder.append(bytes)
        }))
        let responseBytes = await recorder.all()
        let responseIDs = try responseBytes.map { try decode($0).requestID }
        #expect(responseIDs == [3, 4, 5, 6, 7])
    }

    @Test("availability hints are asynchronous, state-free sync prompts")
    func emitsSyncAvailableForRegisteredUser() async throws {
        let registry = V2DeviceConnectionRegistry()
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(), capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: ByteStreamCommandFake(),
            registry: registry
        )
        let recorder = OutboundFrameRecorder()
        await stream.setOutboundWriter { bytes in
            await recorder.append(bytes)
        }
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(authenticate, version: protocolVersion))
        #expect(await registry.connectionMetricsSnapshot() == .init(activeDevices: 1, activeConnections: 1))

        await registry.notifySyncAvailable(userID: try .init("user-a"), eventID: 12, highWatermark: 48)
        let bytes = try #require(await recorder.waitForFirst())
        let hint = try decode(bytes)
        #expect(hint.requestID == 0)
        #expect(hint.syncAvailable.eventID == 12)
        #expect(hint.syncAvailable.highWatermark == 48)

        try await stream.finish()
        #expect(await registry.connectionMetricsSnapshot() == .init(activeDevices: 0, activeConnections: 0))
    }

    @Test("a heartbeat closes a connection that cannot reacquire its expired lease")
    func heartbeatFailsClosedWhenLeaseRenewalIsRejected() async throws {
        let registry = V2DeviceConnectionRegistry(connectionAdmissionPolicy: .init(
            maximumConnectionsPerDevice: 1,
            maximumConnectionsPerUser: 1
        ))
        let leases = RejectingByteStreamRenewalLeases()
        await registry.configureLivePresenceLeases(leases)
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: ByteStreamAuthFake(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: ByteStreamCommandFake(),
            registry: registry
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(authenticate, version: protocolVersion))
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 1)

        var heartbeat = IMV2Envelope()
        heartbeat.requestID = 3
        heartbeat.protocolVersion = UInt32(protocolVersion)
        heartbeat.heartbeat = .init()
        await #expect(throws: V2GatewaySessionError.authenticatedConnectionLimit) {
            try await stream.receive(encoded(heartbeat, version: protocolVersion))
        }

        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        #expect(await leases.activeConnectionIDs().isEmpty)
    }

    @Test("a local Hybrid room viewer receives a metadata-only wake on its existing TLS stream")
    func emitsGroupEventAvailableOnlyWhileLocallySubscribed() async throws {
        let registry = V2DeviceConnectionRegistry()
        let connectionID = UUID()
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(), capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: ByteStreamCommandFake(),
            connectionID: connectionID,
            registry: registry
        )
        let recorder = OutboundFrameRecorder()
        await stream.setOutboundWriter { bytes in await recorder.append(bytes) }
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(authenticate, version: protocolVersion))

        let roomID = try RoomID("00000000-0000-0000-0000-000000000c01")
        await registry.subscribeForegroundGroup(stream, connectionID: connectionID, roomID: roomID)
        await registry.notifyForegroundGroupAvailable(roomID: roomID, highWatermark: 42)
        let frame = try #require(await recorder.waitForFirst())
        let wake = try decode(frame)
        #expect(wake.requestID == 0)
        #expect(wake.groupEventAvailable.roomID == roomID.rawValue)
        #expect(wake.groupEventAvailable.highWatermark == 42)

        await registry.unsubscribeForegroundGroup(connectionID: connectionID, roomID: roomID)
        await registry.notifyForegroundGroupAvailable(roomID: roomID, highWatermark: 43)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await recorder.count() == 1)
    }

    @Test("a direct live payload is routed only to an authenticated captured recipient")
    func routesDirectLivePayloadOnlyToRecipient() async throws {
        let registry = V2DeviceConnectionRegistry()
        let connectionID = UUID()
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(), capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: ByteStreamCommandFake(),
            connectionID: connectionID,
            registry: registry
        )
        let recorder = OutboundFrameRecorder()
        await stream.setOutboundWriter { bytes in await recorder.append(bytes) }
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(authenticate, version: protocolVersion))

        let roomID = try RoomID("00000000-0000-0000-0000-000000000c02")
        await registry.subscribeForegroundGroup(stream, connectionID: connectionID, roomID: roomID)
        let direct = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 42,
            sourceEventID: .init("00000000-0000-0000-0000-000000000e01"),
            roomSequence: 42,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [try .init("user-a")]
        )
        await registry.notifyForegroundDirectEvent(direct)
        let frame = try #require(await recorder.waitForFirst())
        let wake = try decode(frame)
        #expect(wake.groupEventAvailable.roomID == roomID.rawValue)
        #expect(wake.groupEventAvailable.highWatermark == 42)
        #expect(wake.groupEventAvailable.sourceEventID == direct.sourceEventID.rawValue)
        #expect(wake.groupEventAvailable.roomSequence == 42)
        #expect(wake.groupEventAvailable.projectionKind == "message")
        #expect(wake.groupEventAvailable.eventPayload == direct.payload)

        let otherRecipient = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 43,
            sourceEventID: .init("00000000-0000-0000-0000-000000000e02"),
            roomSequence: 43,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [try .init("user-b")]
        )
        await registry.notifyForegroundDirectEvent(otherRecipient)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await recorder.count() == 1)
    }

    @Test("a group live payload is routed only to the exact authorized membership epoch")
    func routesGroupLivePayloadOnlyToMatchingMembershipRevision() async throws {
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 4_096,
            acceptedVersions: [0, protocolVersion]
        )
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: frameLimits)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000c12")
        let recorders = [OutboundFrameRecorder(), OutboundFrameRecorder()]
        let revisions: [UInt64] = [7, 6]
        var streams: [V2GatewayByteStream] = []
        var connectionIDs: [UUID] = []

        for index in recorders.indices {
            let connectionID = UUID()
            let stream = V2GatewayByteStream(
                frameLimits: frameLimits,
                session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(), capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
                handler: ByteStreamCommandFake(),
                connectionID: connectionID,
                registry: registry
            )
            let recorder = recorders[index]
            await stream.setOutboundWriter { bytes in await recorder.append(bytes) }
            var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(encoded(hello, version: 0))
            var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
            _ = try await stream.receive(encoded(authenticate, version: protocolVersion))
            await registry.subscribeForegroundGroup(
                stream,
                connectionID: connectionID,
                roomID: roomID,
                membershipRevision: revisions[index]
            )
            streams.append(stream)
            connectionIDs.append(connectionID)
        }

        let group = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 52,
            sourceEventID: .init("00000000-0000-0000-0000-000000000e12"),
            roomSequence: 52,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [],
            groupMembershipRevision: 7,
            acceptedMembershipRevision: 7
        )
        #expect(V2PreparedGatewayGroupEventAvailable(
            groupEvents: [group],
            frameLimits: frameLimits
        ) != nil)
        await registry.notifyForegroundGroupEvents([group])

        let frame = try #require(await recorders[0].waitForFirst())
        let available = try decode(frame).groupEventAvailable
        #expect(available.roomSequence == 0)
        #expect(available.liveEvents.map(\.roomSequence) == [52])
        try await Task.sleep(for: .milliseconds(20))
        #expect(await recorders[0].count() == 1)
        #expect(await recorders[1].count() == 0)

        // Updating one subscription invalidates the immutable room snapshot.
        // The next publication must rebuild it once and include the newly
        // matching stream without weakening the revision fence above.
        await registry.subscribeForegroundGroup(
            streams[1],
            connectionID: connectionIDs[1],
            roomID: roomID,
            membershipRevision: 7
        )
        let nextGroup = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 53,
            sourceEventID: .init("00000000-0000-0000-0000-000000000e13"),
            roomSequence: 53,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [],
            groupMembershipRevision: 7,
            acceptedMembershipRevision: 7
        )
        await registry.notifyForegroundGroupEvents([nextGroup])
        try await Task.sleep(for: .milliseconds(20))
        #expect(await recorders[0].count() == 2)
        #expect(await recorders[1].count() == 1)
    }

    @Test("one shared group batch serves compressed and legacy connection contracts")
    func groupLiveBatchSelectsNegotiatedCompressionVariant() async throws {
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 4_096,
            acceptedVersions: [0, protocolVersion]
        )
        let registry = V2DeviceConnectionRegistry(
            foregroundFrameLimits: frameLimits,
            foregroundFrameCompression: .zlib,
            foregroundCompressionThresholdBytes: 1
        )
        let roomID = try RoomID("00000000-0000-0000-0000-000000000c22")
        let recorders = [OutboundFrameRecorder(), OutboundFrameRecorder()]

        for index in recorders.indices {
            let connectionID = UUID()
            let stream = V2GatewayByteStream(
                frameLimits: frameLimits,
                session: .init(
                    limits: try .init(maximumInFlightRequests: 1),
                    authenticator: ByteStreamAuthFake(),
                    capabilityProfile: "base",
                    supportedFrameCompression: .zlib,
                    commandAdmission: V2AllowingGatewayCommandAdmission()
                ),
                handler: ByteStreamCommandFake(),
                connectionID: connectionID,
                registry: registry
            )
            let recorder = recorders[index]
            await stream.setOutboundWriter { bytes in await recorder.append(bytes) }
            var hello = IMV2Envelope()
            hello.requestID = 1
            hello.clientHello = .init()
            hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            if index == 0 { hello.clientHello.supportedFrameCompressions = [.zlib] }
            _ = try await stream.receive(encoded(hello, version: 0))
            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = UInt32(protocolVersion)
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = "opaque"
            authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
            _ = try await stream.receive(encoded(authenticate, version: protocolVersion))
            await registry.subscribeForegroundGroup(
                stream,
                connectionID: connectionID,
                roomID: roomID,
                membershipRevision: 9
            )
        }

        let event = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 61,
            sourceEventID: .init("00000000-0000-0000-0000-000000000e22"),
            roomSequence: 61,
            projectionKind: "message",
            payload: Data(repeating: 0x61, count: 1_500),
            recipientUserIDs: [],
            groupMembershipRevision: 9,
            acceptedMembershipRevision: 9
        )
        await registry.notifyForegroundGroupEvents([event])

        let compressedBytes = try #require(await recorders[0].waitForFirst())
        let plainBytes = try #require(await recorders[1].waitForFirst())
        let compressedFrame = try V2FrameCodec.decodeExactlyOne(
            compressedBytes,
            limits: frameLimits
        )
        let plainFrame = try V2FrameCodec.decodeExactlyOne(plainBytes, limits: frameLimits)
        #expect(compressedFrame.flags.contains(.compressed))
        #expect(plainFrame.flags.isEmpty)
        #expect(compressedBytes.count < plainBytes.count)
        #expect(try V2ServerProtobufFrameCodec.decode(
            compressedFrame,
            compression: .zlib
        ).groupEventAvailable.liveEvents.map(\.roomSequence) == [61])
        #expect(try V2ServerProtobufFrameCodec.decode(plainFrame)
            .groupEventAvailable.liveEvents.map(\.roomSequence) == [61])
    }

    @Test("a direct live payload reaches every small-fanout local stream exactly once")
    func routesDirectLivePayloadToSmallFanoutStreams() async throws {
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 4_096,
            acceptedVersions: [0, protocolVersion]
        )
        // Supplying the process-wide frame contract exercises the production
        // encode-once broadcast path rather than the compatibility fallback.
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: frameLimits)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000c03")
        let recorders = [OutboundFrameRecorder(), OutboundFrameRecorder()]

        for recorder in recorders {
            let connectionID = UUID()
            let stream = V2GatewayByteStream(
                frameLimits: frameLimits,
                session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(), capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
                handler: ByteStreamCommandFake(),
                connectionID: connectionID,
                registry: registry
            )
            await stream.setOutboundWriter { bytes in await recorder.append(bytes) }
            var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(encoded(hello, version: 0))
            var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
            _ = try await stream.receive(encoded(authenticate, version: protocolVersion))
            await registry.subscribeForegroundGroup(stream, connectionID: connectionID, roomID: roomID)
        }

        let direct = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 44,
            sourceEventID: .init("00000000-0000-0000-0000-000000000e03"),
            roomSequence: 44,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [try .init("user-a")]
        )
        await registry.notifyForegroundDirectEvent(direct)

        var encodedFrames: [Data] = []
        for recorder in recorders {
            let frame = try #require(await recorder.waitForFirst())
            encodedFrames.append(frame)
            let wake = try decode(frame)
            #expect(wake.groupEventAvailable.sourceEventID == direct.sourceEventID.rawValue)
            #expect(await recorder.count() == 1)
        }
        #expect(encodedFrames.count == 2)
        #expect(encodedFrames[0] == encodedFrames[1])
    }

    @Test("a direct live payload excludes only its originating connection")
    func directLivePayloadExcludesOnlyOriginatingConnection() async throws {
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 4_096,
            acceptedVersions: [0, protocolVersion]
        )
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: frameLimits)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000c04")
        let connectionIDs = [UUID(), UUID()]
        let recorders = [OutboundFrameRecorder(), OutboundFrameRecorder()]

        for index in recorders.indices {
            let stream = V2GatewayByteStream(
                frameLimits: frameLimits,
                session: .init(
                    limits: try .init(maximumInFlightRequests: 1),
                    authenticator: ByteStreamAuthFake(),
                    capabilityProfile: "base",
                    commandAdmission: V2AllowingGatewayCommandAdmission()
                ),
                handler: ByteStreamCommandFake(),
                connectionID: connectionIDs[index],
                registry: registry
            )
            let recorder = recorders[index]
            await stream.setOutboundWriter { bytes in await recorder.append(bytes) }
            var hello = IMV2Envelope()
            hello.requestID = 1
            hello.clientHello = .init()
            hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(encoded(hello, version: 0))
            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = UInt32(protocolVersion)
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = "opaque"
            authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
            _ = try await stream.receive(encoded(authenticate, version: protocolVersion))
            await registry.subscribeForegroundGroup(
                stream,
                connectionID: connectionIDs[index],
                roomID: roomID
            )
        }

        let direct = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 45,
            sourceEventID: .init("00000000-0000-0000-0000-000000000e04"),
            roomSequence: 45,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [try .init("user-a")],
            excludedConnectionID: connectionIDs[0]
        )
        await registry.notifyForegroundDirectEvent(direct)

        #expect(await recorders[0].count() == 0)
        let peerFrame = try #require(await recorders[1].waitForFirst())
        #expect(try decode(peerFrame).groupEventAvailable.roomSequence == 45)
        #expect(await recorders[1].count() == 1)
    }

    private func encoded(_ envelope: IMV2Envelope, version: UInt8) throws -> Data {
        try V2FrameCodec.encode(try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version), limits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]))
    }

    private func decode(_ bytes: Data) throws -> IMV2Envelope {
        try V2ServerProtobufFrameCodec.decode(V2FrameCodec.decodeExactlyOne(bytes, limits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion])))
    }
}

private actor ConcurrentGatewayResponseRecorder {
    private var frames: [V2Frame] = []
    var count: Int { frames.count }
    func all() -> [V2Frame] { frames }
    func append(_ frame: V2Frame) { frames.append(frame) }
}

private actor SlowMessageSendCommandHandler: V2GatewayCommandHandler {
    private(set) var started = false
    private(set) var cancelled = false

    func handle(envelope: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard case .messageSendOperation = envelope.body else { return IMV2Envelope() }
        started = true
        do { try await Task.sleep(for: .seconds(60)) }
        catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        var response = IMV2Envelope()
        response.messageSendOperationResult.unresolved = true
        return response
    }
}

private final class RequiredNotificationFailingWriter: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private struct Failure: Error {}
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(Failure())
    }
}

private final class RequiredNotificationStallingWriter: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private struct Failure: Error {}
    private let pending = Mutex<EventLoopPromise<Void>?>(nil)
    var hasPending: Bool { pending.withLock { $0 != nil } }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        pending.withLock { $0 = promise }
    }
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        let write = pending.withLock { value in
            let result = value
            value = nil
            return result
        }
        // The write fails after the timeout resolved its result. This also
        // proves that a late completion cannot resume the continuation twice.
        write?.fail(Failure())
        context.close(mode: mode, promise: promise)
    }
}

private actor OutboundFrameRecorder {
    private var frames: [Data] = []

    func append(_ bytes: Data) { frames.append(bytes) }

    func waitForFirst() async -> Data? {
        for _ in 0..<20 {
            if let first = frames.first { return first }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func count() -> Int { frames.count }
    func all() -> [Data] { frames }
}

private final class SynchronousFrameRecorder: Sendable {
    private let frames = Mutex<[Data]>([])

    func append(_ bytes: Data) { frames.withLock { $0.append(bytes) } }
    var count: Int { frames.withLock(\.count) }
    var first: Data? { frames.withLock(\.first) }
    func element(at index: Int) -> Data? {
        frames.withLock { $0.indices.contains(index) ? $0[index] : nil }
    }
}

private actor RejectingByteStreamRenewalLeases: V2LivePresenceLeaseManaging {
    private var active: Set<UUID> = []

    func setPresencePublication(identity: V2AuthenticatedConnection, connectionID: UUID,
        suppressed: Bool, now: Date) throws -> V2PresencePublicationLeaseObservation {
        Issue.record("The rejected-renewal fixture must not publish presence")
        throw V2LiveActivityStoreError.corruptPersistenceState
    }

    func admitConnection(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        publicationSuppressed _: Bool,
        policy _: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        active.insert(connectionID)
        return .accepted(expiresAt: now.addingTimeInterval(90))
    }

    func renewConnection(
        identity _: V2AuthenticatedConnection,
        connectionID _: UUID,
        now _: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome { .rejected }

    func removePresence(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        now _: Date
    ) -> Bool {
        active.remove(connectionID)
        return !active.isEmpty
    }

    func allowsOnlinePresence(userID _: UserID) -> Bool { true }
    func activeConnectionIDs() -> Set<UUID> { active }
}

private struct ByteStreamAuthFake: V2GatewayAuthenticator {
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("user-a"), expiresAt: nil)
    }
}

private struct RejectingByteStreamAuthenticator: V2GatewayAuthenticator {
    let failure: V2GatewayAuthenticationError

    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        throw failure
    }
}

private actor SubscriptionResponseCommandFake: V2GatewayCommandHandler {
    private var failure: String?
    func setFailure(_ value: String?) { failure = value }
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var response = IMV2Envelope()
        if let failure {
            if failure == "unexpected-response" { response.heartbeatAck.serverTimeMs = 1 }
            else { response.error.code = failure; response.error.retryable = true }
        } else { response.acknowledged = .init() }
        return response
    }
}

private struct CanonicalSubscriptionCommandFake: V2GatewayCommandHandler {
    let subject: UserID
    func handle(envelope: IMV2Envelope, identity _: V2AuthenticatedConnection) throws -> IMV2Envelope {
        var response = IMV2Envelope()
        switch envelope.body {
        case .groupEventSubscribe(let request):
            response.groupEventSubscribed.roomID = try RoomID(request.roomID).rawValue
            response.groupEventSubscribed.membershipRevision = 1
        case .subscribePresence(let request):
            response.presenceSubscribed.roomID = try RoomID(request.roomID).rawValue
            response.presenceSubscribed.targetUserID = subject.rawValue
        default: Issue.record("Unexpected command in subscription fixture")
        }
        return response
    }
}

private struct ByteStreamCommandFake: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var response = IMV2Envelope()
        response.error = .init()
        response.error.code = "UNAVAILABLE"
        response.error.retryable = true
        return response
    }
}

private actor OriginRecordingCommandFake: V2GatewayCommandHandler {
    private var values: [UUID?] = []

    func handle(
        envelope _: IMV2Envelope,
        identity _: V2AuthenticatedConnection
    ) async throws -> IMV2Envelope {
        response()
    }

    func handle(
        envelope _: IMV2Envelope,
        identity _: V2AuthenticatedConnection,
        originatingConnectionID: UUID?
    ) async throws -> IMV2Envelope {
        values.append(originatingConnectionID)
        return response()
    }

    func origins() -> [UUID?] { values }

    private func response() -> IMV2Envelope {
        var response = IMV2Envelope()
        response.error = .init()
        response.error.code = "UNAVAILABLE"
        response.error.retryable = true
        return response
    }
}
