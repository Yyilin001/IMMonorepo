@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
@testable import IMV2ServerGateway

struct V2GatewayConnectionTimeoutsTests {
    @Test("Public transport constructors reject unrepresentable timeouts before allocating TLS resources",
          arguments: [false, true], [0, -1, Int(Int64.max / 1_000_000) + 1, Int.max])
    func rejectsInvalidTimeout(authentication: Bool, value: Int) throws {
        let auth = authentication ? value : 10_000
        let idle = authentication ? 60_000 : value
        let stream = try makeStream()
        #expect(throws: V2TLSGatewayServerError.invalidConfiguration) {
            _ = try V2NIOGatewayChannelHandler(stream: stream, maximumQueuedInboundBytes: 4_096,
                maximumQueuedInboundChunks: 4, authenticationTimeoutMilliseconds: auth,
                idleTimeoutMilliseconds: idle, transportMetrics: V2GatewayTransportMetrics())
        }
        let listener = try V2TLSListenerConfiguration(host: "127.0.0.1", port: 12345,
            certificateChainPath: "unused-certificate.pem", privateKeyPath: "unused-private-key.pem")
        #expect(throws: V2TLSGatewayServerError.invalidConfiguration) {
            _ = try V2TLSGatewayServer(configuration: listener, connectionFactory: .init { stream },
                maximumConnections: 1, listenBacklog: 1, acceptBatchSize: 1, maximumQueuedInboundBytes: 4_096,
                maximumQueuedInboundChunks: 4, authenticationTimeoutMilliseconds: auth,
                idleTimeoutMilliseconds: idle, transportMetrics: V2GatewayTransportMetrics(), eventLoopThreads: 1)
        }
    }

    @Test("Valid timeout milliseconds are preserved exactly in both scheduled timers",
          arguments: [1, 60_000, Int(Int64.max / 1_000_000)])
    func preservesExactNanoseconds(milliseconds: Int) throws {
        let timeouts = try V2GatewayConnectionTimeouts(authenticationMilliseconds: milliseconds,
                                                     idleMilliseconds: milliseconds)
        let expected = Int64(milliseconds) * 1_000_000
        #expect(timeouts.authentication.nanoseconds == expected)
        #expect(timeouts.idle.nanoseconds == expected)
        _ = try V2NIOGatewayChannelHandler(stream: makeStream(), maximumQueuedInboundBytes: 4_096,
            maximumQueuedInboundChunks: 4, authenticationTimeoutMilliseconds: milliseconds,
            idleTimeoutMilliseconds: milliseconds, transportMetrics: V2GatewayTransportMetrics())
    }

    private func makeStream() throws -> V2GatewayByteStream {
        .init(frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]),
              session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: TimeoutTestAuthenticator(),
                             capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
              handler: TimeoutTestCommandHandler(), registry: V2DeviceConnectionRegistry())
    }
}

private struct TimeoutTestAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        Issue.record("Constructor boundary tests must not authenticate a connection")
        throw V2GatewayAuthenticationError.unauthenticated
    }
}

private struct TimeoutTestCommandHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        Issue.record("Constructor boundary tests must not execute domain commands")
        return .init()
    }
}
