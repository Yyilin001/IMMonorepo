@testable import IMV2ServerGateway
import Foundation
import IMV2Core
import IMV2ServerContracts
import Synchronization
import Testing

struct V2RetiredGatewayControlDrainTests {
    @Test("shutdown joins an unregistered connection's actual non-Ready retry writer")
    func retiredControlWorkerIsActuallyJoined() async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let connection = UUID(), version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 4),
                authenticator: RetiredControlAuthenticator(), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: RetiredControlCommandHandler(), connectionID: connection, registry: registry)
        let started = RetiredControlSignal(), release = RetiredControlSignal()
        let cancelled = RetiredControlSignal(), settled = RetiredControlSignal(), finished = RetiredControlSignal()
        let selected = Mutex<V2GatewayScopedNotificationWrite?>(nil)
        defer { release.mark() }
        let attached = await stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            scopedNotificationWriter: { write in
                selected.withLock { $0 = write }; started.mark()
                return await withTaskCancellationHandler {
                    await release.wait() // Cancellation is deliberately not actual completion.
                    let accepted = write.enqueueIfCurrent {
                        Issue.record("A retired control writer accepted a late frame")
                    }
                    settled.mark()
                    return accepted
                } onCancel: { cancelled.mark() }
            })
        #expect(attached)
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.deviceID = DeviceID(uuid: UUID()).rawValue
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = hello.clientHello.deviceID
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
        let room = RoomID(uuid: UUID())
        await stream.sendRealtimeCoverage(scope: .room, scopeID: room.rawValue,
            scopeGeneration: 1, ready: false, reason: .installing,
            scopePermit: { enqueue in enqueue(); return true })
        let deadline = ContinuousClock.now + .seconds(3)
        while !started.value {
            guard ContinuousClock.now < deadline else { throw RetiredControlFailure.timeout }
            await Task.yield()
        }
        let write = try #require(selected.withLock { $0 })
        // This control retry owns no Coordinator outbound ticket. Its physical
        // stream is then removed from shutdown's active Directory enumeration.
        let recovery = await registry.realtimeRecoverySnapshot()
        #expect(recovery.actual == 0 && recovery.positions == 0)
        await registry.unregister(connectionID: connection)
        while !cancelled.value {
            guard ContinuousClock.now < deadline else { throw RetiredControlFailure.timeout }
            await Task.yield()
        }
        let heldStages = await registry.registryRecoveryMetricsSnapshot().retiredRecoveryWriterStages
        #expect(heldStages[.retainedStreams]?.count == 1)
        #expect(heldStages[.actualDrains]?.count == 1)
        let late = write.enqueueIfCurrent { Issue.record("Unregister failed to revoke actual control admission") }
        #expect(!late && !settled.value)
        let shutdown = Task {
            await registry.shutdownRealtimeRecovery()
            #expect(settled.value) // Retired physical ownership must settle first.
            finished.mark()
        }
        while !(await registry.realtimeRecoverySnapshot().closed) {
            guard ContinuousClock.now < deadline else { throw RetiredControlFailure.timeout }
            await Task.yield()
        }
        #expect(!finished.value && !settled.value)
        release.mark()
        await shutdown.value
        #expect(finished.value && settled.value)
        let drainedStages = await registry.registryRecoveryMetricsSnapshot().retiredRecoveryWriterStages
        #expect((drainedStages[.retainedStreams]?.count ?? 0) == 0)
        #expect((drainedStages[.actualDrains]?.count ?? 0) == 0)
        await registry.shutdownRealtimeRecovery()
    }
}

private enum RetiredControlFailure: Error { case timeout }
private struct RetiredControlAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init(uuid: UUID()), expiresAt: nil)
    }
}
private struct RetiredControlCommandHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var response = IMV2Envelope(); response.acknowledged = .init(); return response
    }
}
private final class RetiredControlSignal: Sendable {
    private struct State { var value = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())
    var value: Bool { state.withLock { $0.value } }
    func mark() {
        let waiting = state.withLock { value -> [CheckedContinuation<Void, Never>] in
            value.value = true
            let result = value.waiters; value.waiters.removeAll(); return result
        }
        for waiter in waiting { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { value in
                if value.value { return true }
                value.waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
}
