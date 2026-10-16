import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
@testable import IMV2ServerApplication
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("restoration seeds registry and send state without subsequent SQL, and rejects stale data owners",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"),
          arguments: [false, true])
    func unifiedSendInitialization(direct: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            if direct {
                try await sql.raw("DELETE FROM im_v2.group_rooms WHERE room_id=\(bind: roomUUID)").run()
                try await sql.raw("DELETE FROM im_v2.room_memberships WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: memberThreeUUID)").run()
                try await sql.raw("UPDATE im_v2.rooms SET room_kind='direct' WHERE room_id=\(bind: roomUUID)").run()
                try await sql.raw("""
                    INSERT INTO im_v2.direct_room_pairs(room_id, lower_user_id, higher_user_id, created_at)
                    VALUES (\(bind: roomUUID), LEAST(\(bind: senderUUID), \(bind: memberTwoUUID)),
                            GREATEST(\(bind: senderUUID), \(bind: memberTwoUUID)), now())
                    """).run()
            }
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let observations = V2DatabaseLoanObservationRegistry()
                let loan = observations.make(source: .query, at: .now)
                loan.granted(at: .now); loan.driverEntered()
                defer { loan.finish() }
                let observed = v2ObserveBorrowedDatabase(database, observation: loan)
                let initialization = try await v2RestoreRoomSendInitialization(database: observed, token: token)
                #expect(observations.snapshot()[.query]?.sqlPhases[.other]?.count == 1)
                #expect(observations.snapshot()[.query]?.sqlPhases[.transactionControl]?.count == 0)
                #expect(initialization.kind == (direct ? "direct" : "group"))
                #expect((initialization.directState != nil) == direct)
                if let state = initialization.directState {
                    #expect(Set([state.lower, state.higher]) == Set([senderUUID, memberTwoUUID]))
                    #expect(state.members == 2 && state.totalMembers == 2)
                    #expect(state.roomSequence == 0 && state.timelineSequence == 0)
                }
                let directory = PostgresV2RoomPolicyAuthorizationDirectory(database: database,
                    endpoint: "initialization-test", maximumRooms: 4,
                    currentLoader: { _, _, _, _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
                try await directory.install(initialization)
                let memory = V2DirectRoomSendAcceptanceMemory()
                memory.install(initialization)
                let policy = V2DirectSendControlPolicy(
                    sender: .init(userID: senderUUID, isActive: true, specialKind: nil, specialStatus: nil,
                        allowsServiceMessages: nil, allowsCustomerMessages: nil),
                    recipient: .init(userID: memberTwoUUID, isActive: true, specialKind: nil, specialStatus: nil,
                        allowsServiceMessages: nil, allowsCustomerMessages: nil),
                    blocked: false, isFriend: true, allowsStrangers: false)
                let command = try V2SendMessageCommand(roomID: roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "initialized", limits: .init(maxUTF8Bytes: 64))
                // Removing the SQL name proves both initialized lookups are memory-only.
                try await sql.raw("ALTER TABLE im_v2.rooms RENAME TO rooms_initialization_test").run()
                let registry = try await directory.registry(token: token)
                _ = try await registry.runtime(sender: senderUUID, token: token)
                try await memory.initializeIfNeeded(token: token, database: database)
                if direct {
                    #expect(try memory.accept(command: command, token: token, policy: policy, now: Date()) != nil)
                    let preflight = try #require(try memory.preflight(command: command, token: token,
                        policy: policy, ordinal: 0, now: Date()))
                    #expect(preflight.room.roomSequence == 0)
                }
                #expect(await directory.pressure().creations == 0)
                let stale = V2RoomActivationToken(roomID: token.roomID, owner: token.owner,
                    activationEpoch: token.activationEpoch,
                    host: .init(hostID: token.host.hostID, incarnationID: UUID()))
                await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                    try await directory.registry(token: stale)
                }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                    try await directory.install(.init(token: stale, kind: initialization.kind, directState: initialization.directState))
                }
                try await sql.raw("ALTER TABLE im_v2.rooms_initialization_test RENAME TO rooms").run()
                if direct {
                    memory.invalidate(token)
                    #expect(try memory.accept(command: command, token: token, policy: policy, now: Date()) == nil)
                    try await sql.raw("UPDATE im_v2.rooms SET room_sequence=7,timeline_sequence=11 WHERE room_id=\(bind: roomUUID)").run()
                    try await memory.initializeIfNeeded(token: token, database: database)
                    let reloaded = try #require(try memory.preflight(command: command, token: token,
                        policy: policy, ordinal: 0, now: Date()))
                    #expect(reloaded.room.roomSequence == 7 && reloaded.room.timelineSequence == 11)
                }
                await directory.retire(token: token)
                memory.invalidate(token)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind: roomUUID)").run()
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                    _ = try await v2RestoreRoomSendInitialization(database: database, token: token)
                }
                await directory.shutdown()
            }
        }
    }
}
