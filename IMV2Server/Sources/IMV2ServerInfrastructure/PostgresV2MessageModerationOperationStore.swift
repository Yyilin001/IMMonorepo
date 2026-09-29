import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Original proof, short immutable gate, and redaction facts share one room-owner transaction.
public struct PostgresV2MessageModerationOperationStore:Sendable {
    private let database:any Database
    private let clock:@Sendable ()->Date
    public init(database:any Database,clock:@escaping @Sendable ()->Date=Date.init) {self.database=database;self.clock=clock}
    public func baseline(_ query:V2MessageModerationBaselineQuery,token:V2RoomActivationToken) async throws -> V2MessageModerationBaseline {
        try await v2WithRoomScopedTransaction(database:database) { tx in
            guard let sql=tx as? any SQLDatabase,query.roomID==token.roomID,let room=query.roomID.uuidValue,let actor=query.actorUserID.uuidValue,let message=query.messageID.uuidValue else {throw V2MessageModerationValidationError.invalidIntent}
            try await v2RequireRoomActivation(token:token,sql:sql)
            guard let state=try await roomState(room,sql:sql),try await authorized(actor,room:room,revision:state.revision,sql:sql) != nil,
                  let value=try await messageState(message,room:room,sql:sql) else {throw V2ModerationStoreError.actorNotAuthorized}
            return try .init(roomID:query.roomID,messageID:query.messageID,messageRevision:UInt64(value.revision),membershipRevision:UInt64(state.revision),isRedacted:value.withdrawn != nil)
        }
    }
    public func admit(_ intent:V2MessageModerationIntent,token:V2RoomActivationToken) async throws -> V2MessageModerationAdmissionResult {
        try await v2WithRoomScopedTransaction(database:database) { tx in
            let sql=try await lock(intent,token:token,tx:tx)
            if let result=try await original(intent,sql:sql) {
                switch result {case .receipt(let receipt):return .terminal(receipt);case .fingerprintConflict:return .fingerprintConflict;default:throw V2MessageModerationValidationError.invalidReceipt}
            }
            if let prior=try await admission(intent,sql:sql) {return prior.validates(intent:intent) ? .admitted(prior):.fingerprintConflict}
            switch try await inspect(intent,sql:sql) {
            case .failure(let reason):return .currentUnavailable(reason)
            case .success(let state):
                let issued=try milliseconds(clock())
                guard intent.confirmedUntilMilliseconds>issued else {return .currentUnavailable(.confirmationExpired)}
                guard intent.confirmedUntilMilliseconds-issued<=120_000 else {return .currentUnavailable(.invalidConfirmationDeadline)}
                let context=try V2MessageModerationAdmission(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,
                    actorJoinedRevision:state.actorJoined,issuedAtMilliseconds:issued,expiresAtMilliseconds:intent.confirmedUntilMilliseconds)
                try await sql.raw("INSERT INTO im_v2.message_moderation_admissions(actor_user_id,operation_id,room_id,admission) VALUES (\(bind:intent.actorUserID.uuidValue!),\(bind:intent.operationID.uuidValue!),\(bind:intent.roomID.uuidValue!),\(bind:try json(context))::jsonb)").run()
                return .admitted(context)
            }
        }
    }
    public func submit(_ command:V2MessageModerationCommand,token:V2RoomActivationToken,capacityProfile:V2CapacityProfile,eventID:EventID) async throws -> V2MessageModerationRecoveryResult {
        try await v2WithRoomScopedTransaction(database:database) { tx in
            let intent=command.intent;let sql=try await lock(intent,token:token,tx:tx)
            if let prior=try await original(intent,sql:sql) {return prior}
            var now=clock();var ms=try milliseconds(now)
            guard let gate=try await admission(intent,sql:sql),gate==command.admission else {return .receipt(try await persist(intent,.rejected(.invalidAdmission),ms:ms,sql:sql))}
            guard ms<gate.expiresAtMilliseconds else {return .receipt(try await persist(intent,.rejected(.admissionExpired),ms:ms,sql:sql))}
            let outcome:V2MessageModerationTerminalOutcome
            switch try await inspect(intent,sql:sql) {
            case .failure(let reason):outcome = .rejected(reason)
            case .success(let state):
                guard state.actorJoined==gate.actorJoinedRevision else {return .receipt(try await persist(intent,.rejected(.membershipChanged(currentRevision:state.membership)),ms:ms,sql:sql))}
                now=clock();ms=try milliseconds(now)
                guard ms<gate.expiresAtMilliseconds else {return .receipt(try await persist(intent,.rejected(.admissionExpired),ms:ms,sql:sql))}
                if state.redacted {outcome = .alreadySatisfied(messageID:intent.messageID,messageRevision:intent.expectedMessageRevision)}
                else {
                    let domain=try V2ModerationCommand(roomID:intent.roomID,actorUserID:intent.actorUserID,operationID:intent.operationID,
                        action:.redactMessage,messageID:intent.messageID,expectedMessageRevision:intent.expectedMessageRevision,reasonCode:intent.reasonCode)
                    let primitive=PostgresV2ModerationStore(database:tx,activationScope:try .init(tokens:[token])).usingMessageModerationTransaction()
                    do {
                        switch try await primitive.apply(command:domain,capacityProfile:capacityProfile,eventID:eventID,now:now) {
                        case .applied(let result):
                            guard let revision=result.messageRevision else {throw V2MessageModerationValidationError.invalidReceipt}
                            ms=try milliseconds(result.createdAt)
                            outcome = .redacted(messageID:intent.messageID,messageRevision:revision,roomSequence:result.roomSequence,eventID:result.eventID)
                        case .rateLimited(let seconds):return .deferred(try .init(identity:intent.identity,fingerprint:intent.fingerprint,reason:.rateLimited,retryAfterMilliseconds:UInt64(min(86_400,max(1,seconds)))*1000))
                        case .unavailable:return .deferred(try .init(identity:intent.identity,fingerprint:intent.fingerprint,reason:.admissionUnavailable,retryAfterMilliseconds:nil))
                        default:throw V2MessageModerationValidationError.invalidReceipt
                        }
                    } catch V2ModerationStoreError.actorNotAuthorized {outcome = .rejected(.permissionDenied)}
                }
            }
            let receipt=try await persist(intent,outcome,ms:ms,sql:sql)
            guard receipt.validates(intent:intent) else {throw V2MessageModerationValidationError.invalidReceipt}
            return .receipt(receipt)
        }
    }
    public func recover(_ request:V2MessageModerationRecoveryRequest,token:V2RoomActivationToken) async throws -> V2MessageModerationRecoveryResult {
        try await v2WithRoomScopedTransaction(database:database) { tx in
            let sql=try await lock(request.intent,token:token,tx:tx)
            if let prior=try await original(request.intent,sql:sql) {return prior}
            guard request.action == .closeIfAbsent else {return .unresolved}
            return .receipt(try await persist(request.intent,.closed,ms:milliseconds(clock()),sql:sql))
        }
    }
    private enum Inspection {case success(State),failure(V2MessageModerationRejection)}
    private struct State {let actorJoined:UInt64;let membership:UInt64;let redacted:Bool}
    private func inspect(_ intent:V2MessageModerationIntent,sql:any SQLDatabase) async throws -> Inspection {
        guard let room=try await roomState(intent.roomID.uuidValue!,sql:sql) else {return .failure(.roomNotFound)}
        guard let joined=try await authorized(intent.actorUserID.uuidValue!,room:intent.roomID.uuidValue!,revision:room.revision,sql:sql) else {return .failure(.permissionDenied)}
        guard UInt64(room.revision)==intent.expectedMembershipRevision else {return .failure(.membershipChanged(currentRevision:UInt64(room.revision)))}
        guard let message=try await messageState(intent.messageID.uuidValue!,room:intent.roomID.uuidValue!,sql:sql) else {return .failure(.messageNotFound)}
        guard UInt64(message.revision)==intent.expectedMessageRevision else {return .failure(.messageChanged(currentRevision:UInt64(message.revision)))}
        return .success(.init(actorJoined:joined,membership:UInt64(room.revision),redacted:message.withdrawn != nil))
    }
    private func lock(_ intent:V2MessageModerationIntent,token:V2RoomActivationToken,tx:any Database) async throws -> any SQLDatabase {
        guard token.roomID==intent.roomID,let sql=tx as? any SQLDatabase else {throw V2MessageModerationValidationError.invalidIntent}
        let key=intent.actorUserID.uuidValue!.uuidString+":"+intent.operationID.uuidValue!.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:key),0))").run()
        try await v2RequireRoomActivation(token:token,sql:sql);return sql
    }
    private func original(_ intent:V2MessageModerationIntent,sql:any SQLDatabase) async throws -> V2MessageModerationRecoveryResult? {
        guard let row=try await sql.raw("SELECT receipt::text AS payload FROM im_v2.message_moderation_receipts WHERE actor_user_id=\(bind:intent.actorUserID.uuidValue!) AND operation_id=\(bind:intent.operationID.uuidValue!)").first(decoding:Payload.self) else {return nil}
        let value=try JSONDecoder().decode(V2MessageModerationReceipt.self,from:Data(row.payload.utf8))
        guard value.validates(intent:intent) else {return .fingerprintConflict};return .receipt(value)
    }
    private func admission(_ intent:V2MessageModerationIntent,sql:any SQLDatabase) async throws -> V2MessageModerationAdmission? {
        guard let row=try await sql.raw("SELECT admission::text AS payload FROM im_v2.message_moderation_admissions WHERE actor_user_id=\(bind:intent.actorUserID.uuidValue!) AND operation_id=\(bind:intent.operationID.uuidValue!)").first(decoding:Payload.self) else {return nil}
        return try JSONDecoder().decode(V2MessageModerationAdmission.self,from:Data(row.payload.utf8))
    }
    private func persist(_ intent:V2MessageModerationIntent,_ outcome:V2MessageModerationTerminalOutcome,ms:UInt64,sql:any SQLDatabase) async throws -> V2MessageModerationReceipt {
        let receipt=try V2MessageModerationReceipt(identity:intent.identity,fingerprint:intent.fingerprint,outcome:outcome,resolvedAtMilliseconds:ms)
        try await sql.raw("INSERT INTO im_v2.message_moderation_receipts(actor_user_id,operation_id,room_id,receipt) VALUES (\(bind:intent.actorUserID.uuidValue!),\(bind:intent.operationID.uuidValue!),\(bind:intent.roomID.uuidValue!),\(bind:try json(receipt))::jsonb)").run();return receipt
    }
    private struct Payload:Decodable {let payload:String}
}
private struct ModerationOperationRoom:Decodable {let kind:String;let revision:Int64}
private struct ModerationOperationMessage:Decodable {let revision:Int64;let withdrawn:Date?}
private struct ModerationOperationActor:Decodable {let role:String;let joined:Int64}
private func roomState(_ room:UUID,sql:any SQLDatabase) async throws -> ModerationOperationRoom? {
    let state=try await sql.raw("SELECT room_kind AS kind,membership_revision AS revision FROM im_v2.rooms WHERE room_id=\(bind:room) FOR NO KEY UPDATE").first(decoding:ModerationOperationRoom.self)
    guard state.map({$0.revision>=0}) ?? true else {throw V2ModerationStoreError.corruptPersistenceState};return state
}
private func messageState(_ message:UUID,room:UUID,sql:any SQLDatabase) async throws -> ModerationOperationMessage? {
    let value=try await sql.raw("SELECT content_revision AS revision,withdrawn_at AS withdrawn FROM im_v2.messages WHERE message_id=\(bind:message) AND room_id=\(bind:room) FOR UPDATE").first(decoding:ModerationOperationMessage.self)
    guard value.map({$0.revision>0}) ?? true else {throw V2ModerationStoreError.corruptPersistenceState};return value
}
private func authorized(_ actor:UUID,room:UUID,revision:Int64,sql:any SQLDatabase) async throws -> UInt64? {
    guard let row=try await sql.raw("SELECT role,joined_revision AS joined FROM im_v2.room_memberships WHERE room_id=\(bind:room) AND user_id=\(bind:actor) AND joined_revision<=\(bind:revision) AND (left_revision IS NULL OR left_revision>\(bind:revision)) ORDER BY joined_revision DESC LIMIT 1 FOR UPDATE").first(decoding:ModerationOperationActor.self),let role=V2RoomMembershipRole(rawValue:row.role),row.joined>=0 else {return nil}
    let configured=try await v2ResolvedGroupPermissions(roomID:room,role:role,sql:sql)
    guard V2GroupPermissionDefaults.allows(role:role,permission:.moderateMessages,configured:configured) else {return nil};return UInt64(row.joined)
}
private func milliseconds(_ date:Date) throws -> UInt64 {let value=try v2GatewayMilliseconds(date);guard value>0 else {throw V2MessageModerationValidationError.invalidReceipt};return UInt64(value)}
private func json<T:Encodable>(_ value:T) throws -> String {String(decoding:try JSONEncoder().encode(value),as:UTF8.self)}
