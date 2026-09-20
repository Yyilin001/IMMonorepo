import Foundation
import IMV2ClientKit
import IMV2Core
import XCTest

extension IMAppRoomRecoveryScaleTests {
    func verifyScanRace(connection: V2TLSFrameConnection, coordinator: V2RealtimeSessionCoordinator,
                        auth: V2AuthSession, account: LocalE2EAccountCredentials,
                        store: GRDBV2LocalSyncStore, roomID: RoomID, boundary: String) async throws {
        let session = try await coordinator.connect()
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let personal = V2SyncEngine(transport: transport, store: store, capabilityProfile: session.capabilityProfile)
        try await synchronizeInitialState(personal)
        let race = RecoveryScanRaceTransport(transport: transport, roomID: roomID, boundary: boundary) {
            try await sendRecoveryOnlineMessage(transport: transport, auth: auth, roomID: roomID,
                deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        }
        let engine = V2RoomRecoveryEngine(transport: race, latestVisible: transport, store: store,
            groupEvents: V2GroupEventSyncEngine(transport: transport, store: store))
        let runner = V2RoomRecoveryRunner(engine: engine, source: connection, personalSync: personal,
            integrityInterval: { 3600 })
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await runner.run(userID: account.userID) }
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while true {
                    if await race.injected, await engine.phase == .live,
                       try await store.messages(in: roomID).count == 3,
                       try await store.groupEventCursor(roomID: roomID) == 3 { break }
                    guard ContinuousClock.now < deadline else { throw V2RealtimeTransportError.unexpectedResponse }
                    try await Task.sleep(for: .milliseconds(20))
                }
                print("IMV2_TLS_ROOM_SCAN_RACE_PASSED boundary=\(boundary)")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

/// Holds a real response while another Gateway commits a real message. Does not
/// fabricate data, enqueue work, or alter the production notification consumer.
private actor RecoveryScanRaceTransport: V2ClientRoomRecoveryTransport {
    let transport: V2ProtobufSyncTransport
    let roomID: RoomID
    let boundary: String
    let write: @Sendable () async throws -> Void
    private(set) var injected = false
    private var started = false
    init(transport: V2ProtobufSyncTransport, roomID: RoomID, boundary: String,
         write: @escaping @Sendable () async throws -> Void) {
        self.transport = transport; self.roomID = roomID; self.boundary = boundary; self.write = write
    }
    private func inject(at boundary: String) async throws {
        guard self.boundary == boundary, !started else { return }
        started = true
        try await write()
        injected = true
    }
    func startAccountRoomChanges() async throws -> UUID {
        try await inject(at: "before-listener")
        return try await transport.startAccountRoomChanges()
    }
    func userRoomDirectory(cursor: String?, pageSize: Int) async throws -> V2ClientUserRoomPage {
        let page = try await transport.userRoomDirectory(cursor: cursor, pageSize: pageSize)
        if page.rooms.contains(where: { $0.roomID == roomID }) { try await inject(at: "directory") }
        return page
    }
    func roomSyncStates(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomStateResult] {
        let states = try await transport.roomSyncStates(roomIDs: roomIDs)
        if boundary == "state", !started, roomIDs.contains(roomID) {
            // Prove that the delayed result actually predates the third message.
            // A retry/unavailable result is not evidence of an old-state race.
            guard case .state(let state) = states[roomID], state.head == 2 else {
                throw V2RealtimeTransportError.unexpectedResponse
            }
            try await inject(at: "state")
        }
        return states
    }
}
