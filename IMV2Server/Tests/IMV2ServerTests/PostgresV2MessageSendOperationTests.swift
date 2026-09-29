@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
@testable import IMV2ServerGateway

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("send execution v1 wraps v3 and permanently resolves submission close races",arguments:[false,true])
    func permanentMessageSendReceipts(direct:Bool) async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            let now=Date(timeIntervalSince1970:1_750_000_000),profile=try forwardImportTestProfile()
            let operationRoom=direct ? RoomID(uuid:UUID()) : roomID
            if direct {
                _ = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                    roomShardID: "room-a", roomID: operationRoom, now: { now }).openedReceipt(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            }
            let leases=PostgresV2RoomActivationStore(database:database)
            let owner=try V2RoomDataOwner(shardID:"room-a",epoch:0)
            guard case .acquired(let lease)=try await leases.acquire(roomID:operationRoom,owner:owner,host:.init(hostID:.init("send-receipts"),incarnationID:UUID()),duration:.init(30_000)) else { throw CancellationError() }
            let store=PostgresV2MessageSendOperationStore(database:database,writes:PostgresV2RoomWriteStore(database:database,strangerMessagePolicy:try .init(maximumMessagesPerWindow:100,window:86_400),contentReviewMode:.disabled).usingControlDatabase(database),clock:{now})
            let deadline=UInt64(now.timeIntervalSince1970*1000)+60_000
            func command(_ text:String,operation:ClientMessageID = .init(uuid:UUID()),deadlineMS:UInt64? = nil) throws -> V2MessageSendOperationCommand {
                try .init(command:.init(roomID:operationRoom,senderUserID:senderID,clientMessageID:operation,text:text,limits:.init(maxUTF8Bytes:64)),firstSubmissionDeadlineMilliseconds:deadlineMS ?? deadline)
            }
            func recovery(_ command:V2MessageSendOperationCommand,_ action:V2OperationRecoveryRequest.Action) throws -> V2MessageSendOperationRecoveryRequest {
                try .init(identity:command.identity,fingerprint:command.fingerprint,domainFingerprint:command.command.fingerprint,action:action)
            }
            let first=try command("Accepted")
            #expect(try first.fingerprint.version==1 && first.command.fingerprint.version==3)
            guard case .receipt(let original)=try await store.send(first,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) else { throw CancellationError() }
            guard case .accepted(let accepted)=original.outcome else { throw CancellationError() }
            // The protobuf Gateway command and JSON HTTP command must reach the
            // same durable operation key and return the original receipt.
            let gatewayCommand = try V2MessageSendOperationWireCodec.decode(
                command: V2MessageSendOperationWireCodec.encode(command: first))
            let httpCommand = try JSONDecoder().decode(V2MessageSendOperationCommand.self,
                from: JSONEncoder().encode(first))
            #expect(gatewayCommand == httpCommand)
            #expect(try await store.send(gatewayCommand,token:lease.token,capacityProfile:profile,
                identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) == .receipt(original))
            let gatewayRecovery = try V2MessageSendOperationWireCodec.decode(recovery:
                V2MessageSendOperationWireCodec.encode(recovery: recovery(first,.query)))
            #expect(try await store.recover(gatewayRecovery,token:lease.token) == .receipt(original))
            #expect(try await store.send(first,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) == .receipt(original))
            #expect(try await store.recover(recovery(first,.query),token:lease.token) == .receipt(original))
            let changed=try command("Changed",operation:first.command.clientMessageID)
            #expect(try await store.send(changed,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) == .fingerprintConflict)
            let expired=try command("Expired",deadlineMS:deadline-120_000)
            guard case .receipt(let expiredReceipt)=try await store.send(expired,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) else { throw CancellationError() }
            #expect(expiredReceipt.outcome == .rejected(.expiredUnsubmitted))
            let closed=try command("Closed")
            guard case .receipt(let closedReceipt)=try await store.recover(recovery(closed,.closeIfAbsent),token:lease.token) else { throw CancellationError() }
            #expect(closedReceipt.outcome == .closed)
            #expect(try await store.send(closed,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) == .receipt(closedReceipt))
            for _ in 0..<4 {
                let racing=try command("Race")
                async let send=store.send(racing,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID())))
                async let close=store.recover(recovery(racing,.closeIfAbsent),token:lease.token)
                let (submitted,closed)=try await(send,close)
                #expect(submitted==closed)
                guard case .receipt=closed else { throw CancellationError() }
            }
            if direct {
                let limited=PostgresV2MessageSendOperationStore(database:database,writes:PostgresV2RoomWriteStore(database:database,strangerMessagePolicy:try .init(maximumMessagesPerWindow:1,window:86_400),contentReviewMode:.disabled).usingControlDatabase(database),clock:{now})
                let quota=try command("Quota")
                guard case .deferred(let quotaHint)=try await limited.send(quota,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) else { throw CancellationError() }
                #expect(quotaHint.reason == .rateLimited && quotaHint.retryAfterMilliseconds == 86_400_000)
                #expect(try quotaHint.validates(identity:quota.identity,fingerprint:quota.fingerprint))
                #expect(try await limited.recover(recovery(quota,.query),token:lease.token) == .unresolved)
                guard case .receipt(let quotaClose)=try await limited.recover(recovery(quota,.closeIfAbsent),token:lease.token) else { throw CancellationError() }
                #expect(quotaClose.outcome == .closed)
                let generation=try await sql.raw("SELECT generation AS count FROM im_v2.direct_authorization_intents WHERE room_id=\(bind:operationRoom.uuidValue!) AND sender_user_id=\(bind:senderUUID) AND client_message_id=\(bind:quota.command.clientMessageID.uuidValue!)").first(decoding:SendRollbackCount.self)
                let attempt=V2DirectAuthorizationAttempt(roomID:operationRoom.uuidValue!,senderID:senderUUID,clientMessageID:quota.command.clientMessageID.uuidValue!,generation:try #require(generation).count,recipientID:memberTwoUUID,ownerShardID:"room-a",ownerEpoch:0,fingerprint:quota.command.fingerprint.digest)
                let proof=try await PostgresV2DirectAuthorizationReceiptStore().committedReceipt(attempt,database:database)
                #expect(proof?.disposition == .aborted && proof?.eventID==nil)
                _ = try await PostgresV2DirectAuthorizationIntentStore(database:database).resolve(attempt,receipt:try #require(proof),now:now)
            }
            // Body retention cannot erase the minimal original acceptance identity.
            try await sql.raw("UPDATE im_v2.messages SET text_body='Retained replacement',content_revision=content_revision+1 WHERE message_id=\(bind:accepted.messageID.uuidValue!)").run()
            #expect(try await store.recover(recovery(first,.query),token:lease.token) == .receipt(original))
            try await sql.raw("CREATE FUNCTION im_v2.fixture_receipt_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture failure' USING ERRCODE='23514'; END $$").run()
            try await sql.raw("CREATE TRIGGER fixture_receipt_failure BEFORE INSERT ON im_v2.message_send_operation_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_receipt_failure()").run()
            let rolledBack=try command("Rollback")
            await #expect(throws:(any Error).self) { _ = try await store.send(rolledBack,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) }
            let countRow=try await sql.raw("SELECT count(*) AS count FROM im_v2.message_send_completions WHERE client_message_id=\(bind:rolledBack.command.clientMessageID.uuidValue!)").first(decoding:SendRollbackCount.self)
            #expect(countRow?.count==0)
            try await sql.raw("DROP TRIGGER fixture_receipt_failure ON im_v2.message_send_operation_receipts").run()
            try await sql.raw("DROP FUNCTION im_v2.fixture_receipt_failure()").run()
            await #expect(throws:(any Error).self) { try await sql.raw("DELETE FROM im_v2.message_send_operation_receipts WHERE actor_user_id=\(bind:senderUUID)").run() }
        }
    }
}

private struct SendRollbackCount:Decodable { let count:Int64 }
