import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerInfrastructure
@testable import IMV2ServerApplication
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("restoration seeds registry and send state without subsequent SQL, and rejects expired activations",
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
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let host = V2ActorHostIdentity(hostID: try .init("initialization-test"), incarnationID: UUID())
            guard case .acquired(let lease) = try await leases.acquire(roomID: roomID, owner: owner, host: host, duration: .init(30_000)) else {
                Issue.record("activation unavailable"); return
            }
            let initialization = try await v2RestoreRoomSendInitialization(database: database, token: lease.token)
            #expect(initialization.kind == (direct ? "direct" : "group"))
            #expect((initialization.directState != nil) == direct)
            if let state = initialization.directState {
                #expect(Set([state.lower, state.higher]) == Set([senderUUID, memberTwoUUID]))
                #expect(state.members == 2 && state.totalMembers == 2)
                #expect(state.roomSequence == 0 && state.timelineSequence == 0)
            }
            let directory = PostgresV2RoomPolicyAuthorizationDirectory(database: database,
                endpoint: "initialization-test", maximumRooms: 4,
                currentLoader: { _, _, _, _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                loader: { _, _, _, _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget },
                accountLoader: { _, _, _, _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
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
            let registry = try await directory.registry(token: lease.token)
            _ = try await registry.runtime(sender: senderUUID, token: lease.token)
            try await memory.initializeIfNeeded(token: lease.token, database: database)
            if direct {
                #expect(try memory.accept(command: command, token: lease.token, policy: policy, now: Date()) != nil)
                let preflight = try #require(try memory.preflight(command: command, token: lease.token,
                    policy: policy, ordinal: 0, now: Date()))
                #expect(preflight.room.roomSequence == 0)
            }
            #expect(await directory.pressure().creations == 0)
            let stale = V2RoomActivationToken(roomID: lease.token.roomID, owner: owner,
                activationEpoch: lease.token.activationEpoch,
                host: .init(hostID: host.hostID, incarnationID: UUID()))
            await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                try await directory.registry(token: stale)
            }
            await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                try await directory.install(.init(token: stale, kind: initialization.kind, directState: initialization.directState))
            }
            try await sql.raw("ALTER TABLE im_v2.rooms_initialization_test RENAME TO rooms").run()
            if direct {
                memory.invalidate(lease.token)
                #expect(try memory.accept(command: command, token: lease.token, policy: policy, now: Date()) == nil)
                try await sql.raw("UPDATE im_v2.rooms SET room_sequence=7,timeline_sequence=11 WHERE room_id=\(bind: roomUUID)").run()
                try await memory.initializeIfNeeded(token: lease.token, database: database)
                let reloaded = try #require(try memory.preflight(command: command, token: lease.token,
                    policy: policy, ordinal: 0, now: Date()))
                #expect(reloaded.room.roomSequence == 7 && reloaded.room.timelineSequence == 11)
            }
            try await directory.retire(token: lease.token)
            memory.invalidate(lease.token)
            #expect(try await leases.release(token: lease.token))
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await v2RestoreRoomSendInitialization(database: database, token: lease.token)
            }
            try await directory.shutdown()
        }
    }
}
