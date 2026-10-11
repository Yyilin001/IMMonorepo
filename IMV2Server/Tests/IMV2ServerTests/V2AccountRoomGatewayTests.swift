@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("Account room gateway protocol", .timeLimit(.minutes(1)))
struct V2AccountRoomGatewayTests {
    @Test("device transport closure completes before suspended account route cleanup")
    func revocationTransportPrecedesCleanup() async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits), cleanup = CoverageInstallGate()
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), connection = UUID()
        let activated = Mutex(false), closed = Mutex(0), finished = Mutex(false)
        let service = try V2AccountRoomChangeService(states: GatewayCoverageStates(recordRead: {}),
            directoryPage: { _, _ in
                .init(rooms: [try .init(roomID: room, roomKind: .group,
                    viewerMembershipRevision: 1, ownerEpoch: 1)], nextCursor: nil, topologyGeneration: "stable")
            }, onlineDelivery: .init(activate: { _, _, _ in activated.withLock { $0 = true } },
                deactivate: { _ in await cleanup.suspendOnce() }))
        await registry.configureAccountRoomChanges(service)
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [0, version]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: FixedCoverageAuth(user: user),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: GatewayCoverageCommands(registry: registry, rooms: []), connectionID: connection, registry: registry)
        try #require(await stream.attachFixtureTransport(deviceRevocationHandler: { closed.withLock { $0 += 1 } },
            outboundWriter: { _ in }, requiredNotificationWriter: { _ in true },
            scopedNotificationWriter: { write in write.enqueueIfCurrent({}) }))
        let device = UUID().uuidString
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await exchange(hello, stream: stream, version: 0)
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device
        _ = try await exchange(auth, stream: stream)
        let deadline = ContinuousClock.now + .seconds(2)
        while !activated.withLock({ $0 }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(activated.withLock { $0 })
        await cleanup.arm()
        await stream.closeTransportForDeviceRevocation()
        #expect(closed.withLock { $0 } == 1)
        let retirement = Task { await stream.revokeDevice(); finished.withLock { $0 = true } }
        await cleanup.waitUntilSuspended()
        #expect(!finished.withLock { $0 })
        // Repeated close joins only the already completed physical phase.
        await stream.closeTransportForDeviceRevocation()
        #expect(closed.withLock { $0 } == 1)
        await cleanup.release()
        await retirement.value
        #expect(finished.withLock { $0 })
        await service.shutdown(); await registry.shutdownRealtimeRecovery()
    }

    @Test("Start and directory pages preserve server-owned coverage without head queries", arguments: [false, true])
    func protocolLifecycle(duringInstallation: Bool) async throws {
        try await runLifecycle(duringInstallation: duringInstallation)
    }

    @Test("concurrent Start cannot replace the installing directory write fence")
    func concurrentStartKeepsInstallingFence() async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits), gate = CoverageInstallGate()
        let user = UserID(uuid: UUID()), connection = UUID(), device = UUID().uuidString
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [0, version]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: FixedCoverageAuth(user: user),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: GatewayCoverageCommands(registry: registry, rooms: []), connectionID: connection, registry: registry)
        try #require(await stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            requiredNotificationWriter: { _ in true }, scopedNotificationWriter: { write in
                await gate.suspendOnce()
                return write.enqueueIfCurrent({})
            }))
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await exchange(hello, stream: stream, version: 0)
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device
        _ = try await exchange(auth, stream: stream)
        let scans = Mutex(0)
        let service = try V2AccountRoomChangeService(states: GatewayCoverageStates(recordRead: {}),
            directoryPage: { _, _ in scans.withLock { $0 += 1 }; return .init(rooms: [], nextCursor: nil, topologyGeneration: "stable") },
            onlineDelivery: .init(activate: { _, _, _ in }, deactivate: { _ in }))
        await gate.arm()
        await registry.configureAccountRoomChanges(service)
        let installation = Task { try await registry.startAccountRoomChanges(connectionID: connection, userID: user) }
        await gate.waitUntilSuspended()
        let joinedEpoch = try await registry.startAccountRoomChanges(connectionID: connection, userID: user)
        await gate.release()
        do { _ = try await installation.value }
        catch V2RealtimePublicationBackpressure.receiverQueue {}
        let deadline = ContinuousClock.now + .seconds(2)
        var epoch: String?
        while epoch == nil, ContinuousClock.now < deadline {
            do { epoch = try await registry.startAccountRoomChanges(connectionID: connection, userID: user) }
            catch V2RealtimePublicationBackpressure.receiverQueue { await Task.yield() }
        }
        try #require(epoch != nil)
        #expect(epoch == joinedEpoch)
        #expect(scans.withLock { $0 } == 1)
        await stream.closeForAccountRecovery(); await registry.unregister(connectionID: connection)
        await service.shutdown(); await registry.shutdownRealtimeRecovery()
    }

    private func runLifecycle(duringInstallation: Bool) async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let broker = GatewayCoverageInterest()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let rooms = (0..<129).map { _ in RoomID(uuid: UUID()) }
        let stateReads = Synchronization.Mutex(0)
        let service = try V2AccountRoomChangeService(states: GatewayCoverageStates(recordRead: { stateReads.withLock { $0 += 1 } }),
            directoryPage: { _, cursor in
                let slice = cursor == nil ? Array(rooms.prefix(100)) : Array(rooms.dropFirst(100))
                return .init(rooms: try slice.map { try .init(roomID: $0, roomKind: .group,
                    viewerMembershipRevision: 1, ownerEpoch: 1) },
                    nextCursor: cursor == nil ? "next" : nil, topologyGeneration: "fixture")
            }, onlineDelivery: .init(activate: { _, room, reference in try await broker.activate(roomID: room, reference: reference) },
                deactivate: { reference in await broker.deactivate(reference: reference) }))
        await registry.configureAccountRoomChanges(service)
        if duringInstallation { await broker.pauseNext() }
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [0, version]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: GatewayCoverageAuth(),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: GatewayCoverageCommands(registry: registry, rooms: rooms), registry: registry)
        let recorder = CoverageFrameRecorder()
        do {
        #expect(await stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            requiredNotificationWriter: { bytes in await recorder.record(bytes); return true },
            scopedNotificationWriter: { write in
                guard write.enqueueIfCurrent({}) else { return false }
                guard let frame = try? V2FrameCodec.decodeExactlyOne(write.bytes,
                    limits: .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [version])),
                    let envelope = try? V2ServerProtobufFrameCodec.decode(frame) else { return false }
                if case .accountRoomResyncRequired = envelope.body {
                    await recorder.record(write.bytes)
                }
                return true
            }))
        let handshakeDeviceID = UUID().uuidString
        var hello = IMV2Envelope(); hello.requestID = 1
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        hello.clientHello.deviceID = handshakeDeviceID
        _ = try await exchange(hello, stream: stream, version: 0)
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "test-token"; auth.authenticate.deviceID = handshakeDeviceID
        _ = try await exchange(auth, stream: stream)
        var start = IMV2Envelope(); start.requestID = 3; start.protocolVersion = UInt32(version)
        start.accountRoomChangesStart = .init()
        if duringInstallation {
            await broker.waitUntilPaused()
            let pending = try await exchange(start, stream: stream)
            #expect(pending.error.code == "UNAVAILABLE" && pending.error.retryable)
            #expect(await broker.rooms.isEmpty)
            await broker.release()
        }
        var ready = try await exchange(start, stream: stream)
        let deadline = ContinuousClock.now + .seconds(3)
        while case .error = ready.body, ready.error.retryable, ContinuousClock.now < deadline {
            await Task.yield()
            start.requestID += 1
            ready = try await exchange(start, stream: stream)
        }
        #expect(UUID(uuidString: ready.accountRoomChangesReady.connectionEpoch) != nil)
        #expect(await broker.rooms.count == 129)
        let oldRoomTopic = V2RealtimeTopic(kind: .roomEvents, id: rooms[128].rawValue,
            owner: try .init(shardID: "fixture", epoch: 0))
        #expect(try await registry.arrangeRealtimeRecoveryHeads([oldRoomTopic: 8]).isEmpty)
        #expect(stateReads.withLock { $0 } == 0)
        var directory = IMV2Envelope(); directory.requestID = start.requestID + 1; directory.protocolVersion = UInt32(version)
        directory.userRoomDirectoryList.pageSize = 100
        let first = try await exchange(directory, stream: stream)
        #expect(first.userRoomDirectoryPage.rooms.count == 100)
        directory.requestID += 1
        directory.userRoomDirectoryList.cursor = first.userRoomDirectoryPage.nextCursor
        let last = try await exchange(directory, stream: stream)
        #expect(last.userRoomDirectoryPage.rooms.count == 29)
        #expect(await broker.rooms.count == 129)
        #expect(await registry.activeForegroundGroupMetrics().rooms == 0)
        #expect(stateReads.withLock { $0 } == 0)
        var personal = IMV2Envelope(); personal.requestID = 6; personal.protocolVersion = UInt32(version)
        personal.syncPull = .init()
        let discovery = try await exchange(personal, stream: stream)
        #expect(discovery.syncBatch.records.count == 1)
        #expect(await broker.rooms.count == 129)
        var snapshot = IMV2Envelope(); snapshot.requestID = 7; snapshot.protocolVersion = UInt32(version)
        snapshot.snapshotPagePull = .init()
        _ = try await exchange(snapshot, stream: stream)
        #expect(await broker.rooms.count == 129)
        let priorEpoch = ready.accountRoomChangesReady.connectionEpoch
        await registry.invalidateAccountRoomCoverage()
        start.requestID = 1000
        ready = try await exchange(start, stream: stream)
        let rebuildDeadline = ContinuousClock.now + .seconds(3)
        while case .error = ready.body, ready.error.retryable, ContinuousClock.now < rebuildDeadline {
            await Task.yield()
            start.requestID += 1
            ready = try await exchange(start, stream: stream)
        }
        #expect(UUID(uuidString: ready.accountRoomChangesReady.connectionEpoch) != nil)
        #expect(ready.accountRoomChangesReady.connectionEpoch != priorEpoch)
        #expect(await broker.rooms.count == 129)
        try await stream.finish()
        #expect(await broker.rooms.isEmpty)
        await service.shutdown()
        await interests.shutdown()
        } catch {
            await broker.release()
            try? await stream.finish()
            await service.shutdown()
            await interests.shutdown()
                throw error
        }
    }

    private var version: UInt8 { UInt8(IMV2ProtocolVersion.current) }
    private func exchange(_ envelope: IMV2Envelope, stream: V2GatewayByteStream, version: UInt8? = nil) async throws -> IMV2Envelope {
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version ?? self.version)
        let bytes = try V2FrameCodec.encode(frame, limits: .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [0, self.version]))
        var result: IMV2Envelope?
        _ = try await stream.receiveFrames(bytes) {
            result = try V2ServerProtobufFrameCodec.decode($0)
        }
        return try #require(result)
    }
}

private struct GatewayCoverageAuth: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init(uuid: UUID()), expiresAt: nil)
    }
}

private struct GatewayCoverageCommands: V2GatewayCommandHandler {
    let registry: V2DeviceConnectionRegistry
    let rooms: [RoomID]
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        throw V2AccountRoomChangeService.Failure.staleConnection
    }
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection, originatingConnectionID: UUID?) async throws -> IMV2Envelope {
        var response = IMV2Envelope()
        switch envelope.body {
        case .accountRoomChangesStart:
            let connection = try #require(originatingConnectionID)
            do {
                response.accountRoomChangesReady.connectionEpoch = try await registry.startAccountRoomChanges(connectionID: connection, userID: identity.userID)
            } catch V2AccountRoomChangeService.Failure.closed, V2AccountRoomChangeService.Failure.staleConnection {
                response.error.code = "UNAVAILABLE"; response.error.retryable = true
            } catch V2RealtimePublicationBackpressure.receiverQueue {
                response.error.code = "UNAVAILABLE"; response.error.retryable = true
            }
        case .snapshotPagePull:
            let room = RoomID(uuid: UUID())
            let payload = try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": room.rawValue,
                "target_user_id": identity.userID.rawValue, "action": "add", "membership_revision": 1
            ])
            let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "room", entityKey: room.rawValue),
                sourceEventID: .init(uuid: UUID()), sequence: 1, payload: payload)
            response.snapshotPage.payload = try V2SnapshotProjectionV3Codec.encode(.init(items: [item]))
        case .syncPull:
            var record = IMV2SyncRecord()
            record.projectionKind = "membership"
            record.payload = try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": UUID().uuidString,
                "target_user_id": identity.userID.rawValue, "action": "add", "membership_revision": 1
            ])
            response.syncBatch.records = [record]
        case .userRoomDirectoryList(let request):
            let first = request.cursor.isEmpty
            response.userRoomDirectoryPage.rooms = (first ? Array(rooms.prefix(100)) : Array(rooms.dropFirst(100))).map { id in
                var room = IMV2UserRoomDirectoryEntry()
                room.roomID = id.rawValue; room.roomKind = "group"
                room.ownerEpoch = 1; room.viewerMembershipRevision = 1
                return room
            }
            response.userRoomDirectoryPage.nextCursor = first ? "next" : ""
            response.userRoomDirectoryPage.topologyGeneration = "fixture"
        default: throw V2AccountRoomChangeService.Failure.staleConnection
        }
        return response
    }
}

private actor GatewayCoverageInterest: V2GroupEventWakeInterestManaging {
    private var references: [UUID: RoomID] = [:]
    func activate(roomID: RoomID, reference: UUID) async throws {
        try await activate(roomID: roomID)
        references[reference] = roomID
    }
    func deactivate(reference: UUID) async {
        if let room = references.removeValue(forKey: reference) { await deactivate(roomID: room) }
    }
    private(set) var rooms: Set<RoomID> = []
    private var target: RoomID?
    private var pause = false
    private var paused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pauseNext(roomID: RoomID? = nil) { pause = true; target = roomID }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil; paused = false }
    func activate(roomID: RoomID) async throws {
        if pause && (target == nil || target == roomID) {
            pause = false; paused = true
            pauseWaiter?.resume(); pauseWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        try Task.checkCancellation()
        rooms.insert(roomID)
    }
    func deactivate(roomID: RoomID) async {
        rooms.remove(roomID)
    }
}

private struct GatewayCoverageStates: V2RoomStateReading {
    let recordRead: @Sendable () -> Void
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        recordRead()
        return try Dictionary(uniqueKeysWithValues: roomIDs.map { room in
            (room, .state(try .init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
                head: 8, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)))
        })
    }
}

private actor CoverageFrameRecorder {
    private var recorded: Data?
    func record(_ data: Data) {
        if recorded == nil { recorded = data }
    }
    func first() async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(3)
        while recorded == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(recorded, "account room wake was not written")
    }
}

private struct FixedCoverageAuth: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication { .init(userID: user, expiresAt: nil) }
}
private actor CoverageInstallGate {
    private var suspended: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var used = true
    func arm() { used = false }
    func suspendOnce() async {
        guard !used else { return }; used = true
        await withCheckedContinuation { suspended = $0; waiter?.resume(); waiter = nil }
    }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { suspended?.resume(); suspended = nil }
}
