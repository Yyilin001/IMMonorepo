import Foundation
import IMV2ClientKit
import IMV2Core
import XCTest

extension IMAppRoomRecoveryScaleTests {
    func verifyMembershipRace(connection: V2TLSFrameConnection, coordinator: V2RealtimeSessionCoordinator,
                              account: LocalE2EAccountCredentials, store: GRDBV2LocalSyncStore) async throws {
        let owner = try await registerLocalAccount(displayName: "Recovery membership owner")
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SECONDARY_PORT"].flatMap(UInt16.init))
        let ownerConnection = V2TLSFrameConnection(endpoint: try .init(host: "localhost", port: port),
            frameLimits: try .init(maximumPayloadBytes: 65536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]))
        do {
            let ownerSession = try await ownerConnection.connectAndAuthenticate(accessToken: owner.accessToken,
                deviceID: owner.deviceID, supportedCapabilityProfiles: ["base"])
            let ownerTransport = V2ProtobufSyncTransport(wire: ownerConnection, protocolVersion: ownerSession.protocolVersion)
            let operation = try GroupRoomOperationID(UUID().uuidString.lowercased())
            let roomID = try await owner.createGroup(operationID: operation, title: "Recovery membership race", members: [account.userID])
            let members = try await ownerTransport.listRoomMembers(roomID: roomID, cursor: nil, pageSize: 10)
            let initial = try await owner.sendMessage(roomID: roomID,
                clientMessageID: .init(UUID().uuidString.lowercased()), text: "membership-before-scan", media: [], mentions: [])
            let session = try await coordinator.connect()
            let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
            let personal = V2SyncEngine(transport: transport, store: store, capabilityProfile: session.capabilityProfile)
            try await synchronizeInitialState(personal)
            let race = RecoveryMembershipRaceTransport(transport: transport, owner: owner,
                roomID: roomID, userID: account.userID, membershipRevision: members.membershipRevision,
                initialHead: initial.roomSequence)
            for attempt in 0..<3 {
                do {
                    let engine = V2RoomRecoveryEngine(transport: race, latestVisible: transport, store: store,
                        groupEvents: V2GroupEventSyncEngine(transport: transport, store: store))
                    let runner = V2RoomRecoveryRunner(engine: engine, source: connection, personalSync: personal,
                        integrityInterval: { 3600 })
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await runner.run(userID: account.userID) }
                        group.addTask {
                            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
                            while true {
                                if let head = await race.finalHead, await engine.phase == .live {
                                    let messages = try await store.messages(in: roomID)
                                    guard !messages.contains(where: { $0.text == "membership-gap" }) else {
                                        throw V2RealtimeTransportError.unexpectedResponse
                                    }
                                    if messages.contains(where: { $0.text == "membership-after-rejoin" }),
                                       try await store.groupEventCursor(roomID: roomID) == head,
                                       try await store.groupEventAccess(roomID: roomID)?.isAuthorized == true { break }
                                }
                                guard ContinuousClock.now < deadline else { throw V2RealtimeTransportError.unexpectedResponse }
                                try await Task.sleep(for: .milliseconds(20))
                            }
                            print("IMV2_TLS_ROOM_MEMBERSHIP_RACE_PASSED")
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                    break
                } catch V2RoomRecoveryEngineError.coverageLost where attempt < 2 {
                    await coordinator.disconnect()
                    _ = try await coordinator.connect()
                } catch V2TLSFrameConnectionError.connectionClosed where attempt < 2 {
                    await coordinator.disconnect()
                    _ = try await coordinator.connect()
                }
            }
            try await verifyJoinAfterDirectory(connection: connection, coordinator: coordinator, account: account,
                store: store, owner: owner, ownerTransport: ownerTransport, roomID: roomID)
            try await verifyUnknownJoinAfterDirectory(connection: connection, coordinator: coordinator, account: account,
                store: store, owner: owner, ownerTransport: ownerTransport)
            await ownerConnection.disconnect()
        } catch {
            await ownerConnection.disconnect()
            throw error
        }
    }
}

/// Holds a real old membership state while real owner commands change membership.
/// The returned state remains untouched; production fences decide how to apply it.
private actor RecoveryMembershipRaceTransport: V2ClientRoomRecoveryTransport {
    let transport: V2ProtobufSyncTransport
    let owner: LocalE2EAccountCredentials
    let roomID: RoomID
    let userID: UserID
    let membershipRevision: UInt64
    let initialHead: UInt64
    private var started = false
    private(set) var finalHead: UInt64?
    init(transport: V2ProtobufSyncTransport, owner: LocalE2EAccountCredentials, roomID: RoomID,
         userID: UserID, membershipRevision: UInt64, initialHead: UInt64) {
        self.transport = transport; self.owner = owner; self.roomID = roomID
        self.userID = userID; self.membershipRevision = membershipRevision; self.initialHead = initialHead
    }
    func startAccountRoomChanges() async throws -> UUID { try await transport.startAccountRoomChanges() }
    func userRoomDirectory(cursor: String?, pageSize: Int) async throws -> V2ClientUserRoomPage {
        try await transport.userRoomDirectory(cursor: cursor, pageSize: pageSize)
    }
    func roomSyncStates(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomStateResult] {
        let states = try await transport.roomSyncStates(roomIDs: roomIDs)
        guard !started, roomIDs.contains(roomID) else { return states }
        guard case .state(let state) = states[roomID], state.head == initialHead else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        started = true
        let removed = try await owner.changeMembership(roomID: roomID,
            operationID: .init(UUID().uuidString.lowercased()), targetUserID: userID,
            action: .remove, expectedMembershipRevision: membershipRevision)
        _ = try await owner.sendMessage(roomID: roomID, clientMessageID: .init(UUID().uuidString.lowercased()),
            text: "membership-gap", media: [], mentions: [])
        _ = try await owner.changeMembership(roomID: roomID,
            operationID: .init(UUID().uuidString.lowercased()), targetUserID: userID,
            action: .add, expectedMembershipRevision: removed.membershipRevision)
        let accepted = try await owner.sendMessage(roomID: roomID, clientMessageID: .init(UUID().uuidString.lowercased()),
            text: "membership-after-rejoin", media: [], mentions: [])
        finalHead = accepted.roomSequence
        return states
    }
}
