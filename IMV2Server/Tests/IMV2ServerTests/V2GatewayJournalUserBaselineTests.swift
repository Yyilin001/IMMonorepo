import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication
import Testing
@testable import IMV2ServerGateway

@Suite("Gateway user baseline Ready barrier", .timeLimit(.minutes(1)))
struct V2GatewayJournalUserBaselineTests {
    @Test("room directory Ready is independent of a retired personal-sync baseline")
    func directoryReadyDoesNotUsePersonalSyncGate() async throws {
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), connection = UUID()
        let partition = V2RealtimeTopicKey(kind: .userSync, id: user.rawValue).partitionID()
        let source = V2RealtimeJournalSource(sourceID: "auth", incarnationID: UUID(), partitionID: partition)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: Date().addingTimeInterval(30), routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init())
        #expect(receiver.configureAuthenticationSources(["auth"]))
        #expect(receiver.install(source: source, serviceID: "fixture", fence: fence, deadline: .now + .seconds(30),
            rooms: [], viewers: [user]))
        #expect(receiver.installUserControlFloors(source: source, fence: fence, versions: [user: 0], isAuthenticationSource: true))
        let snapshot = V2RealtimeJournalProjectionBatch(source: source, fence: fence, payload: .snapshot(cut: 0, rooms: []))
        #expect(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "fixture") else {
            Issue.record("auth baseline not installed"); return
        }
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits), writer = UserBaselineWriter()
        await registry.configureJournalUserControlReceiver(receiver)
        let baselineReads = Mutex(0)
        await registry.configureJournalUserBaselineBarrier { requestedUser in
            baselineReads.withLock { $0 += 1 }
            return .init(source: source, fence: fence, userID: requestedUser, controlVersion: 0)
        }
        let account = try V2AccountRoomChangeService(states: UserBaselineStateReader(), onlineDelivery: .init(activate: { _, _, _ in }, deactivate: { _ in }))
        await registry.configureAccountRoomChanges(account)
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: UserBaselineAuthenticator(user: user),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: UserBaselineHandler(), connectionID: connection, registry: registry)
        let transportClosed = Mutex(false)
        let attached = await stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            requiredNotificationWriter: { _ in true }, scopedNotificationWriter: { await writer.write($0) },
            requiredNotificationClose: { transportClosed.withLock { $0 = true } })
        try #require(attached)
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device.rawValue
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device.rawValue
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
        let room = RoomID(uuid: UUID()), subject = UserID(uuid: UUID())
        let presence = V2PresenceState(roomID: room, targetUserID: subject, isOnline: true, expiresAt: Date().addingTimeInterval(30))
        let typing = V2TypingState(roomID: room, userID: subject, isTyping: true, expiresAt: Date().addingTimeInterval(30))
        // These calls test the added auth fence; observation permission remains
        // an independent responsibility of Registry/the live activity broker.
        await stream.sendPresenceState(presence)
        await stream.sendTypingState(typing)
        #expect(writer.liveEnqueues == 2)
        let epoch = try await registry.startAccountRoomChanges(connectionID: connection, userID: user)
        let ready = Task { try await registry.accountRoomChangesReadyWritten(connectionID: connection, epoch: epoch) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await writer.waiting), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await writer.waiting)
        receiver.retire(source: source)
        await writer.release()
        try await ready.value
        #expect(writer.readyEnqueues == 1)
        #expect(baselineReads.withLock { $0 } == 0)
        await stream.sendPresenceState(presence)
        await stream.sendTypingState(typing)
        #expect(writer.liveEnqueues == 2)
        let recovery = await registry.realtimeRecoverySnapshot()
        #expect(recovery.desired == 0)
        await account.invalidateCoverage()
        // Retiring a control source invalidates its authorization proof; it is
        // not a credential revocation or a physical transport failure.
        await account.shutdown()
        #expect(!transportClosed.withLock { $0 })
        #expect(await stream.supportsRequiredNotifications())
        await stream.sendPresenceState(presence)
        await stream.sendTypingState(typing)
        #expect(writer.liveEnqueues == 2)
        await stream.closeForAccountRecovery()
        await registry.shutdownRealtimeRecovery(); await account.shutdown()
        receiver.shutdown()
    }
}

private struct UserBaselineAuthenticator: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication { .init(userID: user, expiresAt: nil) }
}
private struct UserBaselineHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope { .init() }
}
private struct UserBaselineStateReader: V2RoomStateReading {
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        Dictionary(uniqueKeysWithValues: roomIDs.map { ($0, .unavailable) })
    }
}
private actor UserBaselineWriter {
    private nonisolated let live = Mutex(0)
    nonisolated var liveEnqueues: Int { live.withLock { $0 } }
    private nonisolated let enqueued = Mutex(0)
    nonisolated var readyEnqueues: Int { enqueued.withLock { $0 } }
    private(set) var waiting = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func release() { released = true; continuation?.resume(); continuation = nil }
    func write(_ write: V2GatewayScopedNotificationWrite) async -> Bool {
        let version = UInt8(IMV2ProtocolVersion.current)
        var decoder = V2FrameDecoder(limits: try! .init(maximumPayloadBytes: 4096, acceptedVersions: [version]))
        guard let frame = try? decoder.append(write.bytes).first,
              let envelope = try? V2ServerProtobufFrameCodec.decode(frame) else { return false }
        if case .presenceChanged? = envelope.body {
            return write.enqueueIfCurrent { self.live.withLock { $0 += 1 } }
        }
        if case .typingStateChanged? = envelope.body {
            return write.enqueueIfCurrent { self.live.withLock { $0 += 1 } }
        }
        guard case .realtimeCoverage(let coverage)? = envelope.body else { return write.enqueueIfCurrent({}) }
        if coverage.scope == .directory && coverage.state == .ready {
            waiting = true
            if !released { await withCheckedContinuation { continuation = $0 } }
            return write.enqueueIfCurrent { self.enqueued.withLock { $0 += 1 } }
        }
        return write.enqueueIfCurrent({})
    }
}
