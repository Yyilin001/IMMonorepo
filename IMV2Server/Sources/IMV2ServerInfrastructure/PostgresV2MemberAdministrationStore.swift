import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Short online admission and permanent original outcomes, owned by the room activation.
public struct PostgresV2MemberAdministrationStore:Sendable {
    private let database:any Database
    private let clock:@Sendable () -> Date
    public init(database:any Database,clock:@escaping @Sendable () -> Date=Date.init) { self.database=database;self.clock=clock }
    public func admit(_ intent:V2MemberAdministrationIntent,token:V2RoomActivationToken) async throws -> V2MemberAdministrationAdmissionResult {
        guard intent.targetUserID.uuidValue != nil else { throw V2MemberAdministrationValidationError.invalidIntent }
        return try await v2WithRoomScopedTransaction(database:database) { transaction in
            let sql=try await lock(identity:intent.identity,token:token,database:transaction)
            if let prior=try await admission(identity:intent.identity,sql:sql) {
                guard prior.validates(intent:intent) else { return .fingerprintConflict }
                return .admitted(prior)
            }
            let observed=try await authorization(intent,sql:sql)
            switch observed {
            case .failure(let reason):return .currentUnavailable(reason)
            case .success(let state):
                let issued=try milliseconds(clock())
                guard intent.confirmedUntilMilliseconds>issued else { return .currentUnavailable(.confirmationExpired) }
                guard intent.confirmedUntilMilliseconds-issued<=120_000 else { return .currentUnavailable(.invalidConfirmationDeadline) }
                let context=try V2MemberAdministrationAdmission(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,
                    membershipRevision:state.revision,targetJoinedRevision:state.targetJoinedRevision,issuedAtMilliseconds:issued,
                    expiresAtMilliseconds:min(intent.confirmedUntilMilliseconds,issued+120_000))
                try await sql.raw("""
                    INSERT INTO im_v2.member_administration_admissions(actor_user_id,operation_id,room_id,admission)
                    VALUES(\(bind:intent.actorUserID.uuidValue!),\(bind:intent.operationID.uuidValue!),\(bind:intent.roomID.uuidValue!),\(bind:json(context))::jsonb)
                    """).run()
                return .admitted(context)
            }
        }
    }
    public func submit(_ command:V2MemberAdministrationCommand,token:V2RoomActivationToken,
                       capacityProfile:V2CapacityProfile,eventID:EventID) async throws -> V2MemberAdministrationRecoveryResult {
        guard command.intent.targetUserID.uuidValue != nil else { throw V2MemberAdministrationValidationError.invalidIntent }
        return try await v2WithRoomScopedTransaction(database:database) { transaction in
            let sql=try await lock(identity:command.identity,token:token,database:transaction)
            if let prior=try await original(identity:command.identity,fingerprint:command.fingerprint,sql:sql) { return prior }
            var now=clock(),nowMS=try milliseconds(now)
            var outcome:V2MemberAdministrationTerminalOutcome
            guard let context=try await admission(identity:command.identity,sql:sql),context==command.admission else {
                return .receipt(try await persist(command.identity,command.fingerprint,.rejected(.invalidAdmission),at:nowMS,sql:sql))
            }
            guard nowMS<context.expiresAtMilliseconds else {
                return .receipt(try await persist(command.identity,command.fingerprint,.rejected(.admissionExpired),at:nowMS,sql:sql))
            }
            switch try await authorization(command.intent,sql:sql) {
            case .failure(let reason):
                let rejection:V2MemberAdministrationRejection
                switch reason {
                case .permissionDenied:rejection = .permissionDenied
                case .roomNotFound:rejection = .roomNotFound
                case .targetNotMember:rejection = .targetNotMember
                case .membershipChanged(let revision):rejection = .membershipChanged(currentRevision:revision)
                default:throw V2MemberAdministrationValidationError.invalidAdmission
                }
                outcome = .rejected(rejection)
            case .success(let state):
                guard state.targetJoinedRevision==context.targetJoinedRevision else {
                    return .receipt(try await persist(command.identity,command.fingerprint,.rejected(.membershipChanged(currentRevision:state.revision)),at:nowMS,sql:sql))
                }
                now=clock();nowMS=try milliseconds(now)
                guard nowMS<context.expiresAtMilliseconds else {
                    return .receipt(try await persist(command.identity,command.fingerprint,.rejected(.admissionExpired),at:nowMS,sql:sql))
                }
                do {
                    let domain=try domainCommand(command.intent)
                    let store=PostgresV2ModerationStore(database:transaction,activationScope:try .init(tokens:[token])).usingMemberAdministrationTransaction()
                    switch try await store.apply(command:domain,capacityProfile:capacityProfile,eventID:eventID,now:now) {
                    case .applied(let result):
                        nowMS=try milliseconds(result.createdAt)
                        switch command.intent.action {
                        case .mute(let until):outcome = .applied(.muted(untilMilliseconds:until,membershipRevision:state.revision,roomSequence:result.roomSequence,eventID:result.eventID))
                        case .remove:
                            guard let revision=result.membershipRevision else { throw V2MemberAdministrationValidationError.invalidReceipt }
                            outcome = .applied(.removed(membershipRevision:revision,roomSequence:result.roomSequence,eventID:result.eventID))
                        }
                    case .actionAlreadyInDesiredState:
                        guard case .mute=command.intent.action,let row=try await sql.raw("SELECT mute_until FROM im_v2.room_member_mutes WHERE room_id=\(bind:command.intent.roomID.uuidValue!) AND user_id=\(bind:command.intent.targetUserID.uuidValue!)").first(decoding:MuteRow.self) else { throw V2MemberAdministrationValidationError.invalidReceipt }
                        // The SQL comparison already proved the stored timestamp satisfies
                        // the requested deadline at PostgreSQL precision. Round its
                        // canonical deadline up: driver microsecond truncation must
                        // not make an identical millisecond request appear weaker.
                        let observed=row.mute_until.timeIntervalSince1970*1000
                        guard observed.isFinite,observed>0,observed<Double(Int64.max) else { throw V2MemberAdministrationValidationError.invalidReceipt }
                        outcome = .alreadySatisfied(muteUntilMilliseconds:UInt64(observed.rounded(.up)),membershipRevision:state.revision)
                    case .targetNotMember:outcome = .rejected(.targetNotMember)
                    case .rateLimited(let seconds):return .deferred(try .init(identity:command.identity,fingerprint:command.fingerprint,reason:.rateLimited,retryAfterMilliseconds:UInt64(min(86_400,max(1,seconds)))*1000))
                    case .unavailable:return .deferred(try .init(identity:command.identity,fingerprint:command.fingerprint,reason:.admissionUnavailable,retryAfterMilliseconds:nil))
                    case .idempotent,.idempotencyConflict,.messageAlreadyRedacted:throw V2MemberAdministrationValidationError.invalidReceipt
                    }
                } catch V2ModerationValidationError.invalidMuteExpiry { outcome = .rejected(.invalidMuteExpiry) }
                  catch V2ModerationAuthorizationError.notAuthorized { outcome = .rejected(.permissionDenied) }
                  catch V2ModerationStoreError.actorNotAuthorized { outcome = .rejected(.permissionDenied) }
            }
            let receipt=try await persist(command.identity,command.fingerprint,outcome,at:nowMS,sql:sql)
            guard receipt.validates(command:command) else { throw V2MemberAdministrationValidationError.invalidReceipt }
            return .receipt(receipt)
        }
    }
    public func recover(_ request:V2MemberAdministrationRecoveryRequest,token:V2RoomActivationToken) async throws -> V2MemberAdministrationRecoveryResult {
        try await v2WithRoomScopedTransaction(database:database) { transaction in
            let sql=try await lock(identity:request.identity,token:token,database:transaction)
            if let prior=try await original(identity:request.identity,fingerprint:request.fingerprint,sql:sql) { return prior }
            guard request.action == .closeIfAbsent else { return .unresolved }
            return .receipt(try await persist(request.identity,request.fingerprint,.closed,at:milliseconds(clock()),sql:sql))
        }
    }
    private enum Authorization { case success(State),failure(V2MemberAdministrationAdmissionUnavailable) }
    private struct State { let revision:UInt64;let targetJoinedRevision:UInt64 }
    private func authorization(_ intent:V2MemberAdministrationIntent,sql:any SQLDatabase) async throws -> Authorization {
        guard let row=try await sql.raw("SELECT room_kind AS kind,membership_revision FROM im_v2.rooms WHERE room_id=\(bind:intent.roomID.uuidValue!) FOR UPDATE").first(decoding:RoomRow.self) else { return .failure(.roomNotFound) }
        guard row.kind=="group",row.membership_revision>=0,
            let actor=try await activeMember(intent.actorUserID,intent: intent,revision:row.membership_revision,sql:sql),
            let role=V2RoomMembershipRole(rawValue:actor.role) else { return .failure(.permissionDenied) }
        let required:V2GroupPermission
        switch intent.action { case .mute:required = .muteMembers;case .remove:required = .removeMembers }
        let configured=try await v2ResolvedGroupPermissions(roomID:intent.roomID.uuidValue!,role:role,sql:sql)
        guard V2GroupPermissionDefaults.allows(role:role,permission:required,configured:configured) else { return .failure(.permissionDenied) }
        guard let target=try await activeMember(intent.targetUserID,intent:intent,revision:row.membership_revision,sql:sql) else { return .failure(.targetNotMember) }
        guard target.role != "owner" else { return .failure(.permissionDenied) }
        guard UInt64(row.membership_revision)==intent.expectedMembershipRevision else { return .failure(.membershipChanged(currentRevision:UInt64(row.membership_revision))) }
        guard target.joined_revision>=0 else { throw V2ModerationStoreError.corruptPersistenceState }
        return .success(.init(revision:UInt64(row.membership_revision),targetJoinedRevision:UInt64(target.joined_revision)))
    }
    private func activeMember(_ user:UserID,intent:V2MemberAdministrationIntent,revision:Int64,sql:any SQLDatabase) async throws -> MemberRow? {
        try await sql.raw("SELECT role,joined_revision FROM im_v2.room_memberships WHERE room_id=\(bind:intent.roomID.uuidValue!) AND user_id=\(bind:user.uuidValue!) AND joined_revision<=\(bind:revision) AND (left_revision IS NULL OR left_revision>\(bind:revision)) ORDER BY joined_revision DESC LIMIT 1 FOR UPDATE").first(decoding:MemberRow.self)
    }
    private func lock(identity:V2OperationIdentity,token:V2RoomActivationToken,database:any Database) async throws -> any SQLDatabase {
        guard case .room(let room)=identity.scope,room==token.roomID,let actor=identity.accountID.uuidValue,let operation=UUID(uuidString:identity.operation.rawOperationID),let sql=database as? any SQLDatabase else { throw V2MemberAdministrationValidationError.invalidIntent }
        let key=actor.uuidString+":"+operation.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:key),0))").run()
        try await v2RequireRoomActivation(token:token,sql:sql)
        return sql
    }
    private func admission(identity:V2OperationIdentity,sql:any SQLDatabase) async throws -> V2MemberAdministrationAdmission? {
        guard let row=try await sql.raw("SELECT admission::text AS payload FROM im_v2.member_administration_admissions WHERE actor_user_id=\(bind:identity.accountID.uuidValue!) AND operation_id=\(bind:UUID(uuidString:identity.operation.rawOperationID)!)").first(decoding:PayloadRow.self) else { return nil }
        let value=try JSONDecoder().decode(V2MemberAdministrationAdmission.self,from:Data(row.payload.utf8))
        return value
    }
    private func original(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,sql:any SQLDatabase) async throws -> V2MemberAdministrationRecoveryResult? {
        guard let row=try await sql.raw("SELECT receipt::text AS payload FROM im_v2.member_administration_receipts WHERE actor_user_id=\(bind:identity.accountID.uuidValue!) AND operation_id=\(bind:UUID(uuidString:identity.operation.rawOperationID)!)").first(decoding:PayloadRow.self) else { return nil }
        let value=try JSONDecoder().decode(V2MemberAdministrationReceipt.self,from:Data(row.payload.utf8))
        guard value.identity==identity,value.fingerprint==fingerprint else { return .fingerprintConflict };return .receipt(value)
    }
    private func persist(_ identity:V2OperationIdentity,_ fingerprint:V2OperationFingerprint,_ outcome:V2MemberAdministrationTerminalOutcome,at:UInt64,sql:any SQLDatabase) async throws -> V2MemberAdministrationReceipt {
        let receipt=try V2MemberAdministrationReceipt(identity:identity,fingerprint:fingerprint,outcome:outcome,resolvedAtMilliseconds:at)
        try await sql.raw("INSERT INTO im_v2.member_administration_receipts(actor_user_id,operation_id,room_id,receipt) VALUES(\(bind:identity.accountID.uuidValue!),\(bind:UUID(uuidString:identity.operation.rawOperationID)!),\(bind:room(identity).uuidValue!),\(bind:json(receipt))::jsonb)").run()
        return receipt
    }
    private func room(_ identity:V2OperationIdentity) throws -> RoomID { guard case .room(let room)=identity.scope else { throw V2MemberAdministrationValidationError.invalidIntent };return room }
    private func domainCommand(_ intent:V2MemberAdministrationIntent) throws -> V2ModerationCommand {
        let action:V2ModerationAction,until:Date?
        switch intent.action { case .mute(let milliseconds):action = .muteMember;until=Date(timeIntervalSince1970:Double(milliseconds)/1000);case .remove:action = .removeMember;until=nil }
        return try .init(roomID:intent.roomID,actorUserID:intent.actorUserID,operationID:intent.operationID,action:action,targetUserID:intent.targetUserID,muteUntil:until,reasonCode:intent.reasonCode)
    }
    private func milliseconds(_ date:Date) throws -> UInt64 { let value=date.timeIntervalSince1970*1000;guard value.isFinite,value>0,value<Double(Int64.max) else { throw V2MemberAdministrationValidationError.invalidReceipt };return UInt64(value) }
    private func json<T:Encodable>(_ value:T) throws -> String { String(decoding:try JSONEncoder().encode(value),as:UTF8.self) }
    private struct PayloadRow:Decodable { let payload:String }
    private struct RoomRow:Decodable { let kind:String;let membership_revision:Int64 }
    private struct MemberRow:Decodable { let role:String;let joined_revision:Int64 }
    private struct MuteRow:Decodable { let mute_until:Date }
}
