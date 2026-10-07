import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Cross-Gateway same-account device scopes", .enabled(if:
    ProcessInfo.processInfo.environment["IMV2_LOCAL_ACCOUNT_E2E"] == "1" &&
    ProcessInfo.processInfo.environment["IMV2_CROSS_GATEWAY_MULTI_DEVICE_E2E"] == "1"))
struct V2CrossGatewayMultiDeviceIntegrationTests {
    @Test func oldSocketUnsubscribePreservesBothCurrentDeviceScopes() async throws {
        let environment = ProcessInfo.processInfo.environment
        let primary = environment["IMV2_CROSS_GATEWAY_PRIMARY_PORT"].flatMap(UInt16.init) ?? 7_443
        let secondary = try #require(environment["IMV2_ROOM_RECOVERY_SECONDARY_PORT"].flatMap(UInt16.init))
        guard primary != secondary else { throw ScopeFailure.rejected }
        let sender = try await registerLocalAccount(displayName: "Scope sender")
        let receiver = try await registerLocalAccount(displayName: "Scope receiver")
        let sibling = try await registerSiblingLocalDevice(receiver)
        #expect(sibling.deviceID != receiver.deviceID)
        let room = try await localOpenDirectRoom(account: sender, target: receiver.userID).roomID
        let limits = try V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-device-scopes-\(UUID())")
        let senderWire = V2TLSFrameConnection(endpoint: try .init(host: "localhost", port: primary), frameLimits: limits)
        let old = try Peer(port: primary, limits: limits, root: root, name: "old", userID: receiver.userID)
        let device1 = try Peer(port: secondary, limits: limits, root: root, name: "device1", userID: receiver.userID)
        let device2 = try Peer(port: secondary, limits: limits, root: root, name: "device2", userID: receiver.userID)
        var observers: [Task<Void, Never>] = []
        do {
            let senderSession = try await senderWire.connectAndAuthenticate(accessToken: sender.accessToken,
                deviceID: sender.deviceID, supportedCapabilityProfiles: ["base"])
            let senderTransport = V2ProtobufSyncTransport(wire: senderWire, protocolVersion: senderSession.protocolVersion)
            // The old physical connection really precedes its same-device replacement.
            observers.append(try await old.start(accessToken: receiver.accessToken, deviceID: receiver.deviceID))
            observers.append(try await device2.start(accessToken: sibling.accessToken, deviceID: sibling.deviceID))
            observers.append(try await device1.start(accessToken: receiver.accessToken, deviceID: receiver.deviceID))
            print("IMV2_ACCOUNT_RECEIPT_STAGE authenticated")
            // Only the old connection has a foreground scope. Current devices
            // must receive the first message through automatic account coverage.
            try await old.subscribe(room: room, after: 0)
            print("IMV2_ACCOUNT_RECEIPT_STAGE old_foreground_ready")
            for peer in [device1, device2] {
                #expect(await peer.coverage.ready(room: room, atLeast: 0) == nil)
            }
            // Establish mutual messaging through the actual TCP operation adapter.
            print("IMV2_ACCOUNT_RECEIPT_STAGE receiver_send_ready=\(await device1.connection.messageSendSession() != nil)")
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while true {
                        let hint = try await senderWire.nextGroupEventAvailabilityHint()
                        if hint.roomID == room, hint.highWatermark > 0 { return }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw ScopeFailure.timeout
                }
                defer { group.cancelAll() }
                _ = try await send(account: receiver, room: room, text: "peer-reply", peer: device1)
                print("IMV2_ACCOUNT_RECEIPT_STAGE receiver_reply_committed")
                _ = try await group.next()
            }
            print("IMV2_ACCOUNT_RECEIPT_STAGE sender_send_ready=\(await senderWire.messageSendSession() != nil)")
            let first = try await send(account: sender, room: room, text: "all-three-receiver-sockets",
                connection: senderWire, transport: senderTransport)
            print("IMV2_ACCOUNT_RECEIPT_STAGE first_committed")
            for peer in [old, device1, device2] {
                try await peer.receiveAndPersist(room: room, sequence: first.roomSequence)
                print("IMV2_ACCOUNT_RECEIPT_STAGE first_persisted_\(peer.name)")
            }
            // Foreground scopes are created only after unopened-room receipt
            // and SQLite persistence have both been proven.
            for peer in [device1, device2] { try await peer.refreshReady(room: room, atLeast: first.roomSequence) }
            let firstGeneration = try #require(await device1.coverage.ready(room: room, atLeast: 0))
            let secondGeneration = try #require(await device2.coverage.ready(room: room, atLeast: 0))
            #expect(firstGeneration.connectionGeneration != secondGeneration.connectionGeneration)
            // Exact old room scope acknowledged first, then actual socket close.
            try await old.transport.unsubscribeFromGroupEvents(roomID: room)
            await old.connection.disconnect()
            let second = try await send(account: sender, room: room, text: "after-old-unsubscribe-and-close",
                connection: senderWire, transport: senderTransport)
            for peer in [device1, device2] {
                try await peer.receiveAndPersist(room: room, sequence: second.roomSequence)
                try await peer.refreshReady(room: room, atLeast: second.roomSequence)
                let state = try #require(await peer.coverage.ready(room: room, atLeast: 0))
                let expected = peer.name == "device1" ? firstGeneration : secondGeneration
                #expect(state.connectionGeneration == expected.connectionGeneration)
                #expect(state.scopeGeneration > expected.scopeGeneration)
                #expect(try await peer.store.groupEventCursor(roomID: room) >= state.highWatermark)
                let messages = try await peer.store.messages(in: room)
                #expect(messages.contains { $0.messageID == first.messageID })
                #expect(messages.contains { $0.messageID == second.messageID })
            }
            print("IMV2_REAL_TLS_TWO_DEVICES_OLD_SCOPE_CLEANUP_PASSED")
        } catch {
            await cleanup(sender: senderWire, peers: [old, device1, device2], observers: observers)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await cleanup(sender: senderWire, peers: [old, device1, device2], observers: observers)
        try? FileManager.default.removeItem(at: root)
    }

    private struct Peer: Sendable {
        let name: String
        let userID: UserID
        let connection: V2TLSFrameConnection
        let transport: V2ProtobufSyncTransport
        let store: GRDBV2LocalSyncStore
        let coverage = ScopeCoverage()
        init(port: UInt16, limits: V2FrameLimits, root: URL, name: String, userID: UserID) throws {
            self.name = name; self.userID = userID
            connection = V2TLSFrameConnection(endpoint: try .init(host: "localhost", port: port), frameLimits: limits)
            transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: UInt8(IMV2ProtocolVersion.current))
            store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("\(name).sqlite"),
                installationBinding: .init(value: UUID()), userID: userID)
        }
        func start(accessToken: String, deviceID: DeviceID) async throws -> Task<Void, Never> {
            let session = try await connection.connectAndAuthenticate(accessToken: accessToken, deviceID: deviceID, supportedCapabilityProfiles: ["base"])
            #expect(session.userID == userID)
            try await synchronizeInitialState(V2SyncEngine(transport: transport, store: store, capabilityProfile: session.capabilityProfile))
            let stream = await connection.realtimeCoverageChanges()
            return Task { for await state in stream { if Task.isCancelled { return }; await coverage.receive(state) } }
        }
        func subscribe(room: RoomID, after: UInt64) async throws {
            let previousGeneration = await coverage.latest?.scopeGeneration ?? 0
            let subscribed = try await transport.subscribeToGroupEvents(roomID: room, afterRoomSequence: after)
            print("IMV2_ACCOUNT_RECEIPT_STAGE subscribe_\(name)_cursor=\(after)_head=\(subscribed.highWatermark)")
            try await waitUntil {
                guard let ready = await coverage.ready(room: room, atLeast: subscribed.highWatermark) else { return false }
                return ready.scopeGeneration > previousGeneration
            }
            print("IMV2_ACCOUNT_RECEIPT_STAGE subscribed_ready_\(name)")
        }
        func receiveAndPersist(room: RoomID, sequence: UInt64) async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while true {
                        let hint = try await connection.nextGroupEventAvailabilityHint()
                        if hint.roomID == room, hint.highWatermark >= sequence { return }
                    }
                }
                group.addTask { try await Task.sleep(for: .seconds(10)); throw ScopeFailure.timeout }
                defer { group.cancelAll() }; _ = try await group.next()
            }
            try await V2GroupEventSyncEngine(transport: transport, store: store).synchronizeUntilCaughtUp(roomID: room)
            #expect(try await store.groupEventCursor(roomID: room) >= sequence)
        }
        func refreshReady(room: RoomID, atLeast: UInt64) async throws {
            // Ready proves a subscription barrier, not the newly emitted message.
            // Only the actual persisted cursor supplies this re-subscribe cursor.
            let cursor = try await store.groupEventCursor(roomID: room)
            #expect(cursor >= atLeast)
            try await transport.unsubscribeFromGroupEvents(roomID: room)
            try await subscribe(room: room, after: cursor)
            // Ready's installation baseline is immutable; the persisted cursor
            // above separately proves catch-up through the requested message.
            try await waitUntil { await coverage.ready(room: room, atLeast: 0) != nil }
        }
    }
    private actor ScopeCoverage {
        var latest: V2RealtimeCoverageState?
        func receive(_ state: V2RealtimeCoverageState) {
            if state.scope == .room {
                latest = state
                print("IMV2_ACCOUNT_RECEIPT_COVERAGE status=\(state.status.rawValue) head=\(state.highWatermark) scope=\(state.scopeGeneration)")
            }
        }
        func ready(room: RoomID, atLeast: UInt64) -> V2RealtimeCoverageState? {
            guard let state = latest, state.status == .ready, (try? RoomID(state.scopeID)) == room,
                  state.highWatermark >= atLeast else { return nil }; return state
        }
    }
    private enum ScopeFailure: Error { case timeout, rejected }
    private func send(account: LocalE2EAccountCredentials, room: RoomID, text: String, peer: Peer) async throws -> V2MessageOperationAcceptance {
        try await send(account: account, room: room, text: text, connection: peer.connection, transport: peer.transport)
    }
    private func send(account: LocalE2EAccountCredentials, room: RoomID, text: String,
                      connection: V2TLSFrameConnection, transport: V2ProtobufSyncTransport) async throws -> V2MessageOperationAcceptance {
        let command = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: account.userID,
            clientMessageID: .init(uuid: UUID()), text: text, media: [], mentions: [], limits: .init(maxUTF8Bytes: 65_536)),
            firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000))
        let result = try await V2ProtobufMessageSendOperationClient(transport: transport, connection: connection).submit(command)
        guard case .receipt(let receipt) = result, receipt.validates(identity: try command.identity, fingerprint: try command.fingerprint),
              case .accepted(let accepted) = receipt.outcome else { throw ScopeFailure.rejected }
        return accepted
    }
    private func cleanup(sender: V2TLSFrameConnection, peers: [Peer], observers: [Task<Void, Never>]) async {
        for observer in observers { observer.cancel() }
        for peer in peers { await peer.connection.disconnect() }
        await sender.disconnect()
        for observer in observers { _ = await observer.result }
        for peer in peers { try? await peer.store.close() }
    }
}
private func waitUntil(_ predicate: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw V2CrossGatewayWaitFailure.timeout }
        try await Task.sleep(for: .milliseconds(20))
    }
}
private enum V2CrossGatewayWaitFailure: Error { case timeout }
