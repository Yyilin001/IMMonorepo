import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2GatewaySessionTests {
    private let protocolVersion = UInt8(IMV2ProtocolVersion.current)

    @Test("hello then authenticated device identity is the only session identity")
    func bootstrapAuthentication() async throws {
        let auth = GatewayAuthFake(userID: try .init("user-a"))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: auth,
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        let helloResponse = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
        #expect(try V2ServerProtobufFrameCodec.decode(helloResponse).serverHello.selectedProtocolVersion == UInt32(protocolVersion))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion))
        #expect(await session.authenticatedIdentity() == .init(userID: try .init("user-a"), deviceID: try .init("device-a"), capabilityProfile: "base"))

        var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(protocolVersion); request.syncPull = .init()
        let response = try await session.receiveAuthenticated(try V2ServerProtobufFrameCodec.encode(request, frameVersion: protocolVersion), handler: GatewayCommandFake())
        #expect(try V2ServerProtobufFrameCodec.decode(response).error.code == "UNAVAILABLE")
    }

    @Test("production receive returns the same validated request used for dispatch")
    func productionReceiveReturnsValidatedRequest() async throws {
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: GatewayAuthFake(userID: try .init("user-a")),
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello = .init()
        hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        let helloExchange = try await session.receive(
            try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0),
            handler: GatewayCommandFake()
        )
        #expect(helloExchange.request == hello)
        #expect(
            try V2ServerProtobufFrameCodec.decode(helloExchange.response)
                .serverHello.selectedCapabilityProfile == "base"
        )

        var authenticate = IMV2Envelope()
        authenticate.requestID = 2
        authenticate.protocolVersion = UInt32(protocolVersion)
        authenticate.authenticate = .init()
        authenticate.authenticate.accessToken = "opaque"
        authenticate.authenticate.deviceID = "device-a"
        let authenticationExchange = try await session.receive(
            try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion),
            handler: GatewayCommandFake()
        )
        #expect(authenticationExchange.request == authenticate)

        var request = IMV2Envelope()
        request.requestID = 3
        request.protocolVersion = UInt32(protocolVersion)
        request.syncPull = .init()
        let exchange = try await session.receive(
            try V2ServerProtobufFrameCodec.encode(request, frameVersion: protocolVersion),
            handler: GatewayCommandFake()
        )
        #expect(exchange.request == request)
        #expect(exchange.responseEnvelope.requestID == request.requestID)
        #expect(try V2ServerProtobufFrameCodec.decode(exchange.response) == exchange.responseEnvelope)
    }

    @Test("bootstrap uses the authenticator's one combined identity and expiry read")
    func usesCombinedAuthenticationRead() async throws {
        let auth = CombinedGatewayAuthFake()
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 1),
            authenticator: auth,
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 10) }
        )
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion))

        #expect(await auth.readCount == 1)
    }

    @Test("gateway session enforces its configured protobuf nesting limit")
    func enforcesConfiguredProtobufNestingLimit() async throws {
        let auth = GatewayAuthFake(userID: try .init("user-a"))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: auth,
            capabilityProfile: "base",
            maximumProtobufMessageDepth: 2,
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion))

        var nested = IMV2Envelope(); nested.requestID = 3; nested.protocolVersion = UInt32(protocolVersion); nested.syncBatch = .init(); nested.syncBatch.records = [.init()]
        let frame = try V2ServerProtobufFrameCodec.encode(nested, frameVersion: protocolVersion)
        await #expect(throws: V2ServerProtobufFrameCodecError.payloadDecodeFailed) {
            _ = try await session.receiveAuthenticated(frame, handler: GatewayCommandFake())
        }
    }

    @Test("an access-token lease expires an otherwise active session")
    func expiresAuthenticatedSessionLease() async throws {
        let clock = SessionClock(Date(timeIntervalSince1970: 10))
        let auth = GatewayAuthFake(userID: try .init("user-a"), expiresAt: Date(timeIntervalSince1970: 11))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: auth,
            capabilityProfile: "base",
            commandAdmission: V2AllowingGatewayCommandAdmission(),
            now: { clock.now }
        )
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello = .init(); hello.clientHello.supportedProtocolVersions = [UInt32(protocolVersion)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0))
        var authenticate = IMV2Envelope(); authenticate.requestID = 2; authenticate.protocolVersion = UInt32(protocolVersion); authenticate.authenticate = .init(); authenticate.authenticate.accessToken = "opaque"; authenticate.authenticate.deviceID = "device-a"
        _ = try await session.receiveBootstrap(try V2ServerProtobufFrameCodec.encode(authenticate, frameVersion: protocolVersion))
        clock.now = Date(timeIntervalSince1970: 11)
        var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(protocolVersion); request.heartbeat = .init()
        await #expect(throws: V2GatewaySessionError.sessionExpired) {
            _ = try await session.receiveAuthenticated(try V2ServerProtobufFrameCodec.encode(request, frameVersion: protocolVersion), handler: GatewayCommandFake())
        }
    }
}

private actor GatewayAuthFake: V2GatewayAuthenticator {
    let userID: UserID
    let expiresAt: Date?
    init(userID: UserID, expiresAt: Date? = nil) { self.userID = userID; self.expiresAt = expiresAt }
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) -> V2GatewayAuthentication {
        .init(userID: userID, expiresAt: expiresAt)
    }
}

private actor CombinedGatewayAuthFake: V2GatewayAuthenticator {
    private(set) var readCount = 0

    func authenticateSession(accessToken _: String, deviceID _: DeviceID) throws -> V2GatewayAuthentication {
        readCount += 1
        return try .init(
            userID: .init("combined-user"),
            expiresAt: Date(timeIntervalSince1970: 20)
        )
    }
}

private final class SessionClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private struct GatewayCommandFake: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var response = IMV2Envelope(); response.error = .init(); response.error.code = "UNAVAILABLE"; response.error.retryable = true
        return response
    }
}
