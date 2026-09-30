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
    @Test("durable sendOperation batch counts prior accepted shard reservations")
    func durableSendBatchRespectsCumulativeShardCapacity() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_limit = 1, command_window_used = 0,
                    valid_until = \(bind: now.addingTimeInterval(600))
                WHERE room_shard_id = 'room-a'
                  AND capacity_profile_id = (SELECT capacity_profile_id FROM im_v2.rooms WHERE room_id = \(bind: roomID.uuidValue!))
                """).run()
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
            let deadline = UInt64(now.timeIntervalSince1970 * 1000) + 60_000
            func command(_ text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: text,
                    limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: deadline)
            }
            let batch = try [command("capacity one"), command("capacity two")]
            let results = try await withRoomActivation(database: database, roomID: roomID) { token in
                try await store.sendBatch(batch, token: token, capacityProfile: profile,
                    identifiers: .init(), now: { now })
            }
            #expect(results.count == 2)
            guard case .sendOperation(.receipt(let accepted)) = results[0],
                  case .accepted = accepted.outcome,
                  case .sendOperation(.deferred(let deferred)) = results[1] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(deferred.reason == .rateLimited)
            let pool = try await sql.raw("""
                SELECT command_window_used AS count FROM im_v2.shard_admission_pools
                WHERE room_shard_id = 'room-a'
                  AND capacity_profile_id = (SELECT capacity_profile_id FROM im_v2.rooms WHERE room_id = \(bind: roomID.uuidValue!))
                """).first(decoding: SendRollbackCount.self)
            #expect(pool?.count == 1)
            for (index, item) in batch.enumerated() {
                let completions = try await sql.raw("""
                    SELECT count(*) AS count FROM im_v2.message_send_completions
                    WHERE room_id = \(bind: roomID.uuidValue!) AND sender_user_id = \(bind: senderUUID)
                      AND client_message_id = \(bind: item.command.clientMessageID.uuidValue!)
                    """).first(decoding: SendRollbackCount.self)
                #expect(completions?.count == (index == 0 ? 1 : 0))
            }
        }
    }

    @Test("durable sendOperation batch tail failure rolls back provisional acceptance")
    func durableSendBatchTailFailureRollsBackAcceptedWrites() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_limit = 10, command_window_used = 0,
                    valid_until = \(bind: now.addingTimeInterval(600))
                WHERE room_shard_id = 'room-a'
                  AND capacity_profile_id = (SELECT capacity_profile_id FROM im_v2.rooms WHERE room_id = \(bind: roomID.uuidValue!))
                """).run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.fixture_reject_shard_admission_tail() RETURNS trigger
                LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER fixture_reject_shard_admission_tail
                BEFORE UPDATE OF command_window_used ON im_v2.shard_admission_pools
                FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_reject_shard_admission_tail()
                """).run()
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
            let deadline = UInt64(now.timeIntervalSince1970 * 1000) + 60_000
            let acceptedCandidate = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "tail rollback",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: deadline)
            let expired = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "expired before body",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1)
            let results = try await withRoomActivation(database: database, roomID: roomID) { token in
                try await store.sendBatch([acceptedCandidate, acceptedCandidate, expired], token: token,
                    capacityProfile: profile, identifiers: .init(), now: { now })
            }
            #expect(results.count == 3)
            guard case .sendOperation(.deferred(let tailFailure)) = results[0],
                  case .sendOperation(.deferred(let replayTailFailure)) = results[1] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(tailFailure.reason == .rateLimited)
            #expect(replayTailFailure.reason == .rateLimited)
            guard case .sendOperation(.receipt(let expiredReceipt)) = results[2] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(expiredReceipt.outcome == .rejected(.expiredUnsubmitted))
            let messageCount = try await sql.raw("""
                SELECT count(*) AS count FROM im_v2.message_send_completions
                WHERE room_id = \(bind: roomID.uuidValue!) AND sender_user_id = \(bind: senderUUID)
                  AND client_message_id = \(bind: acceptedCandidate.command.clientMessageID.uuidValue!)
                """).first(decoding: SendRollbackCount.self)
            #expect(messageCount?.count == 0)
            let acceptedReceiptCount = try await sql.raw("""
                SELECT count(*) AS count FROM im_v2.message_send_operation_receipts
                WHERE room_id = \(bind: roomID.uuidValue!) AND actor_user_id = \(bind: senderUUID)
                  AND operation_id = \(bind: acceptedCandidate.command.clientMessageID.uuidValue!)
                """).first(decoding: SendRollbackCount.self)
            #expect(acceptedReceiptCount?.count == 0)
            let expiredReceiptCount = try await sql.raw("""
                SELECT count(*) AS count FROM im_v2.message_send_operation_receipts
                WHERE room_id = \(bind: roomID.uuidValue!) AND actor_user_id = \(bind: senderUUID)
                  AND operation_id = \(bind: expired.command.clientMessageID.uuidValue!)
                """).first(decoding: SendRollbackCount.self)
            #expect(expiredReceiptCount?.count == 1)
            try await sql.raw("DROP TRIGGER fixture_reject_shard_admission_tail ON im_v2.shard_admission_pools").run()
            try await sql.raw("DROP FUNCTION im_v2.fixture_reject_shard_admission_tail()").run()
        }
    }

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
            let batch = try [command("Batch one"), command("Batch two")]
            let batchResults = try await store.sendBatch(batch, token: lease.token, capacityProfile: profile,
                identifiers: .init(), now: { now })
            #expect(batchResults.count == 2)
            for (command, result) in zip(batch, batchResults) {
                guard case .sendOperation(.receipt(let receipt)) = result else { throw CancellationError() }
                #expect(receipt.identity == (try command.identity))
                guard case .accepted = receipt.outcome else { throw CancellationError() }
            }
            #expect(try await store.sendBatch(batch, token: lease.token, capacityProfile: profile,
                identifiers: .init(), now: { now }) == batchResults)
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
            let batchRollback = try [command("Batch rollback one"), command("Batch rollback two")]
            await #expect(throws: (any Error).self) {
                _ = try await store.sendBatch(batchRollback, token: lease.token, capacityProfile: profile,
                    identifiers: .init(), now: { now })
            }
            for item in batchRollback {
                let batchCount = try await sql.raw("SELECT count(*) AS count FROM im_v2.message_send_operation_receipts WHERE operation_id=\(bind:item.command.clientMessageID.uuidValue!)").first(decoding: SendRollbackCount.self)
                #expect(batchCount?.count == 0)
                let completionCount = try await sql.raw("SELECT count(*) AS count FROM im_v2.message_send_completions WHERE client_message_id=\(bind:item.command.clientMessageID.uuidValue!)").first(decoding: SendRollbackCount.self)
                #expect(completionCount?.count == 0)
            }
            try await sql.raw("DROP TRIGGER fixture_receipt_failure ON im_v2.message_send_operation_receipts").run()
            try await sql.raw("DROP FUNCTION im_v2.fixture_receipt_failure()").run()
            await #expect(throws:(any Error).self) { try await sql.raw("DELETE FROM im_v2.message_send_operation_receipts WHERE actor_user_id=\(bind:senderUUID)").run() }
        }
    }
}

private struct SendRollbackCount:Decodable { let count:Int64 }
