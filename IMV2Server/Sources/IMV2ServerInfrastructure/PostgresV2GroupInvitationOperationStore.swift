import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// The room owner is the single transaction boundary for the domain fact and
/// immutable operation proof. Global quota authority comes from the account coordinator.
public struct PostgresV2GroupInvitationOperationStore: Sendable {
    private let database: any Database
    private let activation: V2RoomActivationWriteScope
    private let primitive: PostgresV2GroupInvitationStore
    private let issuer: V2GroupInviteSecretIssuer
    private let policy: V2GroupInvitationPolicy
    private let capacity: V2CapacityProfile
    init(database: any Database, activationToken: V2RoomActivationToken, identities: any V2GroupInvitationIdentityReading,
         issuer: V2GroupInviteSecretIssuer, policy: V2GroupInvitationPolicy, capacity: V2CapacityProfile, inviteID: GroupInviteID? = nil) throws {
        self.database = database; self.activation = try .init(tokens:[activationToken])
        self.primitive = try .init(database:database,identities:identities,activationToken:activationToken,inviteID:inviteID)
        self.issuer = issuer; self.policy = policy; self.capacity = capacity
    }
    public func baseline(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupInvitationOperationBaseline {
        try await v2WithPostgresTransactionRetry(database:database,maximumRetryCount:0,useRoomDeadline:true) { tx in
            let sql = try sqlDatabase(tx)
            let revision = try await primitive.usingOperationTransaction(tx).operationMembershipRevision(roomID:roomID,actorUserID:actorUserID,management:true,sql:sql)
            return try .init(roomID:roomID,membershipRevision:revision)
        }
    }
    public func admit(_ intent: V2GroupInvitationOperationIntent, now: Date = Date()) async throws -> V2GroupInvitationAdmissionResult {
        try await v2WithPostgresTransactionRetry(database:database,maximumRetryCount:0,classifyCommitFailure:true,useRoomDeadline:true) { tx in
            let sql = try sqlDatabase(tx)
            try await lock(intent,sql:sql); try await activation.require([intent.roomID.uuidValue!],sql:sql)
            if let receipt = try await receipt(intent,sql:sql) { return receipt.validates(intent:intent) ? .terminal(receipt) : .fingerprintConflict }
            if let stored = try await admission(intent,sql:sql) {
                guard stored.validates(intent:intent) else { return .fingerprintConflict }
                return try milliseconds(now) < stored.expiresAtMilliseconds ? .admitted(stored) : .currentUnavailable(.admissionExpired)
            }
            let ms = try milliseconds(now)
            let maximum = V2CommandPolicy.registered(for:intent.identity.kind).firstSubmissionWindowMilliseconds!
            guard ms < intent.confirmedUntilMilliseconds, intent.confirmedUntilMilliseconds - ms <= maximum else { return .currentUnavailable(.admissionExpired) }
            let bound = primitive.usingOperationTransaction(tx)
            do {
                let revision = try await bound.operationMembershipRevision(roomID:intent.roomID,actorUserID:intent.identity.accountID,management:intent.action.observedMembershipRevision != nil,sql:sql)
                if let expected = intent.action.observedMembershipRevision, expected != revision { return .currentUnavailable(.membershipChanged(currentRevision:revision)) }
                if let rejection = try await validateTarget(intent,now:now,sql:sql) { return .currentUnavailable(rejection) }
                let value = try V2GroupInvitationAdmission(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,membershipRevision:revision,issuedAtMilliseconds:ms,expiresAtMilliseconds:min(intent.confirmedUntilMilliseconds,ms + 120_000))
                try await sql.raw("INSERT INTO im_v2.group_invitation_admissions(actor_user_id,operation_id,room_id,kind,admission) VALUES (\(bind: intent.identity.accountID.uuidValue!),\(bind: operationID(intent)),\(bind: intent.roomID.uuidValue!),\(bind: intent.identity.kind.rawValue),\(bind: try json(value))::jsonb)").run()
                return .admitted(value)
            } catch let error as V2GroupInvitationServiceError {
                guard let reason = rejection(error) else { throw error }; return .currentUnavailable(reason)
            }
        }
    }
    public func submit(_ execution: V2GroupInvitationExecutionRequest, now: Date = Date()) async throws -> V2GroupInvitationOperationRecoveryResult {
        try await v2WithPostgresTransactionRetry(database:database,maximumRetryCount:0,classifyCommitFailure:true,useRoomDeadline:true) { tx in
            let sql = try sqlDatabase(tx); let command = execution.command; let intent = command.intent
            try await lock(intent,sql:sql); try await activation.require([intent.roomID.uuidValue!],sql:sql)
            if let prior = try await receipt(intent,sql:sql) { return prior.validates(intent:intent) ? .receipt(prior) : .fingerprintConflict }
            guard let context = try await admission(intent,sql:sql), context == command.admission else { return try await save(intent,.rejected(.invalidAdmission),now:now,sql:sql) }
            guard try milliseconds(now) < context.expiresAtMilliseconds else { return try await save(intent,.rejected(.admissionExpired),now:now,sql:sql) }
            let bound = primitive.usingOperationTransaction(tx)
            do {
                let revision = try await bound.operationMembershipRevision(roomID:intent.roomID,actorUserID:intent.identity.accountID,management:intent.action.observedMembershipRevision != nil,sql:sql)
                if let expected = intent.action.observedMembershipRevision, expected != revision { return try await save(intent,.rejected(.membershipChanged(currentRevision:revision)),now:now,sql:sql) }
                let value: V2GroupInvitationOperationValue
                var satisfied = false
                switch intent.action {
                case .create(let lifetime,let uses,_):
                    let request = try creationRequest(command,now:now)
                    let stored = try await bound.create(request)
                    // Compare the immutable database binding, not a subtraction
                    // of decoded floating-point Dates. Encoding either endpoint
                    // can truncate a microsecond when crossing the PG epoch.
                    guard let expectedTimestamps = request.persistedTimestamps,
                          stored.persistedTimestamps == expectedTimestamps else {
                        throw V2GroupInvitationServiceError.corruptPersistenceState
                    }
                    // The exact persisted binding was checked above. Publish
                    // the original integer times instead of re-encoding Date.
                    value = .inviteCreated(inviteID:stored.inviteID,
                        createdAtMilliseconds:command.admission.issuedAtMilliseconds,
                        expiresAtMilliseconds:command.admission.issuedAtMilliseconds + lifetime * 1_000,
                        maximumApprovedUses:uses)
                case .revoke(let invite,_):
                    try await bound.revoke(inviteID:invite,roomID:intent.roomID,actorUserID:intent.identity.accountID,operationID:.init(intent.identity.operation.rawOperationID),now:now)
                    value = .inviteRevoked(inviteID:invite)
                case .submit(let invite,let digest,let note):
                    guard let wire = execution.quotaIntent else { throw V2GroupInvitationServiceError.conflict }
                    let quota = try wire.toDomain()
                    guard quota.applicantUserID == intent.identity.accountID.uuidValue!, quota.roomID == intent.roomID.uuidValue!, quota.inviteID == invite.uuidValue!, quota.tokenDigest == digest else { throw V2GroupInvitationServiceError.conflict }
                    // An existing canonical reservation can represent an already-pending
                    // request; a fresh operation must not silently edit that request's note.
                    if quota.operationID == operationID(intent) && quota.note != note { throw V2GroupInvitationServiceError.conflict }
                    let outcome = try await bound.applyReservedSubmission(quota,now:now)
                    switch outcome.outcome {
                    case .pending,.approved,.rejected,.cancelled:
                        guard let request = outcome.targetRequestID else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                        if outcome.outcome == .rejected || outcome.outcome == .cancelled { return try await save(intent,.rejected(.requestAlreadyDecided),now:now,sql:sql) }
                        satisfied = quota.operationID != operationID(intent) || outcome.outcome == .approved
                        value = .requestSubmitted(requestID:.init(uuid:request),inviteID:invite)
                    case .alreadyMember: return try await save(intent,.rejected(.alreadyMember),now:now,sql:sql)
                    case .unavailable: return try await save(intent,.rejected(.inviteUnavailable),now:now,sql:sql)
                    case .permissionDenied: return try await save(intent,.rejected(.permissionDenied),now:now,sql:sql)
                    case .rateLimited: return .deferred(try hint(intent,reason:.rateLimited,milliseconds:1_000))
                    }
                case .cancel(let request):
                    let record = try await bound.cancel(roomID:intent.roomID,requestID:request,applicantUserID:intent.identity.accountID,now:now)
                    guard record.state == .cancelled else { return try await save(intent,.rejected(.requestAlreadyDecided),now:now,sql:sql) }
                    value = .requestCancelled(requestID:request)
                case .decide(let request,let decision,let expected):
                    let operation = try GroupJoinDecisionOperationID(intent.identity.operation.rawOperationID)
                    if decision == .reject {
                        switch try await bound.reject(roomID:intent.roomID,requestID:request,reviewerUserID:intent.identity.accountID,operationID:operation,now:now) {
                        case .rejected: value = .requestDecided(requestID:request,decision:decision,membershipRevision:nil)
                        default: return try await save(intent,.rejected(.requestAlreadyDecided),now:now,sql:sql)
                        }
                    } else {
                        switch try await bound.approve(roomID:intent.roomID,requestID:request,reviewerUserID:intent.identity.accountID,operationID:operation,capacityProfile:capacity,eventID:.init(uuid:UUID()),now:now) {
                        case .approved: value = .requestDecided(requestID:request,decision:decision,membershipRevision:expected + 1)
                        case .rateLimited(let seconds): return .deferred(try hint(intent,reason:.rateLimited,milliseconds:UInt64(max(1,seconds))*1_000))
                        case .memberLimitReached: return try await save(intent,.rejected(.memberLimitReached),now:now,sql:sql)
                        case .unavailable: return .deferred(try hint(intent,reason:.admissionUnavailable,milliseconds:nil))
                        default: return try await save(intent,.rejected(.requestAlreadyDecided),now:now,sql:sql)
                        }
                    }
                }
                return try await save(intent,satisfied ? .alreadySatisfied(value) : .applied(value),now:now,sql:sql)
            } catch let error as V2GroupInvitationServiceError {
                if error == .rateLimited { return .deferred(try hint(intent,reason:.rateLimited,milliseconds:1_000)) }
                guard let reason = rejection(error) else { throw error }
                return try await save(intent,.rejected(reason),now:now,sql:sql)
            }
        }
    }
    public func recover(_ request: V2GroupInvitationRecoveryRequest, now: Date = Date()) async throws -> V2GroupInvitationOperationRecoveryResult {
        try await v2WithPostgresTransactionRetry(database:database,maximumRetryCount:0,classifyCommitFailure:true,useRoomDeadline:true) { tx in
            let sql = try sqlDatabase(tx); let intent = request.intent
            try await lock(intent,sql:sql); try await activation.require([intent.roomID.uuidValue!],sql:sql)
            if let value = try await receipt(intent,sql:sql) { return value.validates(intent:intent) ? .receipt(value) : .fingerprintConflict }
            if let context = try await admission(intent,sql:sql), !context.validates(intent:intent) { return .fingerprintConflict }
            return request.action == .closeIfAbsent ? try await save(intent,.closed,now:now,sql:sql) : .unresolved
        }
    }
    func creationRequest(_ command: V2GroupInvitationOperationCommand, now: Date) throws -> V2GroupInviteCreatePersistenceRequest {
        try v2GroupInvitationCreationRequest(command,issuer:issuer,policy:policy,now:now)
    }
    private func validateTarget(_ intent: V2GroupInvitationOperationIntent, now: Date, sql: any SQLDatabase) async throws -> V2GroupInvitationOperationRejection? {
        switch intent.action {
        case .submit(let invite,let digest,_):
            guard let row = try await sql.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.group_invite_links WHERE invite_id = \(bind: invite.uuidValue!) AND room_id = \(bind: intent.roomID.uuidValue!) AND token_digest = \(bind: digest) AND state = 'active' AND expires_at > \(bind: now) AND approved_use_count < maximum_approved_uses").first(decoding: Count.self),row.value == 1 else { return .inviteUnavailable }
        case .cancel(let request):
            guard try await sql.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.group_join_requests WHERE request_id = \(bind: request.uuidValue!) AND room_id = \(bind: intent.roomID.uuidValue!) AND applicant_user_id = \(bind: intent.identity.accountID.uuidValue!) AND state = 'pending'").first(decoding:Count.self)?.value == 1 else { return .requestNotFound }
        case .decide(let request,_,_):
            guard try await sql.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.group_join_requests WHERE request_id = \(bind: request.uuidValue!) AND room_id = \(bind: intent.roomID.uuidValue!) AND state = 'pending'").first(decoding:Count.self)?.value == 1 else { return .requestAlreadyDecided }
        case .revoke(let invite,_):
            guard try await sql.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.group_invite_links WHERE invite_id = \(bind: invite.uuidValue!) AND room_id = \(bind: intent.roomID.uuidValue!)").first(decoding:Count.self)?.value == 1 else { return .inviteUnavailable }
        case .create: break
        }
        return nil
    }
    private struct TextRow: Decodable { let value: String }
    private struct Count: Decodable { let value: Int64 }
    private func operationID(_ intent: V2GroupInvitationOperationIntent) -> UUID { UUID(uuidString:intent.identity.operation.rawOperationID)! }
    private func lock(_ intent: V2GroupInvitationOperationIntent,sql:any SQLDatabase) async throws { try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: intent.identity.accountID.uuidValue!.uuidString + ":" + operationID(intent).uuidString),0))").run() }
    private func sqlDatabase(_ db:any Database) throws -> any SQLDatabase { guard let sql = db as? any SQLDatabase else { throw V2GroupInvitationServiceError.corruptPersistenceState }; return sql }
    private func milliseconds(_ date:Date) throws -> UInt64 { guard v2PostgresTimestampCanEncode(date) else { throw V2GroupInvitationServiceError.corruptPersistenceState }; guard let value=UInt64(exactly:try v2GatewayMilliseconds(date)) else { throw V2GroupInvitationServiceError.corruptPersistenceState }; return value }
    private func json<T:Encodable>(_ value:T) throws -> String { String(decoding:try JSONEncoder().encode(value),as:UTF8.self) }
    private func admission(_ intent:V2GroupInvitationOperationIntent,sql:any SQLDatabase) async throws -> V2GroupInvitationAdmission? {
        guard let row = try await sql.raw("SELECT admission::text AS value FROM im_v2.group_invitation_admissions WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationID(intent))").first(decoding:TextRow.self) else { return nil }
        return try JSONDecoder().decode(V2GroupInvitationAdmission.self,from:Data(row.value.utf8))
    }
    private func receipt(_ intent:V2GroupInvitationOperationIntent,sql:any SQLDatabase) async throws -> V2GroupInvitationOperationReceipt? {
        guard let row = try await sql.raw("SELECT receipt::text AS value FROM im_v2.group_invitation_receipts WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationID(intent))").first(decoding:TextRow.self) else { return nil }
        return try JSONDecoder().decode(V2GroupInvitationOperationReceipt.self,from:Data(row.value.utf8))
    }
    private func save(_ intent:V2GroupInvitationOperationIntent,_ outcome:V2GroupInvitationOperationTerminalOutcome,now:Date,sql:any SQLDatabase) async throws -> V2GroupInvitationOperationRecoveryResult {
        let value = try V2GroupInvitationOperationReceipt(intent:intent,outcome:outcome,resolvedAtMilliseconds:milliseconds(now))
        try await sql.raw("INSERT INTO im_v2.group_invitation_receipts(actor_user_id,operation_id,room_id,kind,receipt) VALUES (\(bind: intent.identity.accountID.uuidValue!),\(bind: operationID(intent)),\(bind: intent.roomID.uuidValue!),\(bind: intent.identity.kind.rawValue),\(bind: try json(value))::jsonb)").run()
        return .receipt(value)
    }
    private func rejection(_ error:V2GroupInvitationServiceError)->V2GroupInvitationOperationRejection? {
        switch error { case .permissionDenied:.permissionDenied;case .roomNotFound:.roomNotFound;case .requestNotFound:.requestNotFound;case .inviteNotFound,.creationExpired:.inviteUnavailable;case .conflict:.requestAlreadyDecided;default:nil }
    }
    private func hint(_ intent:V2GroupInvitationOperationIntent,reason:V2MessageOperationRetryHint.Reason,milliseconds:UInt64?) throws -> V2MessageOperationRetryHint { try .init(identity:intent.identity,fingerprint:intent.fingerprint,reason:reason,retryAfterMilliseconds:milliseconds) }
}
