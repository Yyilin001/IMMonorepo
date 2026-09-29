import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Account preference effects, their durable propagation intents, and original proof commit together.
public struct PostgresV2AccountPreferenceOperationStore:Sendable {
    private let database:any Database
    private let delivery:any V2UserShardProjectionDelivering
    private let authorization:V2DirectAuthorizationCoordinator
    public init(database:any Database,projectionDelivery:any V2UserShardProjectionDelivering,authorizationCoordinator:V2DirectAuthorizationCoordinator) { self.database=database;self.delivery=projectionDelivery;self.authorization=authorizationCoordinator }
    public func snapshot(ownerUserID:UserID,kind:V2OperationKind) async throws -> V2AccountPreferenceSnapshot {
        try await v2WithPostgresTransactionRetry(database:database) { transaction in
            guard let sql=transaction as? any SQLDatabase,let owner=ownerUserID.uuidValue else { throw V2AccountPreferenceValidationError.invalidSnapshot }
            try await stateLock(owner,kind:kind,sql:sql)
            guard try await active(owner,sql:sql) else { throw V2SocialRelationshipStoreError.actorInactive }
            return try await .init(ownerUserID:ownerUserID,value:readValue(owner,kind:kind,sql:sql),revision:revision(owner,kind:kind,sql:sql))
        }
    }
    public func submit(_ command:V2AccountPreferenceCommand,now:Date) async throws -> V2AccountPreferenceRecoveryResult {
        let started=ContinuousClock.now
        let result:V2AccountPreferenceRecoveryResult=try await v2WithPostgresTransactionRetry(database:database) { transaction in
            guard let sql=transaction as? any SQLDatabase else { throw V2AccountPreferenceValidationError.invalidCommand }
            try await operationLock(command.identity,sql:sql)
            if let prior=try await original(command.identity,fingerprint:command.fingerprint,sql:sql) { return prior }
            let owner=command.identity.accountID.uuidValue!
            try await stateLock(owner,kind:command.identity.kind,sql:sql)
            let duration=started.duration(to:.now).components
            let sampled=now.addingTimeInterval(Double(duration.seconds)+Double(duration.attoseconds)/1e18)
            guard v2PostgresTimestampCanEncode(sampled),let row=try await sql.raw("SELECT \(bind:sampled)::timestamptz AS value").first(decoding:PreferenceDateRow.self) else { throw V2AccountPreferenceValidationError.invalidReceipt }
            let clock=row.value,ms=try v2GatewayMilliseconds(clock)
            guard ms>0 else { throw V2AccountPreferenceValidationError.invalidReceipt }
            let outcome:V2AccountPreferenceTerminalOutcome
            if command.firstSubmissionDeadlineMilliseconds<=UInt64(ms) { outcome = .rejected(.firstSubmissionExpired) }
            else if command.firstSubmissionDeadlineMilliseconds-UInt64(ms)>120_000 { outcome = .rejected(.invalidDeadline) }
            else if !(try await active(owner,sql:sql)) { outcome = .rejected(.permissionDenied) }
            else {
                let observed=try await revision(owner,kind:command.identity.kind,sql:sql)
                if observed != command.expectedRevision { outcome = .rejected(.revisionConflict(currentRevision:observed)) }
                else {
                    let operation=UUID(uuidString:command.identity.operation.rawOperationID)!
                    switch command.value {
                    case .strangerMessage(let permission):
                        let store=PostgresV2DirectMessagingStore(database:transaction,identityReader:PostgresV2DirectRoomIdentityReader(database:database),projectionDelivery:delivery,authorizationCoordinator:authorization)
                        guard case .updated=try await store.applyStrangerMessagePermission(command:.init(actorUserID:command.identity.accountID,operationID:.init(uuid:operation),permission:permission),transaction:transaction,now:clock) else { throw V2AccountPreferenceValidationError.invalidReceipt }
                        try await advance(owner,kind:command.identity.kind,sql:sql)
                    case .userAdd(let permission):
                        let store=PostgresV2DirectMessagingStore(database:transaction,identityReader:PostgresV2DirectRoomIdentityReader(database:database),projectionDelivery:delivery,authorizationCoordinator:authorization)
                        guard case .updated=try await store.applyUserAddPermission(command:.init(actorUserID:command.identity.accountID,operationID:.init(uuid:operation),permission:permission),transaction:transaction,now:clock) else { throw V2AccountPreferenceValidationError.invalidReceipt }
                        try await advance(owner,kind:command.identity.kind,sql:sql)
                    case .readReceipt(let direct,let group):
                        _ = try await PostgresV2ReadReceiptStore(database:transaction,projectionDelivery:delivery).applyAccountReadReceiptPreferences(command:.init(actorUserID:command.identity.accountID,operationID:.init(uuid:operation),allowsDirectReadReceipts:direct,allowsGroupReadReceipts:group),transaction:transaction,now:clock)
                    case .liveActivity(let online,let typing):
                        _ = try await PostgresV2LiveActivityStore(database:transaction).applyAccountLiveActivityPreferences(command:.init(actorUserID:command.identity.accountID,operationID:.init(uuid:operation),allowsOnlinePresence:online,allowsTypingIndicators:typing),transaction:transaction,now:clock)
                        try await advance(owner,kind:command.identity.kind,sql:sql)
                        guard let sequence=try await sql.raw("INSERT INTO im_v2.user_sync_sequences(user_id,next_sequence) VALUES(\(bind:owner),1) ON CONFLICT(user_id) DO UPDATE SET next_sequence=im_v2.user_sync_sequences.next_sequence+1 WHERE im_v2.user_sync_sequences.next_sequence<\(bind:Int64.max) RETURNING next_sequence AS value").first(decoding:PreferenceIntegerRow.self) else { throw V2AccountPreferenceValidationError.invalidReceipt }
                        try await sql.raw("INSERT INTO im_v2.user_sync_log(user_id,user_sync_sequence,source_event_id,projection_kind,payload,created_at) VALUES(\(bind:owner),\(bind:sequence.value),\(bind:operation),'live_activity_preferences',jsonb_build_object('allows_online_presence',\(bind:online),'allows_typing_indicators',\(bind:typing),'revision',\(bind:Int64(observed+1)),'updated_at_ms',\(bind:ms)),\(bind:clock))").run()
                    }
                    if command.identity.kind == .strangerMessagePreference || command.identity.kind == .userAddPreference {
                        let projection = command.identity.kind == .strangerMessagePreference ? "stranger_message_permission" : "user_add_permission"
                        try await sql.raw("UPDATE im_v2.user_sync_log SET payload=payload || jsonb_build_object('revision',\(bind:Int64(observed+1))) WHERE user_id=\(bind:owner) AND source_event_id=\(bind:operation) AND projection_kind=\(bind:projection)").run()
                    }
                    guard try await revision(owner,kind:command.identity.kind,sql:sql)==observed+1 else { throw V2AccountPreferenceValidationError.invalidReceipt }
                    outcome = .applied(value:command.value,revision:observed+1)
                }
            }
            let receipt=try await persist(command.identity,command.fingerprint,outcome,at:UInt64(ms),sql:sql)
            guard receipt.validates(command:command) else { throw V2AccountPreferenceValidationError.invalidReceipt }
            return .receipt(receipt)
        }
        try await deliver(result,identity:command.identity)
        return result
    }
    public func recover(_ request:V2AccountPreferenceRecoveryRequest,now:Date) async throws -> V2AccountPreferenceRecoveryResult {
        let result:V2AccountPreferenceRecoveryResult=try await v2WithPostgresTransactionRetry(database:database) { transaction in
            guard let sql=transaction as? any SQLDatabase else { throw V2AccountPreferenceValidationError.invalidCommand }
            try await operationLock(request.identity,sql:sql)
            if let prior=try await original(request.identity,fingerprint:request.fingerprint,sql:sql) { return prior }
            guard request.action == .closeIfAbsent else { return .unresolved }
            let ms=try v2GatewayMilliseconds(now)
            guard ms>0 else { throw V2AccountPreferenceValidationError.invalidReceipt }
            return .receipt(try await persist(request.identity,request.fingerprint,.closed,at:UInt64(ms),sql:sql))
        }
        try await deliver(result,identity:request.identity)
        return result
    }
    private func deliver(_ result:V2AccountPreferenceRecoveryResult,identity:V2OperationIdentity) async throws {
        guard case .receipt(let receipt)=result,case .applied=receipt.outcome else { return }
        let kind:String=switch identity.kind { case .strangerMessagePreference:"stranger_message_permission";case .userAddPreference:"user_add_permission";case .readReceiptPreference:"read_receipt_preferences";case .liveActivityPreference:"live_activity_preferences";default:throw V2AccountPreferenceValidationError.invalidReceipt }
        _ = try await delivery.deliverToCurrentShard(userID:identity.accountID,sourceEventID:.init(identity.operation.rawOperationID),projectionKinds:[kind])
    }
    private func stateLock(_ owner:UUID,kind:V2OperationKind,sql:any SQLDatabase) async throws {
        let key:String=switch kind {
        case .strangerMessagePreference:"v2-stranger-message-preference:"+owner.uuidString.lowercased()
        case .userAddPreference:"v2-user-add-preference:"+owner.uuidString.lowercased()
        case .readReceiptPreference:"v2-read-receipt-preference:"+owner.uuidString
        case .liveActivityPreference:"v2-live-activity-preference:"+owner.uuidString
        default:throw V2AccountPreferenceValidationError.invalidCommand
        }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:key),0))").run()
    }
    private func operationLock(_ identity:V2OperationIdentity,sql:any SQLDatabase) async throws {
        guard identity.accountID.uuidValue != nil,UUID(uuidString:identity.operation.rawOperationID) != nil else { throw V2AccountPreferenceValidationError.invalidCommand }
        let key="v2-account-preference:"+identity.kind.rawValue+":"+identity.accountID.rawValue+":"+identity.operation.rawOperationID
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:key),0))").run()
    }
    private func active(_ owner:UUID,sql:any SQLDatabase) async throws -> Bool { try await sql.raw("SELECT EXISTS(SELECT 1 FROM im_v2.public_user_profiles AS profile WHERE profile.user_id=\(bind:owner) AND profile.state='active' AND NOT EXISTS(SELECT 1 FROM im_v2.account_disables AS disabled WHERE disabled.user_id=profile.user_id)) AS value").first(decoding:PreferenceBooleanRow.self)?.value ?? false }
    private func revision(_ owner:UUID,kind:V2OperationKind,sql:any SQLDatabase) async throws -> UInt64 {
        let value:Int64
        if kind == .readReceiptPreference { value=try await sql.raw("SELECT preference_revision AS value FROM im_v2.user_read_receipt_preferences WHERE user_id=\(bind:owner)").first(decoding:PreferenceIntegerRow.self)?.value ?? 0 }
        else { value=try await sql.raw("SELECT revision AS value FROM im_v2.account_preference_revisions WHERE user_id=\(bind:owner) AND kind=\(bind:kind.rawValue)").first(decoding:PreferenceIntegerRow.self)?.value ?? 0 }
        guard value>=0 else { throw V2AccountPreferenceValidationError.invalidSnapshot };return UInt64(value)
    }
    private func readValue(_ owner:UUID,kind:V2OperationKind,sql:any SQLDatabase) async throws -> V2AccountPreferenceValue {
        switch kind {
        case .strangerMessagePreference:return .strangerMessage((try await sql.raw("SELECT allows_stranger_messages AS value FROM im_v2.user_stranger_message_preferences WHERE user_id=\(bind:owner)").first(decoding:PreferenceBooleanRow.self)?.value ?? true) ? .allow:.deny)
        case .userAddPreference:return .userAdd((try await sql.raw("SELECT allows_being_added AS value FROM im_v2.user_add_preferences WHERE user_id=\(bind:owner)").first(decoding:PreferenceBooleanRow.self)?.value ?? true) ? .allow:.deny)
        case .readReceiptPreference:
            let row=try await sql.raw("SELECT allows_direct_read_receipts AS first,allows_group_read_receipts AS second FROM im_v2.user_read_receipt_preferences WHERE user_id=\(bind:owner)").first(decoding:PreferencePairRow.self)
            return .readReceipt(allowsDirectReadReceipts:row?.first ?? true,allowsGroupReadReceipts:row?.second ?? true)
        case .liveActivityPreference:
            let row=try await sql.raw("SELECT allows_online_presence AS first,allows_typing_indicators AS second FROM im_v2.user_live_activity_preferences WHERE user_id=\(bind:owner)").first(decoding:PreferencePairRow.self)
            return .liveActivity(allowsOnlinePresence:row?.first ?? true,allowsTypingIndicators:row?.second ?? true)
        default:throw V2AccountPreferenceValidationError.invalidSnapshot
        }
    }
    private func advance(_ owner:UUID,kind:V2OperationKind,sql:any SQLDatabase) async throws { try await sql.raw("INSERT INTO im_v2.account_preference_revisions(user_id,kind,revision) VALUES(\(bind:owner),\(bind:kind.rawValue),1) ON CONFLICT(user_id,kind) DO UPDATE SET revision=im_v2.account_preference_revisions.revision+1").run() }
    private func original(_ identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,sql:any SQLDatabase) async throws -> V2AccountPreferenceRecoveryResult? {
        guard let row=try await sql.raw("SELECT receipt::text AS payload FROM im_v2.account_preference_receipts WHERE actor_user_id=\(bind:identity.accountID.uuidValue!) AND operation_id=\(bind:UUID(uuidString:identity.operation.rawOperationID)!) AND kind=\(bind:identity.kind.rawValue)").first(decoding:PreferenceReceiptRow.self) else { return nil }
        let receipt=try JSONDecoder().decode(V2AccountPreferenceReceipt.self,from:Data(row.payload.utf8))
        guard receipt.identity==identity,receipt.fingerprint==fingerprint else { return .fingerprintConflict };return .receipt(receipt)
    }
    private func persist(_ identity:V2OperationIdentity,_ fingerprint:V2OperationFingerprint,_ outcome:V2AccountPreferenceTerminalOutcome,at:UInt64,sql:any SQLDatabase) async throws -> V2AccountPreferenceReceipt {
        let receipt=try V2AccountPreferenceReceipt(identity:identity,fingerprint:fingerprint,outcome:outcome,resolvedAtMilliseconds:at)
        let json=String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
        try await sql.raw("INSERT INTO im_v2.account_preference_receipts(actor_user_id,operation_id,kind,receipt) VALUES(\(bind:identity.accountID.uuidValue!),\(bind:UUID(uuidString:identity.operation.rawOperationID)!),\(bind:identity.kind.rawValue),\(bind:json)::jsonb)").run();return receipt
    }
}
private struct PreferenceDateRow:Decodable { let value:Date }
private struct PreferenceIntegerRow:Decodable { let value:Int64 }
private struct PreferenceBooleanRow:Decodable { let value:Bool }
private struct PreferencePairRow:Decodable { let first:Bool;let second:Bool }
private struct PreferenceReceiptRow:Decodable { let payload:String }
