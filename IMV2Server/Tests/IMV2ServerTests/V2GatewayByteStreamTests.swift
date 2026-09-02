import Foundation
import IMV2Compression
import IMV2Core
import NIOCore
import NIOEmbedded
import Synchronization
@testable import IMV2Server
import Testing

struct V2GatewayByteStreamTests {
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
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
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
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
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
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
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
        authenticate.authenticate.deviceID = "device-a"
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
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))

        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
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
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
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
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
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
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
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
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
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
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
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
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
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
            var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(encoded(hello, version: 0))
            var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
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
            hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            if index == 0 { hello.clientHello.supportedFrameCompressions = [.zlib] }
            _ = try await stream.receive(encoded(hello, version: 0))
            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = UInt32(protocolVersion)
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = "opaque"
            authenticate.authenticate.deviceID = "device-a"
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
            var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(encoded(hello, version: 0))
            var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
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
            hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(encoded(hello, version: 0))
            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = UInt32(protocolVersion)
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = "opaque"
            authenticate.authenticate.deviceID = "device-a"
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

    func admitConnection(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
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
