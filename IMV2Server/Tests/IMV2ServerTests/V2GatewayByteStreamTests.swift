import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2GatewayByteStreamTests {
    @Test("fragmented bootstrap and authenticated frames preserve request correlation")
    func fragmentedFrames() async throws {
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]),
            session: .init(limits: try .init(maximumInFlightRequests: 2), authenticator: ByteStreamAuthFake(), capabilityProfile: "base", now: { Date(timeIntervalSince1970: 0) }),
            handler: ByteStreamCommandFake()
        )

        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.supportedProtocolVersions = [1]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        let helloBytes = try V2FrameCodec.encode(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]))
        #expect(try await stream.receive(Data(helloBytes.prefix(5))).isEmpty)
        let helloResponses = try await stream.receive(Data(helloBytes.dropFirst(5)))
        #expect(helloResponses.count == 1)
        #expect(try decode(helloResponses[0]).serverHello.selectedCapabilityProfile == "base")

        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = 1
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
        let authResponses = try await stream.receive(encoded(authenticate, version: 1))
        #expect(try decode(authResponses[0]).authenticated.selectedCapabilityProfile == "base")

        var heartbeat = IMV2Envelope()
        heartbeat.requestID = 3
        heartbeat.protocolVersion = 1
        heartbeat.heartbeat = .init()
        heartbeat.heartbeat.clientTimeMs = 123
        let heartbeatResponses = try await stream.receive(encoded(heartbeat, version: 1))
        let heartbeatAck = try decode(try #require(heartbeatResponses.first))
        #expect(heartbeatAck.requestID == 3)
        #expect(heartbeatAck.heartbeatAck.serverTimeMs == 0)

        var pull = IMV2Envelope()
        pull.requestID = 4
        pull.protocolVersion = 1
        pull.syncPull = .init()
        let pullResponses = try await stream.receive(encoded(pull, version: 1))
        let response = try decode(try #require(pullResponses.first))
        #expect(response.requestID == 4)
        #expect(response.error.code == "UNAVAILABLE")
    }

    @Test("malformed framing closes the connection")
    func malformedFrameClosesSession() async throws {
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 128, acceptedVersions: [0, 1]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(), capabilityProfile: "base"),
            handler: ByteStreamCommandFake()
        )
        await #expect(throws: V2FrameCodecError.invalidMagic) {
            try await stream.receive(Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        }
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [1]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        await #expect(throws: V2ConnectionStateError.unexpectedCommand) {
            try await stream.receive(encoded(hello, version: 0))
        }
    }

    @Test("declared frame limits are classified separately from generic request failures")
    func classifiesFrameLimitClosures() {
        #expect(v2GatewayClosureReason(for: V2FrameCodecError.declaredPayloadTooLarge(4_097)) == .frameLimitViolation)
        #expect(v2GatewayClosureReason(for: V2FrameCodecError.invalidMagic) == .requestFailure)
    }

    @Test("availability hints are asynchronous, state-free sync prompts")
    func emitsSyncAvailableForRegisteredUser() async throws {
        let registry = V2DeviceConnectionRegistry()
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: ByteStreamAuthFake(), capabilityProfile: "base"),
            handler: ByteStreamCommandFake(),
            registry: registry
        )
        let recorder = OutboundFrameRecorder()
        await stream.setOutboundWriter { bytes in
            Task { await recorder.append(bytes) }
        }
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [1]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(encoded(hello, version: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = 1; authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
        _ = try await stream.receive(encoded(authenticate, version: 1))
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

    private func encoded(_ envelope: IMV2Envelope, version: UInt8) throws -> Data {
        try V2FrameCodec.encode(try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version), limits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]))
    }

    private func decode(_ bytes: Data) throws -> IMV2Envelope {
        try V2ServerProtobufFrameCodec.decode(V2FrameCodec.decodeExactlyOne(bytes, limits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1])))
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
}

private struct ByteStreamAuthFake: V2GatewayAuthenticator {
    func authenticate(accessToken _: String, deviceID _: DeviceID) async throws -> UserID { try .init("user-a") }
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
