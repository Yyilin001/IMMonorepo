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
            let service = try V2SendMessageService(store:V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                    store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0),capacityProfile:forwardImportTestProfile(),limits:.init(maxUTF8Bytes:64),now:{now})
            for _ in 0..<2 { _ = try await service.send(.init(roomID:receiptRoom,actorUserID:senderID,clientMessageID:.init(uuid:UUID()),text:"Read frontier")) }
            try await withRoomActivation(database: database, roomID: receiptRoom) { token in
            let store = PostgresV2ReadReceiptStore(database:database)
            func command(_ sequence:UInt64,operation:ReadReceiptOperationID = .init(uuid:UUID())) throws -> V2RecordReadReceiptCommand {
                try .init(roomID:receiptRoom,actorUserID:senderID,operationID:operation,readThroughRoomSequence:sequence)
            }
            let a = try command(1),b = try command(2),unsubmitted = try command(1)
            #expect(try await store.recoverActivationValidated(.init(command:a),token:token) == .unresolved)
            guard case .recorded(let original) = try await store.recordActivationValidated(command:a,token:token,now:now) else { throw CancellationError() }
            _ = try await store.recordActivationValidated(command:b,token:token,now:now)
            #expect(try await store.recoverActivationValidated(.init(command:a),token:token) == .originalReceipt(.init(command:a,receipt:original)))
            guard case .watermarkProof(let proof) = try await store.recoverActivationValidated(.init(command:unsubmitted),token:token) else { throw CancellationError() }
            #expect(proof.watermark.readThroughRoomSequence == 2 && proof.validates(unsubmitted))
            #expect(try await store.recoverActivationValidated(.init(command:command(2,operation:a.operationID)),token:token) == .fingerprintConflict)
            #expect(try await store.recoverActivationValidated(.init(command:command(3)),token:token) == .currentUnavailable(.invalidWatermark))
            // The retained original ledger may be trimmed; current max remains separate authority evidence.
            try await sql.raw("DELETE FROM im_v2.read_receipt_operations WHERE user_id=\(bind:senderUUID) AND operation_id=\(bind:a.operationID.uuidValue!)").run()
            guard case .watermarkProof = try await store.recoverActivationValidated(.init(command:a),token:token) else { throw CancellationError() }
            // Historical own evidence survives leaving; new proofs and submissions still require membership.
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=2 WHERE room_id=\(bind:receiptRoomUUID) AND user_id=\(bind:senderUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2 WHERE room_id=\(bind:receiptRoomUUID)").run()
            guard case .originalReceipt(let retained) = try await store.recoverActivationValidated(.init(command:b),token:token) else { throw CancellationError() }
            #expect(retained.validates(b) && retained.receipt.readThroughRoomSequence == 2)
            #expect(try await store.recoverActivationValidated(.init(command:a),token:token) == .currentUnavailable(.permissionDenied))
            #expect(try await store.recoverActivationValidated(.init(command:unsubmitted),token:token) == .currentUnavailable(.permissionDenied))
            #expect(try await store.recoverActivationValidated(.init(command:command(1,operation:b.operationID)),token:token) == .fingerprintConflict)
            let otherActor = try V2RecordReadReceiptCommand(roomID:receiptRoom,actorUserID:.init(uuid:memberTwoUUID),operationID:b.operationID,readThroughRoomSequence:2)
            #expect(try await store.recoverActivationValidated(.init(command:otherActor),token:token) == .unresolved)
            await #expect(throws:V2ReadReceiptStoreError.actorNotMember) { _ = try await store.recordActivationValidated(command:b,token:token,now:now) }
            // Actor identity is checked at the native Host boundary. SQL still
            // rejects a token for a changed durable data owner.
            try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind:receiptRoomUUID)").run()
            await #expect(throws: V2RoomActorStateError.ownerChanged) {
                _ = try await store.recoverActivationValidated(.init(command: b), token: token)
            }
            }
        }
    }
}
