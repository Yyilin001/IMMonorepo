@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("D5 same-owner pair commits once and a stale data owner cannot replay",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_D5_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func v2RoomActorForwardPairFenceAndReplay() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D5_OWNER_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        var policyOwners: PostgresV2PolicyOwnerDirectory?
        var policyService: V2RoomPolicyAuthorizationService?
        do {
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
                .first(decoding: D5ForwardBool.self)?.value == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let sourceRoom = RoomID(uuid: roomUUID)
            let targetUUID = UUID(), targetRoom = RoomID(uuid: targetUUID)
            let seededAt = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, capacity_class)
                VALUES (\(bind: targetUUID), 'room-a', 'standard', 'standard')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_owner_routes
                    (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: targetUUID), 'room-a', 0, \(bind: seededAt), \(bind: seededAt))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
                VALUES (\(bind: targetUUID), \(bind: senderUUID), 'Target', \(bind: seededAt))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: targetUUID), 3, 10, \(bind: leaseUUID), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                VALUES (\(bind: targetUUID), \(bind: senderUUID), 0),
                       (\(bind: targetUUID), \(bind: memberTwoUUID), 0),
                       (\(bind: targetUUID), \(bind: memberThreeUUID), 0)
                """).run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 128)
            let send = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0),
                capacityProfile: profile, limits: limits, now: { seededAt })
            guard case .accepted(let source) = try await send.send(.init(roomID: sourceRoom,
                actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "forward source")) else {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET valid_until = CURRENT_TIMESTAMP + INTERVAL '1 hour'
                WHERE room_shard_id = 'room-a'
                """).run()
            // Prepare both source messages through the current policy boundary.
            let targetSend = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0),
                capacityProfile: profile, limits: limits, now: Date.init)
            guard case .accepted(let oppositeSource) = try await targetSend.send(.init(
                roomID: targetRoom, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "opposite source")) else {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            let journal = PostgresV2PolicyAuthorizationJournal(database: database)
            let owners = PostgresV2PolicyOwnerDirectory(journal: journal,
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery()))
            let service = V2RoomPolicyAuthorizationService(roomDatabase: database,
                policyOwners: owners, endpoint: "room-a", maximumRooms: 2)
            policyOwners = owners; policyService = service
            let executor = V2ActorForwardPairDomainExecutor(database: database,
                write: PostgresV2RoomWriteStore(database: database), capacityProfile: profile,
                limits: limits, now: Date.init).usingPolicyAuthorizations(service)
            let pair = V2ActorForwardPairWire(actorUserID: senderID,
                operationID: .init(uuid: UUID()), source: try .init(roomID: sourceRoom,
                    messageID: source.messageID, revision: .init(1)), targetRoomID: targetRoom)
            try await withRoomActivation(database: database, roomID: sourceRoom) { sourceToken in
                try await withRoomActivation(database: database, roomID: targetRoom) { targetToken in
                    let tokens = [sourceToken, targetToken]
                    let first = try await executor.execute(pair, activationTokens: tokens)
                    #expect(first.errorCode == nil && first.messageID != nil)
                    let second = try await executor.execute(pair, activationTokens: tokens)
                    #expect(second == first)
                    let selfPair = V2ActorForwardPairWire(actorUserID: senderID,
                        operationID: .init(uuid: UUID()), source: pair.source,
                        targetRoomID: sourceRoom)
                    let selfResult = try await executor.execute(selfPair,
                        activationTokens: [sourceToken])
                    #expect(selfResult.errorCode == nil && selfResult.messageID != nil)
                    let forwardA = V2ActorForwardPairWire(actorUserID: senderID,
                        operationID: .init(uuid: UUID()), source: pair.source,
                        targetRoomID: targetRoom)
                    let forwardB = V2ActorForwardPairWire(actorUserID: senderID,
                        operationID: .init(uuid: UUID()), source: try .init(roomID: targetRoom,
                            messageID: oppositeSource.messageID, revision: .init(1)),
                        targetRoomID: sourceRoom)
                    async let toTarget = executor.execute(forwardA, activationTokens: tokens)
                    async let toSource = executor.execute(forwardB, activationTokens: tokens)
                    let (a, b) = try await (toTarget, toSource)
                    #expect(a.messageID != nil && b.messageID != nil)
                    let recoveredClient = UUID(), recoveredOperation = UUID()
                    try await sql.raw("""
                        INSERT INTO im_v2.message_forward_operations
                            (actor_user_id, operation_id, source_message_id, target_room_id,
                             target_client_message_id, source_content_revision, source_room_id, created_at)
                        VALUES (\(bind: senderUUID), \(bind: recoveredOperation),
                            \(bind: source.messageID.uuidValue!), \(bind: targetUUID),
                            \(bind: recoveredClient), 1, \(bind: roomUUID), CURRENT_TIMESTAMP)
                        """).run()
                    let recoveredAt = Date()
                    let recoveredCommand = try V2SendMessageCommand(roomID: targetRoom,
                        senderUserID: senderID, clientMessageID: .init(uuid: recoveredClient),
                        text: "forward source", media: [], entities: [],
                        forwardedFrom: .init(messageID: source.messageID,
                            senderUserID: senderID, sourceRevision: .init(1)), limits: limits)
                    let recoveredPair = V2ActorForwardPairWire(actorUserID: senderID,
                        operationID: .init(uuid: recoveredOperation), source: pair.source, targetRoomID: targetRoom)
                    let write = PostgresV2RoomWriteStore(database: database).usingPolicyAuthorizations(service)
                    let request = V2RoomWriteRequest(command: recoveredCommand, capacityProfile: profile,
                        identifiers: try V2AcceptanceIDFactory().make(at: recoveredAt), now: recoveredAt)
                    // Omit ledger publication while the fenced acceptance and completion
                    // commit, then verify recovery from the immutable success record.
                    let outcome = try await write.acceptActorForwardPair(request: request,
                        sourceRoomID: sourceRoom, activationTokens: tokens,
                        prepareLedger: { _ in }, recordLedger: { _, _ in })
                    let recoveredMessageID = try #require(outcome.acceptanceReceipt).messageID
                    try await sql.raw("""
                        UPDATE im_v2.messages
                        SET withdrawn_at = CURRENT_TIMESTAMP, withdrawn_by_user_id = \(bind: senderUUID)
                        WHERE message_id = \(bind: source.messageID.uuidValue!)
                        """).run()
                    let repaired = try await executor.execute(recoveredPair, activationTokens: tokens)
                    #expect(repaired.messageID == recoveredMessageID && repaired.errorCode == nil)
                    #expect(try await sql.raw("""
                        SELECT result_message_id = \(bind: recoveredMessageID.uuidValue!) AS value
                        FROM im_v2.message_forward_operations
                        WHERE operation_id = \(bind: recoveredOperation)
                        """).first(decoding: D5ForwardBool.self)?.value == true)
                    #expect(try await executor.execute(pair, activationTokens: tokens) == first)
                    #expect(try await sql.raw("""
                        SELECT count(*)::bigint AS value FROM im_v2.message_forward_operations
                        WHERE operation_id = \(bind: pair.operationID.uuidValue!)
                        """).first(decoding: D5ForwardCount.self)?.value == 1)
                    #expect(try await sql.raw("""
                        SELECT result_message_id IS NOT NULL AS value FROM im_v2.message_forward_operations
                        WHERE operation_id = \(bind: pair.operationID.uuidValue!)
                        """).first(decoding: D5ForwardBool.self)?.value == true)
                    try await sql.raw("""
                        UPDATE im_v2.rooms SET owner_epoch = owner_epoch + 1
                        WHERE room_id = \(bind: targetUUID)
                        """).run()
                    await #expect(throws: V2RoomActorStateError.ownerChanged) {
                        _ = try await executor.execute(pair, activationTokens: tokens)
                    }
                }
            }
            if let policyService { await policyService.shutdown() }
            if let policyOwners { await policyOwners.shutdown() }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let policyService { await policyService.shutdown() }
            if let policyOwners { await policyOwners.shutdown() }
            try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct D5ForwardBool: Decodable { let value: Bool }
private struct D5ForwardCount: Decodable { let value: Int64 }
