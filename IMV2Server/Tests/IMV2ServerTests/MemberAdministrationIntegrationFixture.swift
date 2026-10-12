@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

/// Test fixture for existing domain assertions. Every member effect uses the new
/// owner admission and bound submit; it never calls the retired member ledger.
func applyAdmittedMemberFixture(database:any Database,command:V2ModerationCommand,profile:V2CapacityProfile,eventID:EventID,now:Date,ownerRoute:V2RoomShardRoute?=nil,token:V2RoomActivationToken?=nil) async throws -> V2ModerationOutcome {
    guard let sql=database as? any SQLDatabase,let room=command.roomID.uuidValue,let actor=command.actorUserID.uuidValue,let operation=command.operationID.uuidValue,let target=command.targetUserID else { throw V2ModerationStoreError.corruptPersistenceState }
    if let ownerRoute { try await v2RequireRoomOwner(roomID:room,route:ownerRoute,sql:sql) }
    let route=try #require(try await sql.raw("SELECT room_shard_id,route_epoch FROM im_v2.room_owner_routes WHERE room_id=\(bind:room)").first(decoding:MemberFixtureRoute.self))
    @Sendable func perform(_ token:V2RoomActivationToken) async throws -> V2ModerationOutcome {
        let prior=try await sql.raw("SELECT admission::text AS payload FROM im_v2.member_administration_admissions WHERE actor_user_id=\(bind:actor) AND operation_id=\(bind:operation)").first(decoding:MemberFixturePayload.self)
        let context=try prior.map { try JSONDecoder().decode(V2MemberAdministrationAdmission.self,from:Data($0.payload.utf8)) }
        let revision=try #require(try await sql.raw("SELECT membership_revision AS value FROM im_v2.rooms WHERE room_id=\(bind:room)").first(decoding:MemberFixtureRevision.self)).value
        let stamp=now.timeIntervalSince1970*1000
        guard stamp.isFinite,stamp>0,stamp<Double(Int64.max)-120_000,v2PostgresTimestampCanEncode(now),v2PostgresTimestampCanEncode(now.addingTimeInterval(180*86_400)) else { throw V2ModerationStoreError.corruptPersistenceState }
        let action:V2MemberAdministrationAction
        switch command.action {
        case .muteMember:
            guard let expiry=command.muteUntil,v2PostgresTimestampCanEncode(expiry),let until=command.muteUntil?.timeIntervalSince1970,until.isFinite,until>0,until<Double(Int64.max)/1000 else { throw V2ModerationValidationError.invalidMuteExpiry }
            action = .mute(untilMilliseconds:UInt64(until*1000))
        case .removeMember:action = .remove
        default:throw V2ModerationStoreError.unsupportedAction
        }
        let intent=try V2MemberAdministrationIntent(roomID:command.roomID,actorUserID:command.actorUserID,operationID:command.operationID,targetUserID:target,action:action,reasonCode:command.reasonCode,expectedMembershipRevision:context?.membershipRevision ?? UInt64(revision),confirmedUntilMilliseconds:context?.expiresAtMilliseconds ?? UInt64(stamp)+120_000)
        let store=PostgresV2MemberAdministrationStore(database:database,clock:{now})
        let issued:V2MemberAdministrationAdmission
        switch try await store.admit(intent,token:token) {
        case .admitted(let value):issued=value
        case .fingerprintConflict:return .idempotencyConflict
        case .currentUnavailable(.targetNotMember):return .targetNotMember
        case .currentUnavailable(.permissionDenied):throw V2ModerationAuthorizationError.notAuthorized
        case .currentUnavailable(.roomNotFound):throw V2ModerationStoreError.roomNotFound
        case .currentUnavailable:throw V2ModerationStoreError.corruptPersistenceState
        }
        let frozen=try V2MemberAdministrationCommand(intent:intent,admission:issued)
        let original=try await sql.raw("SELECT count(*) AS value FROM im_v2.member_administration_receipts WHERE actor_user_id=\(bind:actor) AND operation_id=\(bind:operation)").first(decoding:MemberFixtureRevision.self)?.value == 1
        switch try await store.submit(frozen,token:token,capacityProfile:profile,eventID:eventID) {
        case .receipt(let receipt):
            let result:V2ModerationResult
            switch receipt.outcome {
            case .applied(.muted(let until,_,let sequence,let event)):
                result=try .init(roomID:command.roomID,operationID:command.operationID,action:.muteMember,targetUserID:target,messageID:nil,muteUntil:Date(timeIntervalSince1970:Double(until)/1000),roomSequence:sequence,eventID:event,createdAt:Date(timeIntervalSince1970:Double(receipt.resolvedAtMilliseconds)/1000))
            case .applied(.removed(let revision,let sequence,let event)):
                result=try .init(roomID:command.roomID,operationID:command.operationID,action:.removeMember,targetUserID:target,messageID:nil,membershipRevision:revision,muteUntil:nil,roomSequence:sequence,eventID:event,createdAt:Date(timeIntervalSince1970:Double(receipt.resolvedAtMilliseconds)/1000))
            case .alreadySatisfied:return .actionAlreadyInDesiredState
            case .rejected(.targetNotMember):return .targetNotMember
            case .rejected(.permissionDenied):throw V2ModerationAuthorizationError.notAuthorized
            case .rejected(.invalidMuteExpiry):throw V2ModerationValidationError.invalidMuteExpiry
            case .rejected(.roomNotFound):throw V2ModerationStoreError.roomNotFound
            default:throw V2ModerationStoreError.corruptPersistenceState
            }
            return original ? .idempotent(result):.applied(result)
        case .fingerprintConflict:return .idempotencyConflict
        case .deferred(let hint):return .rateLimited(retryAfterSeconds:Int((hint.retryAfterMilliseconds ?? 1000)/1000))
        case .unresolved:throw V2ModerationStoreError.corruptPersistenceState
        }
    }
    if let token { return try await perform(token) }
    return try await withRoomActivation(database:database,roomID:command.roomID,shardID:ownerRoute?.shardID ?? route.room_shard_id,epoch:ownerRoute.map{Int64($0.epoch)} ?? route.route_epoch,perform)
}
private struct MemberFixtureRoute:Decodable { let room_shard_id:String;let route_epoch:Int64 }
private struct MemberFixturePayload:Decodable { let payload:String }
private struct MemberFixtureRevision:Decodable { let value:Int64 }

extension PostgresV2RoomWriteStoreIntegrationTests {
    /// Member results now retain canonical milliseconds in immutable proof;
    /// domain event and audit timestamps still use PostgreSQL precision.
    func verifyMemberClockFixture(database:any Database,sql:any SQLDatabase,profile:V2CapacityProfile,kind:String) async throws {
        for fraction in [0.00000025,0.001,0.1234567] {
            let now=Date(timeIntervalSince1970:1_750_000_000+fraction),ms=UInt64(now.timeIntervalSince1970*1000)
            let store=PostgresV2MemberAdministrationStore(database:database,clock:{now})
            try await withRoomActivation(database:database,roomID:roomID) { token in
                let revision=try #require(try await sql.raw("SELECT membership_revision AS value FROM im_v2.rooms WHERE room_id=\(bind:roomUUID)").first(decoding:MemberFixtureRevision.self)).value
                let intent=try V2MemberAdministrationIntent(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),targetUserID:.init(uuid:memberTwoUUID),action:kind == "remove" ? .remove : .mute(untilMilliseconds:ms+60_000),reasonCode:.init("abuse_spam"),expectedMembershipRevision:UInt64(revision),confirmedUntilMilliseconds:ms+120_000)
                guard case .admitted(let admission)=try await store.admit(intent,token:token) else { throw CancellationError() }
                let command=try V2MemberAdministrationCommand(intent:intent,admission:admission)
                guard case .receipt(let receipt)=try await store.submit(command,token:token,capacityProfile:profile,eventID:.init(uuid:UUID())) else { throw CancellationError() }
                #expect(receipt.validates(command:command))
                let eventID:EventID
                switch receipt.outcome {
                case .applied(.muted(_,_,_,let event)),.applied(.removed(_,_,let event)):eventID=event
                default:throw CancellationError()
                }
                if kind == "mute" {
                    let repeated=try V2MemberAdministrationIntent(roomID:intent.roomID,actorUserID:intent.actorUserID,operationID:.init(uuid:UUID()),targetUserID:intent.targetUserID,action:intent.action,reasonCode:intent.reasonCode,expectedMembershipRevision:intent.expectedMembershipRevision,confirmedUntilMilliseconds:intent.confirmedUntilMilliseconds)
                    guard case .admitted(let repeatedAdmission)=try await store.admit(repeated,token:token) else { throw CancellationError() }
                    let repeatedCommand=try V2MemberAdministrationCommand(intent:repeated,admission:repeatedAdmission)
                    guard case .receipt(let noOp)=try await store.submit(repeatedCommand,token:token,capacityProfile:profile,eventID:.init(uuid:UUID())) else { throw CancellationError() }
                    #expect(noOp.validates(command:repeatedCommand))
                    #expect(noOp.outcome == .alreadySatisfied(muteUntilMilliseconds:ms+60_000,membershipRevision:UInt64(revision)))
                }
                let event=try #require(try await sql.raw("SELECT created_at AS value FROM im_v2.room_events WHERE event_id=\(bind:eventID.uuidValue!)").first(decoding:RevocationClockDateRow.self)).value
                #expect(try v2GatewayMilliseconds(event)==Int64(receipt.resolvedAtMilliseconds))
                let normalized=try #require(try await sql.raw("SELECT \(bind:now)::timestamptz AS value").first(decoding:RevocationClockDateRow.self)).value
                #expect(event==normalized)
                let audit=try #require(try await sql.raw("SELECT occurred_at AS value FROM im_v2.moderation_audit_entries WHERE actor_user_id=\(bind:senderUUID) AND operation_id=\(bind:intent.operationID.uuidValue!)").first(decoding:RevocationClockDateRow.self)).value
                #expect(event==audit)
                #expect(try await store.submit(command,token:token,capacityProfile:profile,eventID:.init(uuid:UUID())) == .receipt(receipt))
                await #expect(throws:(any Error).self) { try await sql.raw("UPDATE im_v2.member_administration_receipts SET receipt=jsonb_set(receipt,'{resolvedAtMilliseconds}','0') WHERE actor_user_id=\(bind:senderUUID) AND operation_id=\(bind:intent.operationID.uuidValue!)").run() }
                #expect(try await store.recover(.init(identity:command.identity,fingerprint:command.fingerprint,action:.query),token:token) == .receipt(receipt))
            }
            if kind == "remove" {
                let revision=try #require(try await sql.raw("SELECT membership_revision AS value FROM im_v2.rooms WHERE room_id=\(bind:roomUUID)").first(decoding:MemberFixtureRevision.self)).value
                let target = UserID(uuid: memberTwoUUID)
                let identity = try await V2PostgresMembershipIdentitySnapshotValidator(database: database)
                    .snapshot(actorUserID: senderID, targetUserID: target)
                try await withRoomActivation(database: database, roomID: roomID) { token in
                    let membership = PostgresV2MembershipOperationStore(database: database, clock: { now })
                    let intent = try V2MembershipIntent(roomID: roomID, actorUserID: senderID,
                        operationID: .init(uuid: UUID()), targetUserID: target, action: .add,
                        expectedMembershipRevision: UInt64(revision), confirmedUntilMilliseconds: ms+120_000)
                    guard case .admitted(let admission) = try await membership.admit(intent, identitySnapshot: identity, token: token) else { throw CancellationError() }
                    let command = try V2MembershipOperationCommand(intent: intent, admission: admission)
                    guard case .receipt(let proof) = try await membership.submit(command, token: token,
                        capacityProfile: profile, eventID: .init(uuid: UUID()), identitySnapshot: identity) else { throw CancellationError() }
                    #expect(proof.validates(command: command))
                }
            }
        }
        #expect(try await count("im_v2.moderation_operations",on:sql)==0)
    }
}
