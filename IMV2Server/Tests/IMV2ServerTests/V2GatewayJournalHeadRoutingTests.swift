import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import Testing
@testable import IMV2ServerGateway

@Suite("Gateway projected head routing", .timeLimit(.minutes(1)))
struct V2GatewayJournalHeadRoutingTests {
    @Test("Journal cannot write room Ready or H; the current Owner ingress advances both")
    func onlyOwnerIngressWritesRoomHeads() async throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: limits)
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init())
        let authority = V2GatewayRoomSubscriptionAuthority()
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), connection = UUID(), room = RoomID(uuid: UUID())
        let owner = try V2RoomDataOwner(shardID: "rooms", epoch: 0)
        let source = V2RealtimeJournalSource(sourceID: "rooms", incarnationID: UUID(), partitionID: 1)
        let journalFence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: .distantFuture, routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        // Even an independently valid lower-level legacy room projection cannot
        // reenter the production user/session-control receiver's room socket path.
        try #require(receiver.install(source: source, serviceID: "fixture", fence: journalFence,
            deadline: .now + .seconds(30), rooms: [room], viewers: [user]))
        let snapshot = V2RealtimeJournalProjectionBatch(source: source, fence: journalFence,
            payload: .snapshot(cut: 1, rooms: [.init(roomID: room, ownerEpoch: 0, permissionVersion: 1,
                controlVersion: 1, viewerMembershipRevisions: [user: 1], highWatermark: 6)]))
        try #require(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "fixture") else {
            Issue.record("independent projection not installed"); return
        }
        await registry.configureJournalUserControlReceiver(receiver)
        let ingress = try await registry.configureRoomSubscriptionIngress(authority: authority)
        let writer = JournalHeadWriter()
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1),
                authenticator: JournalHeadAuthenticator(user: user), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: JournalHeadHandler(), connectionID: connection, registry: registry)
        let attached = await stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            requiredNotificationWriter: { _ in true }, scopedNotificationWriter: { await writer.write($0) })
        try #require(attached)
        do {
            var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device.rawValue
            hello.clientHello.supportedProtocolVersions = [UInt32(version)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
            auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device.rawValue
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
            _ = try await registry.subscribeForegroundRoom(stream, connectionID: connection, roomID: room)
            await registry.applySharedRealtimeDelivery(.init(topic: .init(kind: .roomEvents, id: room.rawValue, owner: owner),
                partitionID: source.partitionID, partitionEpoch: 1, sessionID: journalFence.sessionID,
                interestGeneration: 1, gatewayIncarnation: journalFence.gatewayIncarnationID,
                payload: .roomWake(roomID: room, highWatermark: 999)), isCurrent: { true })
            #expect(writer.readyHeads.isEmpty && writer.hints.isEmpty)

            let fence = V2RoomSubscriptionFence(activation: .init(roomID: room, owner: owner,
                activationEpoch: try .init(1), host: .init(hostID: try .init("owner-test"),
                    incarnationID: UUID(uuidString: "00000000-0000-0000-0000-00000000ac01")!)),
                subscriptionID: UUID(), generation: 1, baselineSequence: 10)
            try #require(await ingress.install(fence: fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
            #expect(await ingress.applyRoomSubscription(.init(fence: fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [.init(userID: user, memberRevision: 0)])),
                authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
            #expect(await ingress.applyRoomSubscription(.init(fence: fence, deliverySequence: 2, authorizationSequence: 1, payload: .head(highWatermark: 60)),
                authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
            try await waitUntil { writer.readyHeads == [10] && writer.hints.contains(60) }
            let head = V2RealtimeJournalProjectionBatch(source: source, fence: journalFence,
                payload: .heads([.init(roomID: room, highWatermark: 999, ownerEpoch: 0, controlVersion: 1)]))
            guard case .headsApplied = receiver.applyJournalProjection(head, authenticatedServiceID: "fixture") else {
                Issue.record("independent head not installed"); return
            }
            await registry.applySharedRealtimeDelivery(.init(topic: .init(kind: .roomEvents, id: room.rawValue, owner: owner),
                partitionID: source.partitionID, partitionEpoch: 1, sessionID: journalFence.sessionID,
                interestGeneration: 1, gatewayIncarnation: journalFence.gatewayIncarnationID,
                payload: .roomWake(roomID: room, highWatermark: 999)), isCurrent: { true })
            #expect(writer.readyHeads == [10])
            #expect(!writer.hints.contains(999))
            await registry.unsubscribeForegroundGroup(connectionID: connection, roomID: room)
            await stream.closeForAccountRecovery(); await registry.shutdownRealtimeRecovery(); receiver.shutdown()
        } catch {
            await writer.release(); await stream.closeForAccountRecovery()
            await registry.shutdownRealtimeRecovery(); receiver.shutdown(); throw error
        }
    }

    private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw JournalHeadFailure.timeout }
            await Task.yield()
        }
    }
}

private enum JournalHeadFailure: Error { case timeout }
private struct JournalHeadInterests: V2GroupEventWakeInterestManaging {
    func activate(roomID: RoomID) async throws {}
    func deactivate(roomID: RoomID) async {}
}
private struct JournalHeadAuthenticator: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        .init(userID: user, expiresAt: nil)
    }
}
private struct JournalHeadHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope { .init() }
}
private actor JournalHeadWriter {
    private struct Output: Sendable {
        var readyHeads: [UInt64] = []
        var hints: [UInt64] = []
        var bodies = 0
    }
    private nonisolated let output = Mutex(Output())
    nonisolated var readyHeads: [UInt64] { output.withLock { $0.readyHeads } }
    nonisolated var hints: [UInt64] { output.withLock { $0.hints } }
    nonisolated var liveBodies: Int { output.withLock { $0.bodies } }
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private var heldHead: UInt64 = 7
    private(set) var held = false
    func hold(_ head: UInt64) { heldHead = head; held = false; released = false }
    func release() { released = true; gate?.resume(); gate = nil }
    func write(_ write: V2GatewayScopedNotificationWrite) async -> Bool {
        let version = UInt8(IMV2ProtocolVersion.current)
        var decoder = V2FrameDecoder(limits: try! .init(maximumPayloadBytes: 4096, acceptedVersions: [version]))
        guard let frame = try? decoder.append(write.bytes).first,
              let envelope = try? V2ServerProtobufFrameCodec.decode(frame) else { return false }
        let ready: UInt64?
        if case .realtimeCoverage(let coverage)? = envelope.body, coverage.scope == .room, coverage.state == .ready {
            ready = coverage.highWatermark
        } else { ready = nil }
        let hint: UInt64?, body: Bool
        if case .groupEventAvailable(let value)? = envelope.body {
            hint = value.highWatermark; body = !value.eventPayload.isEmpty || !value.liveEvents.isEmpty
        } else { hint = nil; body = false }
        if hint == heldHead, !released { held = true; await withCheckedContinuation { gate = $0 } }
        return write.enqueueIfCurrent {
            self.output.withLock {
                if let ready { $0.readyHeads.append(ready) }
                if let hint { $0.hints.append(hint) }
                if body { $0.bodies += 1 }
            }
        }
    }
}
