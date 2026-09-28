import Foundation
import IMV2ClientKit
import IMV2Core
import XCTest

extension IMAppRoomRecoveryScaleTests {
    func verifyJoinAfterDirectory(connection: V2TLSFrameConnection, coordinator: V2RealtimeSessionCoordinator,
                                 account: LocalE2EAccountCredentials, store: GRDBV2LocalSyncStore,
                                 owner: LocalE2EAccountCredentials, ownerTransport: V2ProtobufSyncTransport, roomID: RoomID) async throws {
        await coordinator.disconnect()
        let members = try await ownerTransport.listRoomMembers(roomID: roomID, cursor: nil, pageSize: 10)
        let removed = try await owner.changeMembership(roomID: roomID,
            operationID: .init(UUID().uuidString.lowercased()), targetUserID: account.userID,
            action: .remove, expectedMembershipRevision: members.membershipRevision)
        _ = try await owner.sendMessage(roomID: roomID, clientMessageID: .init(UUID().uuidString.lowercased()),
            text: "directory-join-gap", media: [], mentions: [])
        try await runDirectoryJoin(connection: connection, coordinator: coordinator, account: account,
            store: store, owner: owner, roomID: roomID, membershipRevision: removed.membershipRevision)
        print("IMV2_TLS_ROOM_DIRECTORY_JOIN_PASSED")
    }

    func verifyUnknownJoinAfterDirectory(connection: V2TLSFrameConnection, coordinator: V2RealtimeSessionCoordinator,
                                        account: LocalE2EAccountCredentials, store: GRDBV2LocalSyncStore,
                                        owner: LocalE2EAccountCredentials, ownerTransport: V2ProtobufSyncTransport) async throws {
        await coordinator.disconnect()
        let operation = try GroupRoomOperationID(UUID().uuidString.lowercased())
        // An owner-only room has never granted this viewer membership.
        let roomID = try await owner.createGroup(operationID: operation, title: "Unknown directory join", members: [])
        let members = try await ownerTransport.listRoomMembers(roomID: roomID, cursor: nil, pageSize: 10)
        _ = try await owner.sendMessage(roomID: roomID, clientMessageID: .init(UUID().uuidString.lowercased()),
            text: "directory-join-gap", media: [], mentions: [])
        let existingAccess = try await store.groupEventAccess(roomID: roomID)
        let existingMessages = try await store.messages(in: roomID)
        XCTAssertNil(existingAccess)
        XCTAssertTrue(existingMessages.isEmpty)
        try await runDirectoryJoin(connection: connection, coordinator: coordinator, account: account,
            store: store, owner: owner, roomID: roomID, membershipRevision: members.membershipRevision)
        print("IMV2_TLS_ROOM_UNKNOWN_DIRECTORY_JOIN_PASSED")
    }

    private func runDirectoryJoin(connection: V2TLSFrameConnection, coordinator: V2RealtimeSessionCoordinator,
                                  account: LocalE2EAccountCredentials, store: GRDBV2LocalSyncStore,
                                  owner: LocalE2EAccountCredentials, roomID: RoomID, membershipRevision: UInt64) async throws {
        let session = try await coordinator.connect()
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let personal = V2SyncEngine(transport: transport, store: store, capabilityProfile: session.capabilityProfile)
        try await synchronizeInitialState(personal)
        print("IMV2_DIRECTORY_JOIN_PERSONAL_READY room=\(roomID.rawValue)")
        let race = RecoveryDirectoryJoinTransport(transport: transport, owner: owner, roomID: roomID,
            userID: account.userID, membershipRevision: membershipRevision)
        let engine = V2RoomRecoveryEngine(transport: race, latestVisible: transport, store: store,
            groupEvents: V2GroupEventSyncEngine(transport: transport, store: store))
        let runner = V2RoomRecoveryRunner(engine: engine, source: connection, personalSync: personal,
            integrityInterval: { 3600 })
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { try await runner.run(userID: account.userID); return false }
                catch {
                    let cursor = try await store.groupEventCursor(roomID: roomID)
                    let access = try await store.groupEventAccess(roomID: roomID)
                    let messages = try await store.messages(in: roomID)
                    print("IMV2_DIRECTORY_JOIN_RUNNER_FAILED error=\(error) cursor=\(cursor) authorized=\(String(describing: access?.isAuthorized)) texts=\(messages.map(\.text))")
                    throw error
                }
            }
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(120))
                while ContinuousClock.now < deadline {
                    if let head = await race.finalHead, await engine.phase == .live {
                        let messages = try await store.messages(in: roomID)
                        guard !messages.contains(where: { $0.text == "directory-join-gap" }) else {
                            throw V2RealtimeTransportError.unexpectedResponse
                        }
                        if messages.contains(where: { $0.text == "directory-join-visible" }),
                           try await store.groupEventCursor(roomID: roomID) == head,
                           try await store.groupEventAccess(roomID: roomID)?.isAuthorized == true {
                            return true
                        }
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let phase = await engine.phase
                let head = await race.finalHead
                let cursor = try await store.groupEventCursor(roomID: roomID)
                let access = try await store.groupEventAccess(roomID: roomID)
                print("IMV2_DIRECTORY_JOIN_TIMEOUT phase=\(phase) head=\(String(describing: head)) cursor=\(cursor) authorized=\(String(describing: access?.isAuthorized))")
                throw V2RealtimeTransportError.unexpectedResponse
            }
            defer { group.cancelAll() }
            guard try await group.next() == true else { throw V2RealtimeTransportError.unexpectedResponse }
        }

    }
}

/// Adds membership only after the real terminal directory response was captured.
/// Returning that unchanged response ensures pagination cannot discover the join.
private actor RecoveryDirectoryJoinTransport: V2ClientRoomRecoveryTransport {
    let transport: V2ProtobufSyncTransport
    let owner: LocalE2EAccountCredentials
    let roomID: RoomID
    let userID: UserID
    let membershipRevision: UInt64
    private var started = false
    private(set) var finalHead: UInt64?
    init(transport: V2ProtobufSyncTransport, owner: LocalE2EAccountCredentials, roomID: RoomID,
         userID: UserID, membershipRevision: UInt64) {
        self.transport = transport; self.owner = owner; self.roomID = roomID
        self.userID = userID; self.membershipRevision = membershipRevision
    }
    func startAccountRoomChanges() async throws -> UUID { try await transport.startAccountRoomChanges() }
    func roomSyncStates(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomStateResult] {
        try await transport.roomSyncStates(roomIDs: roomIDs)
    }
    func userRoomDirectory(cursor: String?, pageSize: Int) async throws -> V2ClientUserRoomPage {
        let page = try await transport.userRoomDirectory(cursor: cursor, pageSize: pageSize)
        guard !started else { return page }
        guard !page.rooms.contains(where: { $0.roomID == roomID }) else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard page.nextCursor == nil else { return page }
        started = true
        print("IMV2_DIRECTORY_JOIN_TERMINAL_CAPTURED room=\(roomID.rawValue)")
        _ = try await owner.changeMembership(roomID: roomID,
            operationID: .init(UUID().uuidString.lowercased()), targetUserID: userID,
            action: .add, expectedMembershipRevision: membershipRevision)
        print("IMV2_DIRECTORY_JOIN_MEMBERSHIP_COMMITTED")
        let accepted = try await owner.sendMessage(roomID: roomID,
            clientMessageID: .init(UUID().uuidString.lowercased()), text: "directory-join-visible", media: [], mentions: [])
        finalHead = accepted.roomSequence
        print("IMV2_DIRECTORY_JOIN_MESSAGE_COMMITTED head=\(accepted.roomSequence)")
        return page
    }
}
