import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2GatewaySessionTests {
    private let protocolVersion = UInt8(IMV2ProtocolVersion.current)

    @Test("hello then authenticated device identity is the only session identity")
    func bootstrapAuthentication() async throws {
        let auth = GatewayAuthFake(userID: try .init("user-a"))
        let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 2), authenticator: auth, capabilityProfile: "base", now: { Date(timeIntervalSince1970: 0) })
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

    @Test("gateway session enforces its configured protobuf nesting limit")
    func enforcesConfiguredProtobufNestingLimit() async throws {
        let auth = GatewayAuthFake(userID: try .init("user-a"))
        let session = V2GatewaySession(
            limits: try .init(maximumInFlightRequests: 2),
            authenticator: auth,
            capabilityProfile: "base",
            maximumProtobufMessageDepth: 2,
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
}

private actor GatewayAuthFake: V2GatewayAuthenticator {
    let userID: UserID
    init(userID: UserID) { self.userID = userID }
    func authenticate(accessToken _: String, deviceID _: DeviceID) -> UserID { userID }
}

private struct GatewayCommandFake: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var response = IMV2Envelope(); response.error = .init(); response.error.code = "UNAVAILABLE"; response.error.retryable = true
        return response
    }
}
