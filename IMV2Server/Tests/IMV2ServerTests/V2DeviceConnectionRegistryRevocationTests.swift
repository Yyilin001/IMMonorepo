import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 device connection registry revocation")
struct V2DeviceConnectionRegistryRevocationTests {
    @Test("all device sockets begin closing before a slow close can finish", .timeLimit(.minutes(1)))
    func closesDeviceSocketsConcurrently() async throws {
        let registry = V2DeviceConnectionRegistry()
        let device = try DeviceID("00000000-0000-0000-0000-000000000e01")
        let identity = V2AuthenticatedConnection(
            userID: try UserID("00000000-0000-0000-0000-000000000e02"),
            deviceID: device,
            capabilityProfile: "base"
        )
        let closeGate = DeviceRevocationCloseGate(expected: 2)
        for index in 0..<2 {
            let connectionID = UUID(
                uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index + 1))
            )
            let stream = V2GatewayByteStream(
                frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]),
                session: .init(
                    limits: try .init(maximumInFlightRequests: 1),
                    authenticator: RegistryRevocationAuthenticator(),
                    capabilityProfile: "base",
                    commandAdmission: V2AllowingGatewayCommandAdmission()
                ),
                handler: RegistryRevocationCommandHandler(),
                connectionID: connectionID,
                registry: registry
            )
            await stream.setDeviceRevocationHandler { await closeGate.close() }
            #expect(try await registry.register(
                stream,
                connectionID: connectionID,
                identity: identity,
                publicationSuppressed: true
            ))
        }

        let revocation = Task { await registry.revoke(deviceID: device) }
        await closeGate.waitUntilAllStarted()
        #expect(await registry.connectionCount(for: device) == 2)
        await closeGate.release()
        await revocation.value
        #expect(await registry.connectionCount(for: device) == 0)
    }
}

private actor DeviceRevocationCloseGate {
    private let expected: Int
    private var started = 0
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) { self.expected = expected }

    func close() async {
        started += 1
        if started == expected {
            startedWaiter?.resume()
            startedWaiter = nil
        }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func waitUntilAllStarted() async {
        if started == expected { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        for waiter in closeWaiters { waiter.resume() }
        closeWaiters.removeAll()
    }
}

private struct RegistryRevocationAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("00000000-0000-0000-0000-000000000e02"), expiresAt: nil)
    }
}

private struct RegistryRevocationCommandHandler: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        .init()
    }
}
