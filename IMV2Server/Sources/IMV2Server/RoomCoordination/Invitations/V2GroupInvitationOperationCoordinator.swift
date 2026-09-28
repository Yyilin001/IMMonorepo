import Foundation
import IMV2ActorContracts
import IMV2Core

public struct V2GroupInvitationOperationRoomPort: Sendable {
    public let baseline: @Sendable (V2GroupInvitationOperationBaselineQuery,ContinuousClock.Instant) async throws -> V2GroupInvitationOperationBaseline
    public let admit: @Sendable (V2GroupInvitationOperationIntent,ContinuousClock.Instant) async throws -> V2GroupInvitationAdmissionResult
    public let submit: @Sendable (V2GroupInvitationExecutionRequest,ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult
    public let recover: @Sendable (V2GroupInvitationRecoveryRequest,ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult
    public init(baseline:@escaping @Sendable (V2GroupInvitationOperationBaselineQuery,ContinuousClock.Instant) async throws -> V2GroupInvitationOperationBaseline,
                admit:@escaping @Sendable (V2GroupInvitationOperationIntent,ContinuousClock.Instant) async throws -> V2GroupInvitationAdmissionResult,
                submit:@escaping @Sendable (V2GroupInvitationExecutionRequest,ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult,
                recover:@escaping @Sendable (V2GroupInvitationRecoveryRequest,ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult) {
        self.baseline=baseline;self.admit=admit;self.submit=submit;self.recover=recover
    }
}

extension V2ActorInvitationCoordinator {
    public func operationBaseline(roomID:RoomID,actorUserID:UserID,deadline:ContinuousClock.Instant) async throws -> V2GroupInvitationOperationBaseline {
        try await operations.baseline(.init(roomID:roomID,actorUserID:actorUserID),deadline)
    }
    public func admitOperation(_ request:V2GroupInvitationAdmissionRequest,deadline:ContinuousClock.Instant) async throws -> V2GroupInvitationAdmissionResult {
        // Recover only the caller's exact original proof before consulting a
        // currently revoked invite or transient bearer. Historical completion
        // does not grant a new admission or restore membership authorization.
        let historical = try await recoverOperation(.init(intent: request.intent, action: .query), deadline: deadline)
        if case .receipt(let proof) = historical { return .terminal(proof) }
        if case .fingerprintConflict = historical { return .fingerprintConflict }
        // A bearer only authorizes the exact public submission target. It is never forwarded to room ownership.
        if case .submit(let invite,let digest,_) = request.intent.action {
            guard request.secretAuthorization?.validates(intent:request.intent) == true,
                  let location = try await directory.resolve(tokenDigest:digest),location.roomID == request.intent.roomID,location.inviteID == invite else { return .currentUnavailable(.inviteUnavailable) }
        }
        let result = try await operations.admit(request.intent,deadline)
        if case .terminal(let proof) = result {
            if let command = try await commands.load(actor:request.intent.identity.accountID.uuidValue!,operation:UUID(uuidString:request.intent.identity.operation.rawOperationID)!) {
                _ = try await finishControl(.receipt(proof),command:command,deadline:deadline)
            } else {
                switch proof.outcome { case .applied(.inviteCreated),.alreadySatisfied(.inviteCreated):throw V2GroupInvitationServiceError.corruptPersistenceState;default:break }
            }
        }
        return result
    }
    public func submitOperation(_ input:V2GroupInvitationSubmission,deadline:ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult {
        // Decode-time validation binds the transient bearer to the frozen command digest.
        try await executeOperation(input.command,deadline:deadline)
    }
    func executeOperation(_ command:V2GroupInvitationOperationCommand,deadline:ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult {
        let original = try await operations.recover(.init(intent:command.intent,action:.query),deadline)
        if original != .unresolved {
            let saved = try await commands.load(actor:command.identity.accountID.uuidValue!,operation:UUID(uuidString:command.identity.operation.rawOperationID)!)
            return try await finishControl(original,command:saved ?? command,deadline:deadline)
        }
        switch command.intent.action {
        case .create:
            try await commands.save(command) // Precedes the durable directory recovery work.
            let candidate = try v2GroupInvitationCreationRequest(command,issuer:secretIssuer,policy:policy,now:now())
            _ = try await directory.prepare(candidate)
            let result = try await operations.submit(.init(command:command),deadline)
            return try await finishControl(result,command:command,deadline:deadline)
        case .submit(let invite,let digest,let note):
            try await commands.save(command) // Precedes the globally reserved attempt.
            guard let location = try await directory.resolve(tokenDigest:digest),location.roomID == command.intent.roomID,location.inviteID == invite else { throw V2GroupInvitationServiceError.inviteNotFound }
            let timestamp = now()
            let seeded = V2GroupJoinSubmissionPersistenceRequest(requestID:.init(uuid:makeUUID()),applicantUserID:command.identity.accountID,
                operationID:try .init(command.identity.operation.rawOperationID),tokenDigest:digest,note:note,createdAt:timestamp,
                maximumPendingRequestsPerApplicant:policy.maximumPendingRequestsPerApplicant,maximumPendingRequestsPerInvite:policy.maximumPendingRequestsPerInvite)
            guard case .reserved(let intent) = try await quota.reserve(seeded,roomID:location.roomID,inviteID:invite,now:timestamp) else {
                return .deferred(try .init(identity:command.identity,fingerprint:command.fingerprint,reason:.rateLimited,retryAfterMilliseconds:1_000))
            }
            let result = try await operations.submit(.init(command:command,quotaIntent:.init(domain:intent)),deadline)
            if case .deferred = result {
                try await quota.resolve(intent,outcome:.rateLimited,targetRequestID:nil,now:now())
            }
            try await reconcileQuota(intent,deadline:deadline)
            return result
        default:
            let result = try await operations.submit(.init(command:command),deadline)
            return try await finishControl(result,command:command,deadline:deadline)
        }
    }
    public func recoverOperation(_ input:V2GroupInvitationRecoveryRequest,deadline:ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult {
        let result = try await operations.recover(input,deadline)
        if case .receipt(let proof) = result { try await quota.releaseVerifiedDecision(proof,intent:input.intent,now:now()) }
        if let command = try await commands.load(actor:input.intent.identity.accountID.uuidValue!,operation:UUID(uuidString:input.intent.identity.operation.rawOperationID)!) {
            return try await finishControl(result,command:command,deadline:deadline)
        }
        if case .receipt(let proof) = result {
            switch proof.outcome {
            case .applied(.inviteCreated),.alreadySatisfied(.inviteCreated):throw V2GroupInvitationServiceError.corruptPersistenceState
            default:break
            }
        }
        return result
    }
    private func finishControl(_ result:V2GroupInvitationOperationRecoveryResult,command:V2GroupInvitationOperationCommand,deadline:ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult {
        guard case .receipt(let receipt) = result else { return result }
        guard receipt.validates(intent:command.intent) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        try await quota.releaseVerifiedDecision(receipt,intent:command.intent,now:now())
        guard case .create = command.intent.action else { return result }
        let value:V2GroupInvitationOperationValue
        switch receipt.outcome { case .applied(let result),.alreadySatisfied(let result):value=result;default:try await commands.finishUncreatedDirectory(command,now:now());return result }
        guard case .inviteCreated = value else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        let candidate = try v2GroupInvitationCreationRequest(command,issuer:secretIssuer,policy:policy,now:now())
        _ = try await V2GroupInviteCreationCoordinator(directory:directory).create(candidate) { fixed in
            guard case .preflightStored(let stored) = try await room.query(.preflightCreation(.init(domain:fixed)),deadline),let stored else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            return try stored.toDomain()
        }
        return result
    }
    func reconcileQuota(_ intent:V2GroupJoinQuotaIntent,deadline:ContinuousClock.Instant) async throws {
        guard case .reservedObservation(let observation) = try await room.query(.reservedObservation(.init(domain:intent)),deadline) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        if observation == nil,
           let command = try await commands.load(actor:intent.applicantUserID,operation:intent.operationID),
           case .receipt(let proof) = try await operations.recover(.init(intent:command.intent,action:.query),deadline) {
            switch proof.outcome {
            case .closed,.rejected:
                try await quota.resolve(intent,outcome:.permissionDenied,targetRequestID:nil,now:now())
            default: throw V2GroupInvitationServiceError.corruptPersistenceState
            }
        }
        if let observation {
            let value = try observation.toDomain()
            try await quota.resolve(intent,outcome:value.outcome,targetRequestID:value.targetRequestID,now:now())
        }
    }
}
