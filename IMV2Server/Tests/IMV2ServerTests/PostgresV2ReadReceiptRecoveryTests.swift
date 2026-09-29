@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("read recovery separates original IDs from current max and rechecks authority",arguments:[false,true])
    func readReceiptRecovery(direct:Bool) async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            let now = Date(timeIntervalSince1970:1_750_000_000)
            let receiptRoom = direct ? RoomID(uuid:UUID()) : roomID
            let receiptRoomUUID = receiptRoom.uuidValue!
            if direct {
                _ = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: forwardImportTestProfile(),
                    roomShardID: "room-a", roomID: receiptRoom, now: { now }).openedReceipt(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            }
            let service = try V2SendMessageService(store:PostgresV2RoomWriteStore(database:database),capacityProfile:forwardImportTestProfile(),limits:.init(maxUTF8Bytes:64),now:{now})
            for _ in 0..<2 { _ = try await service.send(.init(roomID:receiptRoom,actorUserID:senderID,clientMessageID:.init(uuid:UUID()),text:"Read frontier")) }
            let leases = PostgresV2RoomActivationStore(database:database)
            let owner = try V2RoomDataOwner(shardID:"room-a",epoch:0)
            guard case .acquired(let lease) = try await leases.acquire(roomID:receiptRoom,owner:owner,host:.init(hostID:.init("read-recovery"),incarnationID:UUID()),duration:.init(30_000)) else { throw CancellationError() }
            let store = PostgresV2ReadReceiptStore(database:database)
            func command(_ sequence:UInt64,operation:ReadReceiptOperationID = .init(uuid:UUID())) throws -> V2RecordReadReceiptCommand {
                try .init(roomID:receiptRoom,actorUserID:senderID,operationID:operation,readThroughRoomSequence:sequence)
            }
            let a = try command(1),b = try command(2),unsubmitted = try command(1)
            #expect(try await store.recoverActivationValidated(.init(command:a),token:lease.token) == .unresolved)
            guard case .recorded(let original) = try await store.recordActivationValidated(command:a,token:lease.token,now:now) else { throw CancellationError() }
            _ = try await store.recordActivationValidated(command:b,token:lease.token,now:now)
            #expect(try await store.recoverActivationValidated(.init(command:a),token:lease.token) == .originalReceipt(.init(command:a,receipt:original)))
            guard case .watermarkProof(let proof) = try await store.recoverActivationValidated(.init(command:unsubmitted),token:lease.token) else { throw CancellationError() }
            #expect(proof.watermark.readThroughRoomSequence == 2 && proof.validates(unsubmitted))
            #expect(try await store.recoverActivationValidated(.init(command:command(2,operation:a.operationID)),token:lease.token) == .fingerprintConflict)
            #expect(try await store.recoverActivationValidated(.init(command:command(3)),token:lease.token) == .currentUnavailable(.invalidWatermark))
            // The retained original ledger may be trimmed; current max remains separate authority evidence.
            try await sql.raw("DELETE FROM im_v2.read_receipt_operations WHERE user_id=\(bind:senderUUID) AND operation_id=\(bind:a.operationID.uuidValue!)").run()
            guard case .watermarkProof = try await store.recoverActivationValidated(.init(command:a),token:lease.token) else { throw CancellationError() }
            // Historical own evidence survives leaving; new proofs and submissions still require membership.
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=2 WHERE room_id=\(bind:receiptRoomUUID) AND user_id=\(bind:senderUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2 WHERE room_id=\(bind:receiptRoomUUID)").run()
            guard case .originalReceipt(let retained) = try await store.recoverActivationValidated(.init(command:b),token:lease.token) else { throw CancellationError() }
            #expect(retained.validates(b) && retained.receipt.readThroughRoomSequence == 2)
            #expect(try await store.recoverActivationValidated(.init(command:a),token:lease.token) == .currentUnavailable(.permissionDenied))
            #expect(try await store.recoverActivationValidated(.init(command:unsubmitted),token:lease.token) == .currentUnavailable(.permissionDenied))
            #expect(try await store.recoverActivationValidated(.init(command:command(1,operation:b.operationID)),token:lease.token) == .fingerprintConflict)
            let otherActor = try V2RecordReadReceiptCommand(roomID:receiptRoom,actorUserID:.init(uuid:memberTwoUUID),operationID:b.operationID,readThroughRoomSequence:2)
            #expect(try await store.recoverActivationValidated(.init(command:otherActor),token:lease.token) == .unresolved)
            await #expect(throws:V2ReadReceiptStoreError.actorNotMember) { _ = try await store.recordActivationValidated(command:b,token:lease.token,now:now) }
            #expect(try await leases.release(token:lease.token))
            await #expect(throws:V2RoomActivationLeaseError.activationChanged) { _ = try await store.recoverActivationValidated(.init(command:b),token:lease.token) }
        }
    }
}
