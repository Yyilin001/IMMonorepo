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
    @Test("permanent message mutations preserve receipts across conflicts and close races")
    func permanentMessageMutationReceipts() async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            #expect(throws: V2MessageEditStoreError.corruptPersistenceState) {
                _ = try V2PostgresMessageEditPersistence(transaction: database, contentReviewMode: .disabled)
            }
            #expect(throws: V2MessageWithdrawalStoreError.corruptPersistenceState) {
                _ = try V2PostgresMessageWithdrawalPersistence(transaction: database)
            }
            #expect(throws: V2MessageReactionStoreError.corruptPersistenceState) {
                _ = try V2PostgresMessageReactionPersistence(transaction: database)
            }
            let now=Date(timeIntervalSince1970:1_750_000_000)
            let profile=try forwardImportTestProfile()
            let sends=try V2SendMessageService(store:V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0),capacityProfile:profile,limits:.init(maxUTF8Bytes:64),now:{now})
            guard case .accepted(let accepted)=try await sends.send(.init(roomID:roomID,actorUserID:senderID,clientMessageID:.init(uuid:UUID()),text:"Before")) else { throw CancellationError() }
            try await withRoomActivation(database: database, roomID: roomID) { token in
            let store=PostgresV2MessageMutationOperationStore(database:database,contentReviewMode:.disabled,clock:{now})
            let deadline=UInt64(now.timeIntervalSince1970*1000)+60_000
            func edit(_ text:String,_ revision:UInt64,operation:MessageEditOperationID = .init(uuid:UUID()),deadlineMS:UInt64? = nil) throws -> V2MessageEditOperationCommand {
                try .init(command:.init(roomID:roomID,actorUserID:senderID,operationID:operation,messageID:accepted.messageID,expectedMessageRevision:revision,text:text,maximumUTF8Bytes:64),firstSubmissionDeadlineMilliseconds:deadlineMS ?? deadline)
            }
            let first=try edit("After",1)
            guard case .receipt(let original)=try await store.edit(first,token:token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now,maximumUTF8Bytes:64),case .committed(let commit)=original.outcome else { throw CancellationError() }
            #expect(commit.messageRevision==2)
            #expect(try await store.edit(first,token:token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now.addingTimeInterval(1000),maximumUTF8Bytes:64) == .receipt(original))
            let changed=try edit("Different",1,operation:first.operationID)
            #expect(try await store.edit(changed,token:token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now,maximumUTF8Bytes:64) == .fingerprintConflict)
            let stale=try edit("Stale",1)
            guard case .receipt(let conflict)=try await store.edit(stale,token:token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now,maximumUTF8Bytes:64) else { throw CancellationError() }
            #expect(conflict.outcome == .rejected(.revisionConflict(current:2)))
            let expired=try edit("Expired",2,deadlineMS:deadline-120_000)
            guard case .receipt(let expiration)=try await store.edit(expired,token:token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now,maximumUTF8Bytes:64) else { throw CancellationError() }
            #expect(expiration.outcome == .rejected(.expiredUnsubmitted))
            let closedCommand=try edit("Closed",2)
            let closeRequest=try V2MessageMutationRecoveryRequest(identity:closedCommand.identity,fingerprint:closedCommand.fingerprint,action:.closeIfAbsent)
            guard case .receipt(let closed)=try await store.recover(closeRequest,token:token,now:now) else { throw CancellationError() }
            #expect(closed.outcome == .closed)
            #expect(try await store.edit(closedCommand,token:token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now,maximumUTF8Bytes:64) == .receipt(closed))
            try await sql.raw("CREATE FUNCTION im_v2.fixture_mutation_receipt_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture failure' USING ERRCODE='23514'; END $$").run()
            try await sql.raw("CREATE TRIGGER fixture_mutation_receipt_failure BEFORE INSERT ON im_v2.message_mutation_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_mutation_receipt_failure()").run()
            let failedEdit=try edit("Rolled back",2)
            await #expect(throws:(any Error).self) { _ = try await store.edit(failedEdit,token:token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now,maximumUTF8Bytes:64) }
            let failedWithdrawal=try V2MessageWithdrawalOperationCommand(command:.init(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),messageID:accepted.messageID,expectedMessageRevision:2),firstSubmissionDeadlineMilliseconds:deadline)
            await #expect(throws:(any Error).self) { _ = try await store.withdraw(failedWithdrawal,token:token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now) }
            let retainedState=try await sql.raw("SELECT content_revision AS revision,withdrawn_at IS NOT NULL AS withdrawn FROM im_v2.messages WHERE message_id=\(bind:accepted.messageID.uuidValue!)").first(decoding:MutationRollbackState.self)
            #expect(retainedState?.revision==2 && retainedState?.withdrawn==false)
            let roomState=try await sql.raw("SELECT room_sequence AS revision,false AS withdrawn FROM im_v2.rooms WHERE room_id=\(bind:roomID.uuidValue!)").first(decoding:MutationRollbackState.self)
            #expect(roomState?.revision==Int64(commit.roomSequence))
            try await sql.raw("DROP TRIGGER fixture_mutation_receipt_failure ON im_v2.message_mutation_receipts").run()
            try await sql.raw("DROP FUNCTION im_v2.fixture_mutation_receipt_failure()").run()
            let withdrawal=try V2MessageWithdrawalOperationCommand(command:.init(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),messageID:accepted.messageID,expectedMessageRevision:2),firstSubmissionDeadlineMilliseconds:deadline)
            guard case .receipt(let withdrawn)=try await store.withdraw(withdrawal,token:token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now),case .committed(let withdrawalCommit)=withdrawn.outcome else { throw CancellationError() }
            #expect(withdrawalCommit.messageRevision==3)
            #expect(try await store.recover(.init(identity:first.identity,fingerprint:first.fingerprint,action:.query),token:token,now:now) == .receipt(original))
            let payload=String(decoding:try JSONEncoder().encode(original),as:UTF8.self)
            #expect(!payload.contains("After") && !payload.contains("Before"))
            await #expect(throws:(any Error).self) { try await sql.raw("DELETE FROM im_v2.message_mutation_receipts WHERE actor_user_id=\(bind:senderUUID)").run() }
            await #expect(throws:(any Error).self) { try await sql.raw("DELETE FROM im_v2.message_send_completions WHERE sender_user_id=\(bind:senderUUID)").run() }
            }
        }
    }
}

private struct MutationRollbackState:Decodable { let revision:Int64;let withdrawn:Bool }
