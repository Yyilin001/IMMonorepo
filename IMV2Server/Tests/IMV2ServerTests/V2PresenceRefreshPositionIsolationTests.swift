import Foundation
import IMV2Core
import IMV2ServerContracts
import Testing
@testable import IMV2ServerGateway

@Suite("Presence query keys and result positions")
struct V2PresenceRefreshPositionIsolationTests {
    @Test("old socket responsibility cannot block or release a same-key successor query")
    func oldOutputDoesNotOwnSuccessorQueryKey() async throws {
        let recovery = V2RealtimeRecoveryCoordinator()
        let registry = V2DeviceConnectionRegistry()
        let reader = PositionIsolationReader(), writer = PositionIsolationWriter()
        let request = V2PresenceObservationRequest(roomID: .init(uuid: UUID()),
            viewerUserID: .init(uuid: UUID()), targetUserID: .init(uuid: UUID()))
        let observations = V2PresenceRefreshCoordinator(reader: reader, recoveryCoordinator: recovery,
            isCurrent: { _ in true })
        let old = try await target(request, lifecycle: 100, recovery: recovery, registry: registry, writer: writer)
        let next = try await target(request, lifecycle: 101, recovery: recovery, registry: registry, writer: nil)
        let third = try await target(request, lifecycle: 102, recovery: recovery, registry: registry, writer: nil)
        let refresh = Task { try await observations.refresh([old], strict: true) }
        try await wait { await writer.held }
        let held = await observations.snapshot()
        #expect(held.actualQueries == 0 && held.resultPositions == 1 && held.positions == 1)
        let preparing = Task { try await observations.prepare(next) }
        // SQL #2 must start while SQL #1's socket is still physically held.
        try await wait { await reader.calls == 2 }
        #expect(await writer.held)
        #expect(await observations.snapshot().actualQueries == 1)
        await writer.release()
        try await refresh.value
        #expect(await observations.snapshot().resultPositions == 0)
        // Settling the old result must not remove SQL #2's active query key.
        let thirdPreparation = Task { try await observations.prepare(third) }
        try await wait { await observations.snapshot().queued == 1 }
        #expect(await reader.calls == 2)
        #expect(await observations.snapshot().positions == 2)
        await reader.releaseSecond()
        let proof = try await preparing.value
        _ = try await thirdPreparation.value
        #expect(await reader.calls == 3)
        let began = try #require(await reader.secondBegan)
        #expect(proof.deadline <= began + .seconds(30))
        #expect(proof.deadline > began + .seconds(29))
        let cached = try await observations.prepare(next)
        #expect(cached.deadline == proof.deadline)
        #expect(await reader.calls == 3)
        #expect(await observations.snapshot().positions == 0)
        await observations.finish()
        await recovery.shutdown()
        for stream in [old.stream, next.stream, third.stream] { await stream.closeForAccountRecovery() }
        await registry.shutdownRealtimeRecovery()
    }

    private func target(_ request: V2PresenceObservationRequest, lifecycle: UInt64,
        recovery: V2RealtimeRecoveryCoordinator, registry: V2DeviceConnectionRegistry,
        writer: PositionIsolationWriter?) async throws -> V2PresenceRefreshTarget {
        let connection = UUID(), device = DeviceID(uuid: UUID())
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1),
                authenticator: PositionIsolationAuthenticator(user: request.viewerUserID), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: PositionIsolationHandler(), connectionID: connection, registry: registry)
        #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            scopedNotificationWriter: { write in
                if let writer { return await writer.record(write) }
                return write.enqueueIfCurrent {}
            }))
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device.rawValue
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device.rawValue
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
        recovery.installConnection(.init(handle: .init(connectionID: connection, lifecycle: lifecycle,
            identity: .init(userID: request.viewerUserID, deviceID: device, capabilityProfile: "base"), stream: stream), accountScope: nil))
        await recovery.beginScopeRecovery(connection: connection, kind: .userPresence, id: request.targetUserID.rawValue)
        let generation = try #require(recovery.generation(for: .init(connection: connection,
            kind: .userPresence, id: request.targetUserID.rawValue)))
        return .init(connection: connection, lifecycle: lifecycle, scopeGeneration: generation, request: request, stream: stream)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw PositionIsolationFailure.timeout }
            await Task.yield()
        }
    }
}

private enum PositionIsolationFailure: Error { case timeout }
private struct PositionIsolationAuthenticator: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: user, expiresAt: nil)
    }
}
private struct PositionIsolationHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope { envelope }
}
private actor PositionIsolationWriter {
    private(set) var held = false
    private var gate: CheckedContinuation<Void, Never>?
    func record(_ write: V2GatewayScopedNotificationWrite) async -> Bool {
        let limits = try? V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [UInt8(IMV2ProtocolVersion.current)])
        let envelope = limits.flatMap { try? V2FrameCodec.decodeExactlyOne(write.bytes, limits: $0) }
            .flatMap { try? V2ServerProtobufFrameCodec.decode($0) }
        if case .presenceChanged? = envelope?.body {
            held = true
            await withCheckedContinuation { gate = $0 }
            held = false
        }
        return write.enqueueIfCurrent {}
    }
    func release() { gate?.resume(); gate = nil }
}
private actor PositionIsolationReader: V2LiveActivityStore {
    private(set) var calls = 0
    private(set) var secondBegan: ContinuousClock.Instant?
    private var gate: CheckedContinuation<Void, Never>?
    func presenceBatch(_ requests: [V2PresenceObservationRequest], now: Date) async -> [V2PresenceObservationRequest: V2PresenceObservationOutcome] {
        calls += 1
        if calls == 2 {
            secondBegan = .now
            await withCheckedContinuation { gate = $0 }
        }
        return Dictionary(uniqueKeysWithValues: requests.map { request in
            (request, .observed(.init(roomID: request.roomID, targetUserID: request.targetUserID,
                isOnline: true, expiresAt: now.addingTimeInterval(90))))
        })
    }
    func releaseSecond() { gate?.resume(); gate = nil }
    func preferences(userID: UserID, now: Date) throws -> V2LiveActivityPreferences { throw PositionIsolationFailure.timeout }
    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) throws -> V2PresenceState { throw PositionIsolationFailure.timeout }
    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) throws { throw PositionIsolationFailure.timeout }
    func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) throws { throw PositionIsolationFailure.timeout }
    func allowsOnlinePresence(userID: UserID) -> Bool { true }
}
