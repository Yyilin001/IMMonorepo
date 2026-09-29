@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("host receipt batch keeps a stale room separate from a committed sibling",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func actorHostReceiptBatchFence() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let second = RoomID(uuid: UUID())
            let secondID = try #require(second.uuidValue)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("INSERT INTO im_v2.rooms (room_id,room_shard_id,capacity_profile_id,capacity_class,room_sequence) VALUES (\(bind: secondID),'room-a','standard','standard',1)").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes (room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: secondID),'room-a',0,\(bind: now),\(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.group_rooms (room_id,owner_user_id,title,created_at) VALUES (\(bind: secondID),\(bind: senderUUID),'Receipt peer',\(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.room_admission (room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation) VALUES (\(bind: secondID),1,10,\(bind: leaseUUID),1)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: secondID),\(bind: senderUUID),0)").run()
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = 1 WHERE room_id = \(bind: roomUUID)").run()

            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let host = V2ActorHostIdentity(hostID: try .init("receipt-pg"), incarnationID: UUID())
            func acquire(_ room: RoomID) async throws -> V2RoomActivationToken {
                guard case .acquired(let value) = try await leases.acquire(roomID: room,
                    owner: owner, host: host, duration: .init(30_000)) else {
                    throw V2RoomActivationLeaseError.activationChanged
                }
                return value.token
            }
            let stale = try await acquire(roomID)
            let current = try await acquire(second)
            #expect(try await leases.release(token: stale))
            let replacement = try await acquire(roomID)
            let executor = V2ActorRoomReceiptExecutor(database: database,
                projectionDelivery: SuccessfulProjectionDelivery())
            let batcher = V2HostRoomReceiptBatcher(executor: executor,
                configuration: .init(maximumBatchSize: 2, maximumDelay: .milliseconds(20),
                    maximumInFlightBatches: 1, maximumPendingRequests: 4))
            let firstWire = try V2ActorRecordReadReceiptWire(roomID: roomID, actorUserID: senderID,
                operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            let secondWire = try V2ActorRecordReadReceiptWire(roomID: second, actorUserID: senderID,
                operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            let cutoff = ContinuousClock.now + .seconds(5)
            let first = Task { try await batcher.record(.init(command: .record(firstWire), token: stale,
                batchDeadline: cutoff, callDeadline: cutoff, ingressAt: now)) }
            let sibling = Task { try await batcher.record(.init(command: .record(secondWire), token: current,
                batchDeadline: cutoff, callDeadline: cutoff, ingressAt: now.addingTimeInterval(1))) }
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) { try await first.value }
            guard case .record(.recorded(let receipt)) = try await sibling.value else {
                Issue.record("current activation did not record receipt"); return
            }
            #expect(receipt.roomID == second)
            #expect(receipt.recordedAt == now.addingTimeInterval(1))
            #expect(try await count("im_v2.read_receipt_operations", on: sql) == 1)
            #expect(try await leases.release(token: replacement))
            #expect(try await leases.release(token: current))
        }
    }
}
