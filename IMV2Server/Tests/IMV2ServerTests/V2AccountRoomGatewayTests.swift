@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("Account room gateway protocol", .timeLimit(.minutes(1)))
struct V2AccountRoomGatewayTests {
    @Test("Start, directory pages and a room wake reach an unsubscribed room through the byte stream", arguments: [false, true])
    func protocolLifecycle(duringInstallation: Bool) async throws {
        try await runLifecycle(duringInstallation: duringInstallation)
    }

    @Test("real NATS delivers a wake while directory installation has not returned",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_REAL_NATS_URL"] != nil))
    func realNATSInstallationWindow() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["IMV2_REAL_NATS_URL"])
        try await runLifecycle(duringInstallation: true, natsURL: #require(URL(string: address)))
    }

    private func runLifecycle(duringInstallation: Bool, natsURL: URL? = nil) async throws {
        let registry = V2DeviceConnectionRegistry()
        let realBroker: V2NATSGroupEventWakeBroker?
        if let natsURL {
            let configuration = try V2NATSGroupEventWakeConfiguration(url: natsURL,
                subjectPrefix: "imv2.install." + UUID().uuidString.lowercased(),
                routingKey: Data(repeating: 27, count: 32), acknowledgementTimeout: 2)
            realBroker = V2NATSGroupEventWakeBroker(configuration: configuration, receiveWake: { event in
                if case .wake(let wake) = event {
                    await registry.notifyForegroundGroupAvailable(roomID: wake.roomID, highWatermark: wake.highWatermark)
                }
            })
        } else { realBroker = nil }
        let broker = GatewayCoverageInterest(underlying: realBroker)
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: GatewayCoverageStates(), interests: interests)
        await registry.configureAccountRoomChanges(service)
        let rooms = (0..<129).map { _ in RoomID(uuid: UUID()) }
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [0, version]),
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: GatewayCoverageAuth(),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: GatewayCoverageCommands(registry: registry, rooms: rooms), registry: registry)
        let recorder = CoverageFrameRecorder()
        do {
        #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            requiredNotificationWriter: { bytes in await recorder.record(bytes); return true }))
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
        let ready = try await exchange(start, stream: stream)
        #expect(UUID(uuidString: ready.accountRoomChangesReady.connectionEpoch) != nil)
        var directory = IMV2Envelope(); directory.requestID = 4; directory.protocolVersion = UInt32(version)
        directory.userRoomDirectoryList.pageSize = 100
        let first = try await exchange(directory, stream: stream)
        #expect(first.userRoomDirectoryPage.rooms.count == 100)
        #expect(await broker.rooms.count == 100)
        directory.requestID = 5
        directory.userRoomDirectoryList.cursor = first.userRoomDirectoryPage.nextCursor
        let last: IMV2Envelope
        if duringInstallation {
            await broker.pauseNext(roomID: realBroker == nil ? nil : rooms[128])
            let request = directory
            let response = DirectoryResponseProbe()
            let pending = Task {
                try await exchange(request, stream: stream, onResponse: { await response.record() })
            }
            defer { pending.cancel() }
            await broker.waitUntilPaused()
            // All page entries are indexed before the first broker activation
            // finishes. A wake may arrive before the directory response.
            #expect(await broker.rooms.count == (realBroker == nil ? 100 : 128))
            #expect(await !response.received)
            if let realBroker {
                try await realBroker.publish(.init(roomID: rooms[128], highWatermark: 8))
            } else {
                await registry.notifyForegroundGroupAvailable(roomID: rooms[128], highWatermark: 8)
            }
            _ = await recorder.first()
            #expect(await broker.rooms.count == (realBroker == nil ? 100 : 128))
            #expect(await !response.received)
            await broker.release()
            last = try await pending.value
            #expect(await response.received)
        } else {
            last = try await exchange(directory, stream: stream)
        }
        #expect(last.userRoomDirectoryPage.rooms.count == 29)
        #expect(await broker.rooms.count == 129)
        #expect(await registry.activeForegroundGroupMetrics().rooms == 0)
        if !duringInstallation {
            await registry.notifyForegroundGroupAvailable(roomID: rooms[128], highWatermark: 8)
        }
        let bytes = await recorder.first()
        let frame = try V2FrameCodec.decodeExactlyOne(bytes, limits: .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [version]))
        let notification = try V2ServerProtobufFrameCodec.decode(frame)
        #expect(notification.accountRoomChanged.roomID == rooms[128].rawValue)
        #expect(notification.accountRoomChanged.connectionEpoch == ready.accountRoomChangesReady.connectionEpoch)
        #expect(notification.accountRoomChanged.notificationSequence == 1)
        #expect(notification.requestID == 0)
        var personal = IMV2Envelope(); personal.requestID = 6; personal.protocolVersion = UInt32(version)
        personal.syncPull = .init()
        let discovery = try await exchange(personal, stream: stream)
        #expect(discovery.syncBatch.records.count == 1)
        #expect(await broker.rooms.count == 130)
        var snapshot = IMV2Envelope(); snapshot.requestID = 7; snapshot.protocolVersion = UInt32(version)
        snapshot.snapshotPagePull = .init()
        _ = try await exchange(snapshot, stream: stream)
        #expect(await broker.rooms.count == 131)
        try await stream.finish()
        #expect(await broker.rooms.isEmpty)
        await service.shutdown()
        await interests.shutdown()
        await realBroker?.shutdown()
        } catch {
            await broker.release()
            try? await stream.finish()
            await service.shutdown()
            await interests.shutdown()
            await realBroker?.shutdown()
            throw error
        }
    }

    private var version: UInt8 { UInt8(IMV2ProtocolVersion.current) }
    private func exchange(_ envelope: IMV2Envelope, stream: V2GatewayByteStream, version: UInt8? = nil,
                          onResponse: @Sendable () async -> Void = {}) async throws -> IMV2Envelope {
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version ?? self.version)
        let bytes = try V2FrameCodec.encode(frame, limits: .init(maximumPayloadBytes: 48 * 1024, acceptedVersions: [0, self.version]))
        var result: IMV2Envelope?
        _ = try await stream.receiveFrames(bytes) {
            result = try V2ServerProtobufFrameCodec.decode($0)
            await onResponse()
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
            response.accountRoomChangesReady.connectionEpoch = try await registry.startAccountRoomChanges(connectionID: connection, userID: identity.userID)
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
    private(set) var rooms: Set<RoomID> = []
    private let underlying: V2NATSGroupEventWakeBroker?
    init(underlying: V2NATSGroupEventWakeBroker? = nil) { self.underlying = underlying }
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
        try await underlying?.activate(roomID: roomID)
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
        await underlying?.deactivate(roomID: roomID)
    }
}

private struct GatewayCoverageStates: V2RoomStateReading {
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        try Dictionary(uniqueKeysWithValues: roomIDs.map { room in
            (room, .state(try .init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
                head: 8, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)))
        })
    }
}

private actor CoverageFrameRecorder {
    private var recorded: Data?
    private var waiter: CheckedContinuation<Data, Never>?
    func record(_ data: Data) {
        if recorded == nil { recorded = data }
        waiter?.resume(returning: recorded!); waiter = nil
    }
    func first() async -> Data {
        if let recorded { return recorded }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private actor DirectoryResponseProbe {
    private(set) var received = false
    func record() { received = true }
}
