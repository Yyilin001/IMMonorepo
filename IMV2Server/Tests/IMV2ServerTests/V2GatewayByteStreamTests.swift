@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Compression
import IMV2Core
import IMV2ActorContracts
import NIOCore
import NIOEmbedded
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

struct V2GatewayByteStreamTests {
    @Test("TCP admission reasons retain actual send ownership through completion and cancellation",
          arguments: V2GatewayMessageSendRejectionReason.allCases, [false, true])
    func concurrentMessageSendDoesNotBlockHeartbeat(
        reason: V2GatewayMessageSendRejectionReason, cancel: Bool
    ) async throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let slow = SlowMessageSendCommandHandler()
        defer { Task { await slow.release() } }
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
        let payloadBytes = try V2ServerProtobufFrameCodec.encode(send, frameVersion: version).payload.count
        let budget = V2GatewayMessageSendBudget(maximumBytes: reason == .processBytes ? payloadBytes + 1 : 4_194_304)
        let stream = V2GatewayByteStream(
            frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 4),
                           authenticator: ByteStreamAuthFake(), capabilityProfile: "base",
                           commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: slow, registry: V2DeviceConnectionRegistry(),
            messageSendBudget: budget, maximumConcurrentMessageSends: reason == .connectionCount ? 1 : 4,
            maximumConcurrentMessageSendBytes: reason == .connectionBytes ? payloadBytes + 1 : 4_194_304)
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
        let write: @Sendable (V2Frame) async throws -> Void = { frame in await recorder.append(frame) }
        _ = try await stream.receiveFrames(encoded(send, version: version),
                                           concurrentMessageSendRespond: write, respond: write)
        for _ in 0..<10_000 {
            if await slow.started { break }
            await Task.yield()
        }
        #expect(await slow.started)
        let active = await budget.metricsSnapshot()
        #expect(active.inFlightRequests == 1 && active.reservedBytes == payloadBytes)
        #expect(active.peakInFlightRequests == 1 && active.peakReservedBytes == payloadBytes)
        var second = send
        second.requestID = 5
        _ = try await stream.receiveFrames(encoded(second, version: version),
                                           concurrentMessageSendRespond: write, respond: write)
        let rejected = try #require(await recorder.all().first)
        let busy = try V2ServerProtobufFrameCodec.decode(rejected)
        #expect(busy.requestID == 5 && busy.error.code == "SERVER_BUSY")
        #expect(busy.error.retryable && busy.error.retryAfterSeconds == 1)
        let rejectedMetrics = await budget.metricsSnapshot()
        for classification in V2GatewayMessageSendRejectionReason.allCases {
            #expect(rejectedMetrics.rejections[classification] == (classification == reason ? 1 : 0))
        }
        var heartbeat = IMV2Envelope()
        heartbeat.requestID = 4
        heartbeat.protocolVersion = UInt32(version)
        heartbeat.heartbeat = .init()
        let heartbeatResponse = try await stream.receive(encoded(heartbeat, version: version))
        #expect(try decode(#require(heartbeatResponse.first)).body != nil)
        if cancel {
            let closing = Task { try await stream.finish() }
            for _ in 0..<10_000 {
                if await slow.cancelled { break }
                await Task.yield()
            }
            #expect(await slow.cancelled)
            let cancelling = await budget.metricsSnapshot()
            #expect(cancelling.inFlightRequests == 1 && cancelling.reservedBytes == payloadBytes)
            await slow.release()
            try await closing.value
            #expect(await recorder.count == 1)
        } else {
            await slow.release()
            for _ in 0..<10_000 {
                if await budget.inFlightBytes() == 0 { break }
                await Task.yield()
            }
            #expect(await recorder.count == 2)
            try await stream.finish()
        }
        let settled = await budget.metricsSnapshot()
        #expect(settled.inFlightRequests == 0 && settled.reservedBytes == 0)
        #expect(settled.peakInFlightRequests == 1 && settled.peakReservedBytes == payloadBytes)
    }
    @Test("NIO notification writes honor connection revocation and required completion", arguments: [0, 1, 2, 3, 4])
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
        if mode == 4 {
            // Revocation wins before asynchronous session/Registry cleanup.
            // The real EventLoop write fence must reject selected notifications.
            stream.invalidateForegroundAuthorization()
            #expect(!(await stream.isAuthenticated()))
            #expect(!stream.connectionAllowsDispatch())
            await stream.sendSyncAvailable(eventID: 1, highWatermark: 1)
            #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
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
        if mode == 4 {
            #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
        } else if mode == 0 {
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
        let epoch = UUID()
        let notification = V2AccountRoomNotification.resyncRequired(epoch: epoch)
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
        #expect(envelope.accountRoomResyncRequired.connectionEpoch == epoch.uuidString.lowercased())
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
                let detail = await registry.activeForegroundGroupMetrics()
                #expect(detail.rooms == 1 && detail.viewers == 1)
                #expect(await recorder.count() == 0)
            } else {
                await registry.receivePresence(targetUserID: subject, isOnline: true, expiresAt: Date(timeIntervalSince1970: 1_750_000_006))
                let notifications = await recorder.all()
                #expect(notifications.count == 1)
                let notification = try decode(#require(notifications.first))
                #expect(notification.presenceChanged.roomID == room.rawValue)
            }
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
                    // Detail command state is independent of account receipt.
                    break
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
                if kind == "unsubscribe-group" {
                    let detail = await registry.activeForegroundGroupMetrics()
                    #expect(detail.rooms == 1 && detail.viewers == 1)
                } else if hasPriorSubscription { expectedRooms.append(oldRoom.rawValue) }
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
            if kind == "unsubscribe-group" {
                let detail = await registry.activeForegroundGroupMetrics()
                #expect(detail.rooms == 0 && detail.viewers == 0)
            }
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

        let head = try #require(V2PreparedGatewayGroupEventAvailable(roomID: roomID,
            highWatermark: 42, directEvent: nil, frameLimits: limits, protocolVersion: protocolVersion))
        #expect(stream.submitGroupEventAvailable(head))
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
        let body = try #require(V2PreparedGatewayGroupEventAvailable(roomID: roomID,
            highWatermark: 43, directEvent: direct, frameLimits: limits, protocolVersion: protocolVersion))
        #expect(stream.submitGroupEventAvailable(body))
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

        let direct = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 2,
            sourceEventID: .init("00000000-0000-0000-0000-000000000cf4"),
            roomSequence: 2,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [try .init("user-a")]
        )
        let body = try #require(V2PreparedGatewayGroupEventAvailable(roomID: roomID,
            highWatermark: 2, directEvent: direct, frameLimits: limits, protocolVersion: protocolVersion))
        let submission = try #require(stream.prepareNIOGroupEventAvailable(body))
        V2NIOGatewayForegroundWriter.submitBatch([submission])
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
        // Diagnostic detail must not change the original close classification.
        let session = v2GatewayTransportFailureMetadata(V2GatewaySessionError.authenticatedConnectionLimit)
        #expect(session["session_error_code"] == "authenticated_connection_limit")
        #expect(session["error_code"] == "operation_failed")
        #expect(v2GatewayClosureReason(for: V2GatewaySessionError.authenticatedConnectionLimit) == .requestFailure)
        let expired = v2GatewayTransportFailureMetadata(V2GatewaySessionError.sessionExpired)
        #expect(expired["session_error_code"] == "session_expired")
        #expect(v2GatewayClosureReason(for: V2GatewaySessionError.sessionExpired) == .requestFailure)
        let superseded = v2GatewayTransportFailureMetadata(V2GatewayRoomSubscriptionCoordinationError.superseded)
        #expect(superseded["room_coordination_error_code"] == "superseded")
        #expect(v2GatewayClosureReason(for: V2GatewayRoomSubscriptionCoordinationError.superseded) == .requestFailure)
        let refused = v2GatewayTransportFailureMetadata(V2GatewayRoomSubscriptionCoordinationError.refused(.unavailable))
        #expect(refused["room_coordination_error_code"] == "owner_refused")
        #expect(refused["room_subscription_refusal"] == "unavailable")
        let secret = "token=private-value target=private.example:443"
        let io = v2GatewayTransportFailureMetadata(IOError(errnoCode: 54, reason: secret))
        #if !os(Windows)
        #expect(io["errno"] == "54")
        #endif
        #expect(io["session_error_code"] == nil)
        #expect(!String(describing: io).contains(secret))
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

    @Test("expired online projection and rejected repair never reauthenticate or close a live TCP session")
    func heartbeatSurvivesExpiredPresenceAndRejectedRepair() async throws {
        let registry = V2DeviceConnectionRegistry(connectionAdmissionPolicy: .init(
            maximumConnectionsPerDevice: 1,
            maximumConnectionsPerUser: 1
        ))
        let leases = RejectingByteStreamRenewalLeases()
        await registry.configureLivePresenceLeases(leases)
        let authenticator = CountingByteStreamAuthenticator()
        let connection = UUID()
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: authenticator,
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: ByteStreamCommandFake(),
            connectionID: connection, registry: registry
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
        let expiry = try #require(await registry.presenceLeaseSnapshot(connectionID: connection).deadline)
        _ = try await stream.receive(encoded(heartbeat, version: protocolVersion))
        try await ContinuousClock().sleep(until: expiry + .milliseconds(10))
        for requestID in 4...8 {
            heartbeat.requestID = UInt64(requestID)
            let bytes = try await stream.receive(encoded(heartbeat, version: protocolVersion))
            var decoder = V2FrameDecoder(limits: try .init(maximumPayloadBytes: 4096, acceptedVersions: [protocolVersion]))
            let frames = try bytes.flatMap { try decoder.append($0) }
            let frame = try #require(frames.first)
            let response = try V2ServerProtobufFrameCodec.decode(frame)
            #expect(response.requestID == UInt64(requestID))
            if case .heartbeatAck = response.body {} else { Issue.record("live TCP must acknowledge heartbeat") }
        }
        #expect(await authenticator.calls == 1)
        #expect(await leases.renewals > 0)
        #expect(await leases.admissions > 1)
        #expect(await stream.isAuthenticated())
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 1)
        try await stream.finish()
        #expect(!stream.connectionAllowsDispatch())
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        await registry.finishLivePresenceRenewals()
    }

    @Test("a direct live payload is routed only to an authenticated captured recipient")
    func routesDirectLivePayloadOnlyToRecipient() async throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion])
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: limits)
        let owner = try await registry.configureRoomSubscriptionIngress(authority: V2GatewayRoomSubscriptionAuthority())
        let connectionID = UUID()
        let stream = V2GatewayByteStream(
            frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(), capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: ByteStreamCommandFake(),
            connectionID: connectionID,
            registry: registry
        )
        let recorder = SynchronousFrameRecorder()
        #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            foregroundWriter: { bytes in
                if let frame = try? V2FrameCodec.decodeExactlyOne(bytes, limits: limits),
                   let envelope = try? V2ServerProtobufFrameCodec.decode(frame),
                   case .groupEventAvailable(let available) = envelope.body, available.roomSequence > 0 {
                    recorder.append(bytes)
                }
            }))
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"; hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "00000000-0000-0000-0000-000000000A02"
        _ = try await stream.receive(encoded(authenticate, version: protocolVersion))

        let roomID = try RoomID("00000000-0000-0000-0000-000000000c02")
        let fence = V2RoomSubscriptionFence(activation: .init(roomID: roomID,
            owner: try .init(shardID: "rooms", epoch: 0), activationEpoch: try .init(1),
            host: .init(hostID: try .init("byte-stream-owner"), incarnationID: UUID())),
            subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        try #require(await owner.install(fence: fence, sourceShardID: "rooms", serviceID: "owner",
            deadline: .now + .seconds(20)))
        let member = V2RoomSubscriptionMember(userID: try .init("user-a"), memberRevision: 0)
        #expect(await owner.applyRoomSubscription(.init(fence: fence, deliverySequence: 1,
            authorizationSequence: 1, payload: .baseline(members: [member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
        let direct = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 42,
            sourceEventID: .init("00000000-0000-0000-0000-000000000e01"),
            roomSequence: 42,
            projectionKind: "message",
            payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [try .init("user-a")]
        )
        #expect(await owner.applyRoomSubscription(.init(fence: fence, deliverySequence: 2,
            authorizationSequence: 1, payload: .event(V2RealtimeRoomEvent(direct), members: [member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        let frame = try #require(recorder.first)
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
        #expect(await owner.applyRoomSubscription(.init(fence: fence, deliverySequence: 3,
            authorizationSequence: 1, payload: .event(V2RealtimeRoomEvent(otherRecipient), members: [member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(3))
        #expect(recorder.count == 1)
        try await stream.finish(); await registry.shutdownRealtimeRecovery()
    }

    @Test("account membership tenure applies to every device across revoke and rejoin")
    func routesGroupLivePayloadOnlyToMatchingMembershipRevision() async throws {
        let room = try RoomID("00000000-0000-0000-0000-000000000c12")
        let f = try await ownerSockets(roomID: room, memberRevision: 7)
        let user = try UserID("user-a")
        func event(_ delivery: UInt64, authorization: UInt64, sequence: UInt64, member: UInt64) async {
            let body = V2RealtimeRoomEvent(roomID: room, highWatermark: sequence,
                sourceEventID: EventID(uuid: UUID()), roomSequence: sequence, projectionKind: "message",
                payload: Data(#"{"kind":"message"}"#.utf8), recipientUserIDs: [], groupMembershipRevision: member)
            #expect(await f.ingress.applyRoomSubscription(.init(fence: f.fence, deliverySequence: delivery,
                authorizationSequence: authorization, payload: .event(body,
                    members: [.init(userID: user, memberRevision: member)])),
                authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(delivery))
        }
        await event(2, authorization: 1, sequence: 52, member: 6)
        #expect(f.recorders.allSatisfy { $0.count == 0 })
        await event(3, authorization: 1, sequence: 53, member: 7)
        #expect(f.recorders.allSatisfy { $0.count == 1 })
        #expect(await f.ingress.applyRoomSubscription(.init(fence: f.fence, deliverySequence: 4,
            authorizationSequence: 2, payload: .revoke(userID: user, memberRevision: 7)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(4))
        await event(5, authorization: 2, sequence: 54, member: 7)
        #expect(f.recorders.allSatisfy { $0.count == 1 })
        #expect(await f.ingress.applyRoomSubscription(.init(fence: f.fence, deliverySequence: 6,
            authorizationSequence: 3, payload: .grant(member: .init(userID: user, memberRevision: 8), baselineSequence: 54)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(6))
        await event(7, authorization: 3, sequence: 55, member: 7)
        #expect(f.recorders.allSatisfy { $0.count == 1 })
        await event(8, authorization: 3, sequence: 56, member: 8)
        for recorder in f.recorders {
            #expect(recorder.count == 2)
            #expect(try decode(#require(recorder.first)).groupEventAvailable.roomSequence == 53)
            #expect(try decode(#require(recorder.element(at: 1))).groupEventAvailable.roomSequence == 56)
        }
        for stream in f.streams { try await stream.finish() }
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("one prepared Owner body serves compressed and plain connection contracts")
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
        var streams: [V2GatewayByteStream] = []

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
            #expect(await stream.attachTransport(deviceRevocationHandler: {},
                outboundWriter: { bytes in await recorder.append(bytes) }))
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
            let authentication = try await stream.receive(encoded(authenticate, version: protocolVersion))
            #expect(try decode(#require(authentication.first)).authenticated.userID == "user-a")
            streams.append(stream)
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
        let prepared = try #require(V2PreparedGatewayGroupEventAvailable(roomID: roomID,
            highWatermark: 61, directEvent: event, frameLimits: frameLimits,
            compression: .zlib, compressionThresholdBytes: 1))
        for stream in streams { #expect(await stream.sendGroupEventAvailable(prepared)) }

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
        ).groupEventAvailable.roomSequence == 61)
        #expect(try V2ServerProtobufFrameCodec.decode(plainFrame)
            .groupEventAvailable.roomSequence == 61)
        for stream in streams { try await stream.finish() }
    }

    @Test("Owner direct body reaches all local devices exactly once with one shared encoding", arguments: [false, true])
    func routesDirectLivePayloadToSmallFanoutStreams(excludeOrigin: Bool) async throws {
        let room = try RoomID("00000000-0000-0000-0000-000000000c03")
        let f = try await ownerSockets(roomID: room, memberRevision: 0)
        let body = V2RealtimeRoomEvent(roomID: room, highWatermark: 44, sourceEventID: EventID(uuid: UUID()),
            roomSequence: 44, projectionKind: "message", payload: Data(#"{"kind":"message"}"#.utf8),
            recipientUserIDs: [try UserID("user-a")], excludedConnectionID: excludeOrigin ? f.connections[0] : nil)
        #expect(await f.ingress.applyRoomSubscription(.init(fence: f.fence, deliverySequence: 2,
            authorizationSequence: 1, payload: .event(body, members: [.init(userID: try UserID("user-a"), memberRevision: 0)])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        #expect(f.recorders[0].count == (excludeOrigin ? 0 : 1))
        #expect(f.recorders[1].count == 1)
        let peer = try #require(f.recorders[1].first)
        let available = try decode(peer).groupEventAvailable
        #expect(available.sourceEventID == body.sourceEventID.rawValue)
        #expect(available.roomSequence == 44 && available.eventPayload == body.payload)
        if !excludeOrigin { #expect(f.recorders[0].first == peer) }
        for stream in f.streams { try await stream.finish() }
        await f.registry.shutdownRealtimeRecovery()
    }

    private func ownerSockets(roomID: RoomID, memberRevision: UInt64) async throws ->
        (registry: V2DeviceConnectionRegistry, ingress: V2GatewayRoomSubscriptionIngress,
         fence: V2RoomSubscriptionFence, streams: [V2GatewayByteStream],
         recorders: [SynchronousFrameRecorder], connections: [UUID]) {
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion])
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: limits)
        let ingress = try await registry.configureRoomSubscriptionIngress(authority: V2GatewayRoomSubscriptionAuthority())
        var streams: [V2GatewayByteStream] = [], recorders: [SynchronousFrameRecorder] = [], connections: [UUID] = []
        for _ in 0..<2 {
            let connection = UUID(), recorder = SynchronousFrameRecorder(), device = UUID().uuidString
            let stream = V2GatewayByteStream(frameLimits: limits,
                session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(),
                    capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
                handler: ByteStreamCommandFake(), connectionID: connection, registry: registry)
            #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
                foregroundWriter: { bytes in
                    if let frame = try? V2FrameCodec.decodeExactlyOne(bytes, limits: limits),
                       let envelope = try? V2ServerProtobufFrameCodec.decode(frame),
                       case .groupEventAvailable(let available) = envelope.body, available.roomSequence > 0 {
                        recorder.append(bytes)
                    }
                }))
            var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device
            hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(encoded(hello, version: 0))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(protocolVersion); auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = device
            let response = try await stream.receive(encoded(auth, version: protocolVersion))
            #expect(try decode(#require(response.first)).authenticated.userID == "user-a")
            streams.append(stream); recorders.append(recorder); connections.append(connection)
        }
        let fence = V2RoomSubscriptionFence(activation: .init(roomID: roomID,
            owner: try .init(shardID: "rooms", epoch: 0), activationEpoch: try .init(1),
            host: .init(hostID: try .init("byte-stream-owner"), incarnationID: UUID())),
            subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        try #require(await ingress.install(fence: fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        #expect(await ingress.applyRoomSubscription(.init(fence: fence, deliverySequence: 1, authorizationSequence: 1,
            payload: .baseline(members: [.init(userID: try UserID("user-a"), memberRevision: memberRevision)])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
        return (registry, ingress, fence, streams, recorders, connections)
    }

    @Test("native bootstrap writes authentication and its final response before a coalesced user sync hint")
    func syncHintWaitsForBootstrapWriteBoundary() async throws {
        let registry = V2DeviceConnectionRegistry()
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, protocolVersion]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: ByteStreamCommandFake(), registry: registry)
        let recorder = OutboundFrameRecorder()
        await stream.setOutboundWriter { await recorder.append($0) }
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.deviceID = "00000000-0000-0000-0000-000000000A02"
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(protocolVersion)
        auth.authenticate.accessToken = "opaque"; auth.authenticate.deviceID = hello.clientHello.deviceID
        auth.authenticate.presencePublicationSuppressed = true
        let user = try UserID("user-a")
        _ = try await stream.receive(encoded(auth, version: protocolVersion)) { bytes in
            await registry.notifySyncAvailable(userID: user, eventID: 12, highWatermark: 48)
            #expect(await recorder.count() == 0)
            await recorder.append(bytes)
        }
        // Authentication has crossed the writer, but native bootstrap still
        // awaits its publication-control (or first authenticated) response.
        #expect(await recorder.count() == 1)
        await registry.notifySyncAvailable(userID: user, eventID: 14, highWatermark: 64)
        #expect(await recorder.count() == 1)
        var heartbeat = IMV2Envelope(); heartbeat.requestID = 3; heartbeat.protocolVersion = UInt32(protocolVersion)
        heartbeat.heartbeat = .init()
        _ = try await stream.receive(encoded(heartbeat, version: protocolVersion)) { bytes in await recorder.append(bytes) }
        let responses = try await recorder.all().map { try decode($0) }
        #expect(responses.map(\.requestID) == [2, 3, 0])
        #expect(responses.last?.syncAvailable.eventID == 14)
        #expect(responses.last?.syncAvailable.highWatermark == 64)
        try await stream.finish()
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
    private var completion: CheckedContinuation<Void, Never>?

    func release() {
        completion?.resume()
        completion = nil
    }

    private func markCancelled() { cancelled = true }

    func handle(envelope: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard case .messageSendOperation = envelope.body else { return IMV2Envelope() }
        started = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { completion = $0 }
        } onCancel: {
            Task { await self.markCancelled() }
        }
        try Task.checkCancellation()
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

private actor CountingByteStreamAuthenticator: V2GatewayAuthenticator {
    private(set) var calls = 0
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        calls += 1
        return try .init(userID: .init("user-a"), expiresAt: Date().addingTimeInterval(60))
    }
}

private actor RejectingByteStreamRenewalLeases: V2LivePresenceLeaseManaging {
    private(set) var admissions = 0
    private(set) var renewals = 0
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
        admissions += 1
        guard admissions == 1 else { return .rejected }
        active.insert(connectionID)
        return .accepted(expiresAt: now.addingTimeInterval(0.2))
    }

    func renewConnection(
        identity _: V2AuthenticatedConnection,
        connectionID _: UUID,
        now _: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome { renewals += 1; return .rejected }

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
