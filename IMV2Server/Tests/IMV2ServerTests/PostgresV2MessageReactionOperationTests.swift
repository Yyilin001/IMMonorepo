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
    @Test("reaction original outcomes fence inverse intents and survive receipt rollback")
    func permanentMessageReactionReceipts() async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            let now=Date(timeIntervalSince1970:1_750_000_000),profile=try forwardImportTestProfile()
            let sends=try V2SendMessageService(store:PostgresV2RoomWriteStore(database:database),capacityProfile:profile,limits:.init(maxUTF8Bytes:64),now:{now})
            guard case .accepted(let message)=try await sends.send(.init(roomID:roomID,actorUserID:senderID,clientMessageID:.init(uuid:UUID()),text:"Reaction target")) else { throw CancellationError() }
            guard case .acquired(let lease)=try await PostgresV2RoomActivationStore(database:database).acquire(roomID:roomID,owner:.init(shardID:"room-a",epoch:0),host:.init(hostID:.init("reaction-receipts"),incarnationID:UUID()),duration:.init(30_000)) else { throw CancellationError() }
            let store=PostgresV2MessageReactionOperationStore(database:database,clock:{now})
            func command(_ action:V2MessageReactionAction,_ revision:UInt64,operation:MessageReactionOperationID = .init(uuid:UUID()),deadline:UInt64? = nil) throws -> V2MessageReactionOperationCommand {
                try .init(command:.init(roomID:roomID,actorUserID:senderID,operationID:operation,messageID:message.messageID,reaction:"👍",action:action),expectedReactionRevision:revision,firstSubmissionDeadlineMilliseconds:deadline ?? UInt64(now.timeIntervalSince1970*1000)+60_000)
            }
            let baseline=try await store.snapshot(roomID:roomID,actorUserID:senderID,messageID:message.messageID,reaction:"👍",token:lease.token)
            #expect(baseline.revision==0 && baseline.targetState == .absent)
            let add=try command(.add,0)
            guard case .receipt(let original)=try await store.change(add,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now),case .committed(let first)=original.outcome else { throw CancellationError() }
            #expect(first.revision==1 && first.targetState == .present && first.event != nil)
            #expect(try await store.change(add,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now) == .receipt(original))
            let noOp=try command(.add,1)
            guard case .receipt(let noOpReceipt)=try await store.change(noOp,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now),case .committed(let noOpCommit)=noOpReceipt.outcome else { throw CancellationError() }
            #expect(noOpCommit.revision==2 && noOpCommit.event==nil)
            let stale=try command(.remove,1)
            guard case .receipt(let staleReceipt)=try await store.change(stale,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now) else { throw CancellationError() }
            #expect(staleReceipt.outcome == .rejected(.revisionConflict(current:2)))
            let removal=try command(.remove,2)
            guard case .receipt(let removed)=try await store.change(removal,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now),case .committed(let removedCommit)=removed.outcome else { throw CancellationError() }
            #expect(removedCommit.revision==3 && removedCommit.targetState == .absent)
            #expect(try await store.recover(.init(identity:add.identity,fingerprint:add.fingerprint,action:.query),token:lease.token,now:now) == .receipt(original))
            let changed=try command(.remove,0,operation:add.operationID)
            #expect(try await store.change(changed,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now) == .fingerprintConflict)
            let closed=try command(.add,3)
            guard case .receipt(let closeReceipt)=try await store.recover(.init(identity:closed.identity,fingerprint:closed.fingerprint,action:.closeIfAbsent),token:lease.token,now:now) else { throw CancellationError() }
            #expect(closeReceipt.outcome == .closed)
            #expect(try await store.change(closed,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now) == .receipt(closeReceipt))
            let expired=try command(.add,3,deadline:UInt64(now.timeIntervalSince1970*1000)-1)
            guard case .receipt(let expiry)=try await store.change(expired,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now) else { throw CancellationError() }
            #expect(expiry.outcome == .rejected(.expiredUnsubmitted))
            try await sql.raw("CREATE FUNCTION im_v2.fixture_reaction_receipt_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture failure' USING ERRCODE='23514'; END $$").run()
            try await sql.raw("CREATE TRIGGER fixture_reaction_receipt_failure BEFORE INSERT ON im_v2.message_reaction_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_reaction_receipt_failure()").run()
            let rolledBack=try command(.add,3)
            await #expect(throws:(any Error).self) { _ = try await store.change(rolledBack,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now) }
            let retained=try await store.snapshot(roomID:roomID,actorUserID:senderID,messageID:message.messageID,reaction:"👍",token:lease.token)
            #expect(retained.revision==3 && retained.targetState == .absent)
            let count=try await sql.raw("SELECT count(*)::bigint AS count FROM im_v2.message_reactions WHERE message_id=\(bind:message.messageID.uuidValue!)").first(decoding:ReactionTestCount.self)
            #expect(count?.count==0)
            try await sql.raw("DROP TRIGGER fixture_reaction_receipt_failure ON im_v2.message_reaction_receipts").run()
            try await sql.raw("DROP FUNCTION im_v2.fixture_reaction_receipt_failure()").run()
            for _ in 0..<4 {
                let current=try await store.snapshot(roomID:roomID,actorUserID:senderID,messageID:message.messageID,reaction:"👍",token:lease.token)
                let racing=try command(.add,current.revision)
                let request=try V2MessageReactionRecoveryRequest(identity:racing.identity,fingerprint:racing.fingerprint,action:.closeIfAbsent)
                async let submitted=store.change(racing,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now)
                async let closed=store.recover(request,token:lease.token,now:now)
                let results=try await (submitted,closed)
                #expect(results.0==results.1)
            }
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=2 WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2 WHERE room_id=\(bind:roomUUID)").run()
            #expect(try await store.recover(.init(identity:add.identity,fingerprint:add.fingerprint,action:.query),token:lease.token,now:now) == .receipt(original))
            await #expect(throws:(any Error).self) { _ = try await store.snapshot(roomID:roomID,actorUserID:senderID,messageID:message.messageID,reaction:"👍",token:lease.token) }
            try await sql.raw("UPDATE im_v2.room_activation_leases SET activation_epoch=activation_epoch+1 WHERE room_id=\(bind:roomUUID)").run()
            await #expect(throws:(any Error).self) { _ = try await store.recover(.init(identity:add.identity,fingerprint:add.fingerprint,action:.query),token:lease.token,now:now) }
            await #expect(throws:(any Error).self) { try await sql.raw("DELETE FROM im_v2.message_reaction_receipts WHERE actor_user_id=\(bind:senderUUID)").run() }
        }
    }
}
private struct ReactionTestCount:Decodable { let count:Int64 }
