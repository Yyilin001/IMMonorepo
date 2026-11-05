@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import Synchronization
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("Account recovery gateway protocol", .timeLimit(.minutes(1)))
struct V2AccountRoomGatewayTests {
    @Test("1000 rooms do not create Owner subscriptions during auth, Start, directory reads or reconnect")
    func thousandRoomReadiness() async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let service = V2AccountRoomChangeService(), user = UserID(uuid: UUID())
        let rooms = (0..<1000).map { _ in RoomID(uuid: UUID()) }
        await registry.configureAccountRoomChanges(service)
        // Deliberately no room Owner coordinator. Account readiness must be
        // available while every room host is unavailable; detail reads remain separate.
        var previousEpoch: String?
        for _ in 0..<3 {
            let stream = makeStream(registry: registry, user: user, connection: UUID(), rooms: rooms)
            try #require(await stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
                requiredNotificationWriter: { _ in true }, scopedNotificationWriter: { $0.enqueueIfCurrent({}) }))
            try await authenticate(stream)
            var start = IMV2Envelope(); start.requestID = 3; start.protocolVersion = UInt32(version)
            start.accountRoomChangesStart = .init()
            let ready = try await exchange(start, stream: stream)
            let epoch = ready.accountRoomChangesReady.connectionEpoch
            #expect(UUID(uuidString: epoch) != nil && epoch != previousEpoch)
            let metrics = await service.initializationMetricsSnapshot()
            #expect(metrics.accounts == 1 && metrics.readyAccounts == 1 && metrics.active == 0 && metrics.queued == 0)
            var directory = IMV2Envelope(); directory.requestID = 4; directory.protocolVersion = UInt32(version)
            directory.userRoomDirectoryList.pageSize = 100
            var discovered = 0
            repeat {
                let page = try await exchange(directory, stream: stream).userRoomDirectoryPage
                discovered += page.rooms.count
                directory.userRoomDirectoryList.cursor = page.nextCursor
                directory.requestID += 1
            } while !directory.userRoomDirectoryList.cursor.isEmpty
            #expect(discovered == 1000)
            #expect(await registry.activeForegroundGroupMetrics().rooms == 0)
            start.requestID = directory.requestID + 1
            #expect(try await exchange(start, stream: stream).accountRoomChangesReady.connectionEpoch == epoch)
            previousEpoch = epoch
            try await stream.finish()
            #expect(await service.initializationMetricsSnapshot().accounts == 0)
        }
        await service.shutdown(); await registry.shutdownRealtimeRecovery()
    }

    @Test("concurrent Start and delayed directory-state writes retain one epoch")
    func concurrentStartKeepsInstallingFence() async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits), gate = CoverageInstallGate()
        let user = UserID(uuid: UUID()), connection = UUID()
        let stream = makeStream(registry: registry, user: user, connection: connection, rooms: [])
        try #require(await stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            requiredNotificationWriter: { _ in true }, scopedNotificationWriter: { write in
                await gate.suspendOnce(); return write.enqueueIfCurrent({})
            }))
        try await authenticate(stream)
        let service = V2AccountRoomChangeService()
        await registry.configureAccountRoomChanges(service)
        await gate.arm()
        let installation = Task { try await registry.startAccountRoomChanges(connectionID: connection, userID: user) }
        await gate.waitUntilSuspended()
        var joined: String?
        do { joined = try await registry.startAccountRoomChanges(connectionID: connection, userID: user) }
        catch V2RealtimePublicationBackpressure.receiverQueue {}
        await gate.release()
        let first = try await installation.value
        let second = try await registry.startAccountRoomChanges(connectionID: connection, userID: user)
        #expect(first == second && (joined == nil || joined == second))
        #expect(await service.initializationMetricsSnapshot().completed == 1)
        try await stream.finish(); await service.shutdown(); await registry.shutdownRealtimeRecovery()
    }

    @Test("account epoch retirement preserves the authenticated transport and permits immediate replacement")
    func retireAndRestartEpoch() async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let service = V2AccountRoomChangeService(), user = UserID(uuid: UUID()), connection = UUID(), closed = Mutex(0)
        await registry.configureAccountRoomChanges(service)
        let stream = makeStream(registry: registry, user: user, connection: connection, rooms: [])
        try #require(await stream.attachFixtureTransport(deviceRevocationHandler: { closed.withLock { $0 += 1 } },
            outboundWriter: { _ in }, requiredNotificationWriter: { _ in true }, scopedNotificationWriter: { $0.enqueueIfCurrent({}) }))
        try await authenticate(stream)
        let first = try await registry.startAccountRoomChanges(connectionID: connection, userID: user)
        try await registry.accountRoomChangesReadyWritten(connectionID: connection, epoch: first)
        await registry.invalidateAccountRoomCoverage()
        var second: String?
        let deadline = ContinuousClock.now + .seconds(3)
        while second == nil {
            try #require(ContinuousClock.now < deadline)
            do { second = try await registry.startAccountRoomChanges(connectionID: connection, userID: user) }
            catch V2AccountRoomChangeService.Failure.staleConnection { await Task.yield() }
        }
        #expect(second != first && closed.withLock { $0 } == 0)
        await stream.closeTransportForDeviceRevocation()
        #expect(closed.withLock { $0 } == 1)
        await stream.revokeDevice()
        #expect(await service.initializationMetricsSnapshot().accounts == 0)
        await service.shutdown(); await registry.shutdownRealtimeRecovery()
    }

    private var version: UInt8 { UInt8(IMV2ProtocolVersion.current) }
    private func makeStream(registry: V2DeviceConnectionRegistry, user: UserID, connection: UUID, rooms: [RoomID]) -> V2GatewayByteStream {
        V2GatewayByteStream(frameLimits: try! .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [0, version]),
            session: .init(limits: try! .init(maximumInFlightRequests: 1), authenticator: FixedCoverageAuth(user: user),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: GatewayCoverageCommands(registry: registry, rooms: rooms), connectionID: connection, registry: registry)
    }
    private func authenticate(_ stream: V2GatewayByteStream) async throws {
        let device = UUID().uuidString
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await exchange(hello, stream: stream, version: 0)
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device
        _ = try await exchange(auth, stream: stream)
    }
    private func exchange(_ envelope: IMV2Envelope, stream: V2GatewayByteStream, version: UInt8? = nil) async throws -> IMV2Envelope {
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version ?? self.version)
        let bytes = try V2FrameCodec.encode(frame, limits: .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [0, self.version]))
        var result: IMV2Envelope?
        _ = try await stream.receiveFrames(bytes) { result = try V2ServerProtobufFrameCodec.decode($0) }
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
            let offset = Int(request.cursor) ?? 0
            let end = min(rooms.count, offset + 100)
            response.userRoomDirectoryPage.rooms = rooms[offset..<end].map { id in
                var room = IMV2UserRoomDirectoryEntry()
                room.roomID = id.rawValue; room.roomKind = "group"
                room.ownerEpoch = 1; room.viewerMembershipRevision = 1
                return room
            }
            response.userRoomDirectoryPage.nextCursor = end < rooms.count ? String(end) : ""
            response.userRoomDirectoryPage.topologyGeneration = "fixture"
        default: throw V2AccountRoomChangeService.Failure.staleConnection
        }
        return response
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
