import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("granted group turn appends in order in one PostgreSQL atomic batch")
    func actorGrantedSameRoomBatch() async throws {
        try await withForwardOwnerDatabases(mode: .large) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let leases = PostgresV2RoomActivationStore(database: database)
            let token = try await actorBatchLease(leases, room: roomID)
            let writer = try actorBatchWriter(database: database)
            let batcher = V2SendMessageAdmissionBatcher(store: writer,
                configuration: .init(maximumBatchSize: 3, maximumDelay: .seconds(5)),
                actorGrantedStore: writer)
            let executor = try actorBatchExecutor(token: token, writer: writer, database: database, now: now)
            let wires = actorBatchWires(room: roomID, texts: ["one", "two", "three"])
            let results = try await executor.executeGrantedSendTurn(wires,
                batchDeadline: ContinuousClock().now - .milliseconds(1),
                using: .init(batcher: batcher))
            #expect(results.count == 3)
            for (index, result) in results.enumerated() {
                guard case .send(.accepted(let message)) = result else {
                    Issue.record("send \(index) was not accepted: \(result)"); continue
                }
                #expect(message.roomSequence == UInt64(index + 1))
                #expect(message.text == wires[index].text)
            }
            let persisted = try await sql.raw("SELECT room_sequence AS value FROM im_v2.messages WHERE room_id = \(bind: roomUUID) ORDER BY room_sequence")
                .all(decoding: CountRow.self)
            #expect(persisted.map(\.value) == [1, 2, 3])
            let snapshot = await batcher.snapshot()
            #expect(snapshot.completedBatches == 1)
            #expect(snapshot.atomicBatchCommitted == 1)
            #expect(snapshot.singletonDispatches == 0)
            #expect(try await leases.release(token: token))
            await batcher.retireActivation(token)
        }
    }

    @Test("two granted rooms on one owner share one fenced PostgreSQL transaction")
    func actorGrantedTwoRoomBatch() async throws {
        try await withForwardOwnerDatabases(mode: .large) { database, _, sql, _, _ in
            let secondRoom = RoomID(uuid: UUID())
            try await actorBatchSeedPeerRoom(secondRoom, on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let leases = PostgresV2RoomActivationStore(database: database)
            let firstToken = try await actorBatchLease(leases, room: roomID)
            let secondToken = try await actorBatchLease(leases, room: secondRoom)
            let writer = try actorBatchWriter(database: database)
            let batcher = V2SendMessageAdmissionBatcher(store: writer,
                configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
                actorGrantedStore: writer)
            let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
            let firstExecutor = try actorBatchExecutor(token: firstToken, writer: writer, database: database, now: now)
            let secondExecutor = try actorBatchExecutor(token: secondToken, writer: writer, database: database, now: now)
            let first = try firstExecutor.prepareSend(actorBatchWires(room: roomID, texts: ["one"])[0])
            let second = try secondExecutor.prepareSend(actorBatchWires(room: secondRoom, texts: ["two"])[0])
            let deadline = ContinuousClock().now + .seconds(2)
            async let firstResult = adapter.execute([first], batchDeadline: deadline)
            async let secondResult = adapter.execute([second], batchDeadline: deadline)
            let results = try await (firstResult, secondResult)
            #expect(results.0.count == 1 && results.1.count == 1)
            #expect(try await count("im_v2.messages", on: sql) == 2)
            let snapshot = await batcher.snapshot()
            #expect(snapshot.atomicBatchCommitted == 1)
            #expect(snapshot.atomicBatchCommittedRequests == 2)
            #expect(try await leases.release(token: firstToken))
            #expect(try await leases.release(token: secondToken))
            await adapter.retire(firstToken)
            await adapter.retire(secondToken)
        }
    }

    @Test("sharded granted turns use one fenced PostgreSQL transaction on their stable lane")
    func actorGrantedShardedTwoRoomBatch() async throws {
        try await withForwardOwnerDatabases(mode: .large) { database, _, sql, _, _ in
            let firstLane = V2ShardedSendMessageAdmissionBatcher.laneIndex(
                for: roomID, laneCount: 2)
            var secondRoom = RoomID(uuid: UUID())
            while V2ShardedSendMessageAdmissionBatcher.laneIndex(
                for: secondRoom, laneCount: 2) != firstLane {
                secondRoom = RoomID(uuid: UUID())
            }
            try await actorBatchSeedPeerRoom(secondRoom, on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let leases = PostgresV2RoomActivationStore(database: database)
            let firstToken = try await actorBatchLease(leases, room: roomID)
            let secondToken = try await actorBatchLease(leases, room: secondRoom)
            let writer = try actorBatchWriter(database: database)
            let batcher = V2ShardedSendMessageAdmissionBatcher(store: writer,
                configuration: .init(maximumBatchSize: 2, maximumDelay: .milliseconds(500),
                                     maximumInFlightBatches: 2, maximumPendingRequests: 4),
                laneCount: 2, actorGrantedStore: writer)
            let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
            let first = try actorBatchExecutor(token: firstToken, writer: writer, database: database,
                now: now).prepareSend(actorBatchWires(room: roomID, texts: ["first"])[0])
            let second = try actorBatchExecutor(token: secondToken, writer: writer, database: database,
                now: now).prepareSend(actorBatchWires(room: secondRoom, texts: ["second"])[0])
            let deadline = ContinuousClock.now + .seconds(2)
            let firstTask = Task { try await adapter.execute([first],
                batchDeadline: deadline, callDeadline: deadline) }
            let enqueueLimit = ContinuousClock.now + .seconds(1)
            while await batcher.snapshot().pendingRequests == 0 {
                try #require(ContinuousClock.now < enqueueLimit)
                await Task.yield()
            }
            let secondTask = Task { try await adapter.execute([second],
                batchDeadline: deadline, callDeadline: deadline) }
            #expect(try await firstTask.value.count == 1)
            #expect(try await secondTask.value.count == 1)
            #expect(try await count("im_v2.messages", on: sql) == 2)
            #expect(await batcher.snapshot().atomicBatchCommitted == 1)
            #expect(await batcher.snapshot().atomicBatchCommittedRequests == 2)
            #expect(try await leases.release(token: firstToken))
            #expect(try await leases.release(token: secondToken))
            await adapter.retire(firstToken)
            await adapter.retire(secondToken)
        }
    }

    @Test("stale token in a shared send batch leaves both rooms unchanged")
    func actorGrantedStaleMixedBatch() async throws {
        try await withForwardOwnerDatabases(mode: .large) { database, _, sql, _, _ in
            let secondRoom = RoomID(uuid: UUID())
            try await actorBatchSeedPeerRoom(secondRoom, on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let leases = PostgresV2RoomActivationStore(database: database)
            let stale = try await actorBatchLease(leases, room: roomID)
            let current = try await actorBatchLease(leases, room: secondRoom)
            #expect(try await leases.release(token: stale))
            let successor = try await actorBatchLease(leases, room: roomID)
            let writer = try actorBatchWriter(database: database)
            let batcher = V2SendMessageAdmissionBatcher(store: writer,
                configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
                actorGrantedStore: writer)
            let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
            let first = try actorBatchExecutor(token: stale, writer: writer, database: database, now: now)
                .prepareSend(actorBatchWires(room: roomID, texts: ["stale"])[0])
            let second = try actorBatchExecutor(token: current, writer: writer, database: database, now: now)
                .prepareSend(actorBatchWires(room: secondRoom, texts: ["valid"])[0])
            let deadline = ContinuousClock().now + .seconds(2)
            let staleResult = Task { try await adapter.execute([first], batchDeadline: deadline) }
            let currentResult = Task { try await adapter.execute([second], batchDeadline: deadline) }
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await staleResult.value }
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await currentResult.value }
            #expect(try await count("im_v2.messages", on: sql) == 0)
            #expect(await batcher.snapshot().atomicBatchAttempts == 1)
            #expect(await batcher.snapshot().atomicBatchCommitted == 0)
            await adapter.retire(stale)
            await adapter.retire(current)
            #expect(try await leases.release(token: successor))
            #expect(try await leases.release(token: current))
        }
    }

    @Test("deferred COMMIT error quarantines the entire granted turn before a successor SQL batch")
    func actorGrantedCommitUnknown() async throws {
        try await withForwardOwnerDatabases(mode: .large) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let leases = PostgresV2RoomActivationStore(database: database)
            let token = try await actorBatchLease(leases, room: roomID)
            let writer = try actorBatchWriter(database: database)
            let batcher = V2SendMessageAdmissionBatcher(store: writer,
                configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
                actorGrantedStore: writer)
            let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
            let executor = try actorBatchExecutor(token: token, writer: writer, database: database, now: now)
            try await sql.raw("""
                CREATE FUNCTION im_v2.reject_actor_batch_commit() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION 'injected deferred message failure'; END; $$
                """).run()
            try await sql.raw("""
                CREATE CONSTRAINT TRIGGER reject_actor_batch_commit AFTER INSERT ON im_v2.messages
                DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
                EXECUTE FUNCTION im_v2.reject_actor_batch_commit()
                """).run()
            let sends = try actorBatchWires(room: roomID, texts: ["one", "two", "three"])
                .map { try executor.prepareSend($0) }
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                try await adapter.execute(sends, batchDeadline: ContinuousClock().now)
            }
            #expect(await batcher.snapshot().completedBatches == 1)
            #expect(await batcher.snapshot().pendingRequests == 0)
            #expect(try await count("im_v2.messages", on: sql) == 0)
            let late = try executor.prepareSend(actorBatchWires(room: roomID, texts: ["late"])[0])
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                try await adapter.execute([late], batchDeadline: ContinuousClock().now)
            }
            #expect(await batcher.snapshot().completedBatches == 1)
            try await sql.raw("DROP TRIGGER reject_actor_batch_commit ON im_v2.messages").run()
            #expect(try await leases.release(token: token))
            await adapter.retire(token)
        }
    }

    private func actorBatchWriter(database: any Database) throws -> PostgresV2RoomWriteStore {
        PostgresV2RoomWriteStore(database: database,
            strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
            contentReviewMode: .disabled,
            shardAdmissionCommandCreditPool: .init(database: database, batchSize: 4))
    }

    private func actorBatchLease(_ leases: PostgresV2RoomActivationStore, room: RoomID) async throws -> V2RoomActivationToken {
        let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        let host = V2ActorHostIdentity(hostID: try .init("batch-host"), incarnationID: UUID())
        guard case .acquired(let lease) = try await leases.acquire(roomID: room,
            owner: owner, host: host, duration: .init(30_000)) else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        return lease.token
    }

    private func actorBatchExecutor(token: V2RoomActivationToken,
        writer: PostgresV2RoomWriteStore, database: any Database, now: Date
    ) throws -> V2RoomMessagingExecutor {
        try .init(token: token, writes: writer,
            edits: .init(database: database, contentReviewMode: .disabled),
            withdrawals: .init(database: database), reactions: .init(database: database),
            capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64),
            maximumEditBytes: 64, now: { now })
    }

    private func actorBatchWires(room: RoomID, texts: [String]) -> [V2ActorSendMessageWire] {
        texts.map { text in
            .init(roomID: room, actorUserID: senderID, clientMessageID: .init(uuid: UUID()),
                text: text, media: [], mentions: [], entities: [], replyTo: nil)
        }
    }

    private func actorBatchSeedPeerRoom(_ room: RoomID, on sql: any SQLDatabase) async throws {
        let id = try #require(room.uuidValue)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        try await sql.raw("INSERT INTO im_v2.rooms (room_id,room_shard_id,capacity_profile_id,capacity_class) VALUES (\(bind: id),'room-a','standard','large')").run()
        try await sql.raw("INSERT INTO im_v2.room_owner_routes (room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: id),'room-a',0,\(bind: now),\(bind: now))").run()
        try await sql.raw("INSERT INTO im_v2.group_rooms (room_id,owner_user_id,title,created_at) VALUES (\(bind: id),\(bind: senderUUID),'Second batch room',\(bind: now))").run()
        try await sql.raw("INSERT INTO im_v2.room_admission (room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation) VALUES (\(bind: id),3,10,\(bind: leaseUUID),1)").run()
        for member in [senderUUID, memberTwoUUID, memberThreeUUID] {
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: id),\(bind: member),0)").run()
        }
    }
}
