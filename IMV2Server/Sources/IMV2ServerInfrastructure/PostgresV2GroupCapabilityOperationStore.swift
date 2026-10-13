import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import IMV2ActorContracts
import SQLKit

public enum V2GroupCapabilityExecutionError: Error, Sendable { case admissionExpired, corruptPersistence }
/// The room owner serializes admission, submit and close using the same operation lock.
/// Domain event/projection mutations and the immutable proof share one transaction.
public struct PostgresV2GroupCapabilityOperationStore: Sendable {
    private let database:any Database
    private var permissionCommit: V2RoomPermissionCommit?
    package func usingPermissionCommit(_ commit: V2RoomPermissionCommit?) -> Self {
        var copy = self; copy.permissionCommit = commit; return copy
    }
    private let clock:@Sendable () -> Date
    public init(database:any Database,clock:@escaping @Sendable () -> Date = Date.init) { self.database=database;self.clock=clock }
    public func admit(_ intent:V2GroupCapabilityIntent,token:V2RoomActivationToken) async throws -> V2GroupCapabilityAdmissionResult {
        try await v2WithRoomScopedTransaction(database:database) { transaction in
            let sql=try await lock(identity:intent.identity,token:token,database:transaction)
            if let existing=try await admission(identity:intent.identity,sql:sql) {
                let fingerprint=try intent.fingerprint
                return existing.identity==intent.identity && existing.intentFingerprint==fingerprint ? .admitted(existing):.fingerprintConflict
            }
            let now=try milliseconds(clock())
            guard now<intent.confirmedUntilMilliseconds else { return .currentUnavailable(.confirmationExpired) }
            guard intent.confirmedUntilMilliseconds-now<=120_000 else { return .currentUnavailable(.invalidConfirmationDeadline) }
            if let rejection=try await authorize(intent,sql:sql) { return .currentUnavailable(.current(rejection)) }
            let after=try milliseconds(clock())
            guard after<intent.confirmedUntilMilliseconds else { return .currentUnavailable(.confirmationExpired) }
            let value=try V2GroupCapabilityAdmission(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,
                issuedAtMilliseconds:after,expiresAtMilliseconds:intent.confirmedUntilMilliseconds,targetJoinedRevision:try await targetIncarnation(intent,sql:sql))
            try await sql.raw("INSERT INTO im_v2.group_capability_admissions(actor_user_id,operation_id,room_id,kind,admission) VALUES(\(bind:intent.identity.accountID.uuidValue!),\(bind:operation(intent.identity)),\(bind:intent.roomID.uuidValue!),\(bind:intent.identity.kind.rawValue),\(bind:json(value))::jsonb)").run()
            return .admitted(value)
        }
    }
    public func submit(_ command:V2GroupCapabilityCommand,token:V2RoomActivationToken,capacityProfile:V2CapacityProfile,eventID:EventID) async throws -> V2GroupCapabilityRecoveryResult {
        try await v2WithRoomPermissionCommit(database: database, permissionCommit: permissionCommit) { transaction in
            let sql=try await lock(identity:command.identity,token:token,database:transaction)
            if let proof=try await original(command.identity,command.fingerprint,sql:sql) { return proof }
            let now=try milliseconds(clock())
            guard let context=try await admission(identity:command.identity,sql:sql),context==command.admission else {
                return .receipt(try await persist(command.identity,command.fingerprint,.rejected(.invalidAdmission),at:now,sql:sql))
            }
            guard now<context.expiresAtMilliseconds else {
                return .receipt(try await persist(command.identity,command.fingerprint,.rejected(.admissionExpired),at:now,sql:sql))
            }
            let outcome:V2GroupCapabilityTerminalOutcome
            if let rejection=try await authorize(command.intent,sql:sql) { outcome = .rejected(rejection) }
            else {
                guard try await targetIncarnation(command.intent,sql:sql)==context.targetJoinedRevision else {
                    return .receipt(try await persist(command.identity,command.fingerprint,.rejected(.targetChanged),at:milliseconds(clock()),sql:sql))
                }
                let store=PostgresV2GroupCapabilitiesStore(database:transaction,activationScope:try .init(tokens:[token]))
                    .usingGroupCapabilityTransaction(expiresAt:Date(timeIntervalSince1970:Double(context.expiresAtMilliseconds)/1000),clock:clock)
                do {
                    let boundTime = clock()
                    _ = try milliseconds(boundTime)
                    let result:DomainResult
                    switch command.intent.action {
                    case .pin(let message,let desired,_):
                        let domain=try V2PinnedMessageCommand(operationID:.init(uuid:operation(command.identity)),roomID:command.intent.roomID,messageID:message,isPinned:desired)
                        result=try map(await store.setPinnedMessage(actorUserID:command.identity.accountID,command:domain,capacityProfile:capacityProfile,eventID:eventID,now:boundTime)) { .pinned(messageID:$0.messageID,isPinned:$0.isPinned,roomSequence:$0.roomSequence) }
                    case .announcement(let body,let revision):
                        let domain=try V2GroupAnnouncementCommand(operationID:.init(uuid:operation(command.identity)),roomID:command.intent.roomID,body:body,expectedRevision:revision)
                        result=try map(await store.setAnnouncement(actorUserID:command.identity.accountID,command:domain,capacityProfile:capacityProfile,eventID:eventID,now:boundTime)) { .announcement(body:$0.body,revision:$0.revision,roomSequence:$0.roomSequence) }
                    case .rolePermissions(let role,let permissions,let revision):
                        let domain=try V2GroupRolePermissionsCommand(operationID:.init(uuid:operation(command.identity)),roomID:command.intent.roomID,role:role,permissions:permissions,expectedRevision:revision)
                        result=try map(await store.setRolePermissions(actorUserID:command.identity.accountID,command:domain,capacityProfile:capacityProfile,eventID:eventID,now:boundTime)) { .rolePermissions(role:$0.role,permissions:$0.permissions,revision:$0.revision,roomSequence:$0.roomSequence) }
                    case .memberRole(let target,let role,let revision):
                        let domain=try V2GroupMemberRoleCommand(operationID:.init(uuid:operation(command.identity)),roomID:command.intent.roomID,targetUserID:target,role:role,expectedMembershipRevision:revision)
                        result=try map(await store.changeMemberRole(actorUserID:command.identity.accountID,command:domain,capacityProfile:capacityProfile,eventID:eventID,now:boundTime)) { .memberRole(targetUserID:$0.targetUserID,role:$0.role,membershipRevision:$0.membershipRevision,roomSequence:$0.roomSequence) }
                    }
                    switch result {
                    case .applied(let value):outcome = .applied(value)
                    case .alreadySatisfied:
                        outcome = .alreadySatisfied(try await currentValue(command.intent,sql:sql))
                    case .retry(let seconds,let rateLimited):
                        return .deferred(try .init(identity:command.identity,fingerprint:command.fingerprint,
                            reason:rateLimited ? .rateLimited:.admissionUnavailable,retryAfterMilliseconds:seconds.map { UInt64(max(1,$0))*1000 }))
                    }
                } catch V2GroupCapabilityExecutionError.admissionExpired { outcome = .rejected(.admissionExpired) }
            }
            let receipt=try await persist(command.identity,command.fingerprint,outcome,at:milliseconds(clock()),sql:sql)
            guard receipt.validates(command:command) else { throw V2GroupCapabilityValidationError.invalidReceipt }
            return .receipt(receipt)
        }
    }
    public func recover(_ request:V2GroupCapabilityRecoveryRequest,token:V2RoomActivationToken) async throws -> V2GroupCapabilityRecoveryResult {
        try await v2WithRoomScopedTransaction(database:database) { transaction in
            let sql=try await lock(identity:request.identity,token:token,database:transaction)
            if let proof=try await original(request.identity,request.fingerprint,sql:sql) { return proof }
            guard request.action == .closeIfAbsent else { return .unresolved }
            return .receipt(try await persist(request.identity,request.fingerprint,.closed,at:milliseconds(clock()),sql:sql))
        }
    }
    public func pinnedBaseline(_ query:V2PinnedMessageBaselineQuery,token:V2RoomActivationToken) async throws -> V2PinnedMessageBaseline {
        guard query.roomID==token.roomID,query.roomID.uuidValue != nil,query.actorUserID.uuidValue != nil,query.messageID.uuidValue != nil else { throw V2GroupCapabilityValidationError.invalidIntent }
        return try await v2WithRoomScopedTransaction(database:database) { transaction in
            guard let sql=transaction as? any SQLDatabase else { throw V2GroupCapabilityExecutionError.corruptPersistence }
            try await v2RequireRoomActivation(token:token,sql:sql)
            let state=try await roomState(query.roomID,sql:sql)
            guard state.kind=="group",let actor=try await member(query.actorUserID,room:query.roomID,revision:state.membership_revision,sql:sql),let role=V2RoomMembershipRole(rawValue:actor.role) else { throw V2GroupCapabilitiesStoreError.actorNotAuthorized }
            let permissions=try await v2ResolvedGroupPermissions(roomID:query.roomID.uuidValue!,role:role,sql:sql)
            guard V2GroupPermissionDefaults.allows(role:role,permission:.pinMessages,configured:permissions) else { throw V2GroupCapabilitiesStoreError.actorNotAuthorized }
            guard let message=try await visibleMessage(query.messageID,room:query.roomID,actor:query.actorUserID,sql:sql) else { throw V2GroupCapabilitiesStoreError.messageNotFound }
            guard message.withdrawn_at==nil else { throw V2GroupCapabilitiesStoreError.messageWithdrawn }
            let pinned=try await pinnedState(query.messageID,room:query.roomID,sql:sql)
            return try .init(roomID:query.roomID,messageID:query.messageID,isPinned:pinned,roomSequence:unsigned(state.room_sequence))
        }
    }
    private func authorize(_ intent:V2GroupCapabilityIntent,sql:any SQLDatabase) async throws -> V2GroupCapabilityRejection? {
        guard let state=try await fetchRoom(intent.roomID,sql:sql) else { return .roomNotFound }
        guard state.kind=="group" else { return .notGroupRoom }
        guard let actor=try await member(intent.identity.accountID,room:intent.roomID,revision:state.membership_revision,sql:sql),let role=V2RoomMembershipRole(rawValue:actor.role) else { return .permissionDenied }
        let required:V2GroupPermission
        switch intent.action { case .pin:required = .pinMessages;case .announcement:required = .manageAnnouncements;case .rolePermissions,.memberRole:required = .changeMemberRoles }
        let permissions=try await v2ResolvedGroupPermissions(roomID:intent.roomID.uuidValue!,role:role,sql:sql)
        guard V2GroupPermissionDefaults.allows(role:role,permission:required,configured:permissions) else { return .permissionDenied }
        let current:UInt64
        switch intent.action {
        case .pin(let message,_,_):
            guard let value=try await visibleMessage(message,room:intent.roomID,actor:intent.identity.accountID,sql:sql) else { return .messageNotFound }
            guard value.withdrawn_at==nil else { return .messageWithdrawn };current=try unsigned(state.room_sequence)
        case .announcement:
            current=try unsigned(await sql.raw("SELECT revision FROM im_v2.group_announcements WHERE room_id=\(bind:intent.roomID.uuidValue!) FOR UPDATE").first(decoding:RevisionRow.self)?.revision ?? 0)
        case .rolePermissions:current=try unsigned(state.group_permission_revision)
        case .memberRole(let target,_,_):
            guard let member=try await member(target,room:intent.roomID,revision:state.membership_revision,sql:sql) else { return .targetNotMember }
            guard member.role != "owner" else { return .permissionDenied }
            current=try unsigned(state.membership_revision)
        }
        return current==intent.action.observedRevision ? nil:.revisionChanged(currentRevision:current)
    }
    private func targetIncarnation(_ intent:V2GroupCapabilityIntent,sql:any SQLDatabase) async throws -> UInt64? {
        guard case .memberRole(let target,_,_)=intent.action else { return nil }
        let state=try await roomState(intent.roomID,sql:sql)
        guard let value=try await member(target,room:intent.roomID,revision:state.membership_revision,sql:sql) else { throw V2GroupCapabilityExecutionError.corruptPersistence }
        return try unsigned(value.joined_revision)
    }
    private func currentValue(_ intent:V2GroupCapabilityIntent,sql:any SQLDatabase) async throws -> V2GroupCapabilityValue {
        let state=try await roomState(intent.roomID,sql:sql),sequence=try unsigned(state.room_sequence)
        switch intent.action {
        case .pin(let message,_,_):return .pinned(messageID:message,isPinned:try await pinnedState(message,room:intent.roomID,sql:sql),roomSequence:sequence)
        case .memberRole(let target,_,_):
            guard let value=try await member(target,room:intent.roomID,revision:state.membership_revision,sql:sql),let role=V2RoomMembershipRole(rawValue:value.role) else { throw V2GroupCapabilityExecutionError.corruptPersistence }
            return .memberRole(targetUserID:target,role:role,membershipRevision:try unsigned(state.membership_revision),roomSequence:sequence)
        default:throw V2GroupCapabilityExecutionError.corruptPersistence
        }
    }
    private enum DomainResult { case applied(V2GroupCapabilityValue),alreadySatisfied,retry(Int?,Bool) }
    private func map<T:Equatable & Sendable>(_ result:V2GroupCapabilitiesOutcome<T>,transform:(T)->V2GroupCapabilityValue) throws -> DomainResult {
        switch result {
        case .applied(let value):return .applied(transform(value))
        case .alreadyInDesiredState:return .alreadySatisfied
        case .rateLimited(let seconds):return .retry(seconds,true)
        case .unavailable:return .retry(nil,false)
        case .idempotent,.idempotencyConflict,.revisionConflict:throw V2GroupCapabilityExecutionError.corruptPersistence
        }
    }
    private func lock(identity:V2OperationIdentity,token:V2RoomActivationToken,database:any Database) async throws -> any SQLDatabase {
        guard try room(identity)==token.roomID,identity.accountID.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil,let sql=database as? any SQLDatabase else { throw V2GroupCapabilityValidationError.invalidIntent }
        let key=identity.accountID.rawValue+":"+identity.operation.rawOperationID
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:key),0))").run()
        try await v2RequireRoomActivation(token:token,sql:sql);return sql
    }
    private func original(_ identity:V2OperationIdentity,_ fingerprint:V2OperationFingerprint,sql:any SQLDatabase) async throws -> V2GroupCapabilityRecoveryResult? {
        guard let row=try await sql.raw("SELECT receipt::text AS payload FROM im_v2.group_capability_receipts WHERE actor_user_id=\(bind:identity.accountID.uuidValue!) AND operation_id=\(bind:operation(identity))").first(decoding:PayloadRow.self) else { return nil }
        let receipt=try v2DecodePersistenceJSON(V2GroupCapabilityReceipt.self, from: row.payload);return receipt.identity==identity && receipt.fingerprint==fingerprint ? .receipt(receipt):.fingerprintConflict
    }
    private func admission(identity:V2OperationIdentity,sql:any SQLDatabase) async throws -> V2GroupCapabilityAdmission? {
        guard let row=try await sql.raw("SELECT admission::text AS payload FROM im_v2.group_capability_admissions WHERE actor_user_id=\(bind:identity.accountID.uuidValue!) AND operation_id=\(bind:operation(identity))").first(decoding:PayloadRow.self) else { return nil }
        return try v2DecodePersistenceJSON(V2GroupCapabilityAdmission.self, from: row.payload)
    }
    private func persist(_ identity:V2OperationIdentity,_ fingerprint:V2OperationFingerprint,_ outcome:V2GroupCapabilityTerminalOutcome,at:UInt64,sql:any SQLDatabase) async throws -> V2GroupCapabilityReceipt {
        let receipt=try V2GroupCapabilityReceipt(identity:identity,fingerprint:fingerprint,outcome:outcome,resolvedAtMilliseconds:at)
        try await sql.raw("INSERT INTO im_v2.group_capability_receipts(actor_user_id,operation_id,room_id,kind,receipt) VALUES(\(bind:identity.accountID.uuidValue!),\(bind:operation(identity)),\(bind:room(identity).uuidValue!),\(bind:identity.kind.rawValue),\(bind:json(receipt))::jsonb)").run();return receipt
    }
    private func room(_ identity:V2OperationIdentity) throws -> RoomID {
        switch identity.scope { case .room(let value),.message(let value,_):return value;default:throw V2GroupCapabilityValidationError.invalidIntent }
    }
    private func operation(_ identity:V2OperationIdentity) throws -> UUID { guard let id=UUID(uuidString:identity.operation.rawOperationID) else { throw V2GroupCapabilityValidationError.invalidIntent };return id }
    private func json<T:Encodable>(_ value:T) throws -> String { try v2EncodePersistenceJSON(value) }
    private func milliseconds(_ value: Date) throws -> UInt64 {
        try v2PersistenceMilliseconds(value, invalid: V2GroupCapabilityExecutionError.corruptPersistence)
    }
    private func unsigned(_ value:Int64) throws -> UInt64 { try v2PersistenceUnsigned(value, invalid: V2GroupCapabilityExecutionError.corruptPersistence) }
    private func fetchRoom(_ room:RoomID,sql:any SQLDatabase) async throws -> RoomRow? { try await sql.raw("SELECT room_kind AS kind,room_sequence,membership_revision,group_permission_revision FROM im_v2.rooms WHERE room_id=\(bind:room.uuidValue!) FOR UPDATE").first(decoding:RoomRow.self) }
    private func roomState(_ room:RoomID,sql:any SQLDatabase) async throws -> RoomRow { guard let state=try await fetchRoom(room,sql:sql) else { throw V2GroupCapabilitiesStoreError.roomNotFound };return state }
    private func member(_ user:UserID,room:RoomID,revision:Int64,sql:any SQLDatabase) async throws -> MemberRow? { try await sql.raw("SELECT role,joined_revision FROM im_v2.room_memberships WHERE room_id=\(bind:room.uuidValue!) AND user_id=\(bind:user.uuidValue!) AND joined_revision<=\(bind:revision) AND (left_revision IS NULL OR left_revision>\(bind:revision)) ORDER BY joined_revision DESC LIMIT 1 FOR UPDATE").first(decoding:MemberRow.self) }
    private func visibleMessage(_ message:MessageID,room:RoomID,actor:UserID,sql:any SQLDatabase) async throws -> MessageRow? { try await sql.raw("SELECT message.withdrawn_at FROM im_v2.messages AS message JOIN im_v2.rooms AS room ON room.room_id=message.room_id WHERE message.message_id=\(bind:message.uuidValue!) AND message.room_id=\(bind:room.uuidValue!) AND (\(v2ForwardSourceVisibility(actorID:actor.uuidValue!))) FOR UPDATE OF message").first(decoding:MessageRow.self) }
    private func pinnedState(_ message:MessageID,room:RoomID,sql:any SQLDatabase) async throws -> Bool { try await sql.raw("SELECT EXISTS(SELECT 1 FROM im_v2.room_pinned_messages WHERE room_id=\(bind:room.uuidValue!) AND message_id=\(bind:message.uuidValue!)) AS value").first(decoding:BoolRow.self)?.value ?? false }
    private struct PayloadRow:Decodable { let payload:String }
    private struct RoomRow:Decodable { let kind:String;let room_sequence:Int64;let membership_revision:Int64;let group_permission_revision:Int64 }
    private struct MemberRow:Decodable { let role:String;let joined_revision:Int64 }
    private struct MessageRow:Decodable { let withdrawn_at:Date? }
    private struct RevisionRow:Decodable { let revision:Int64 }
    private struct BoolRow:Decodable { let value:Bool }
}
