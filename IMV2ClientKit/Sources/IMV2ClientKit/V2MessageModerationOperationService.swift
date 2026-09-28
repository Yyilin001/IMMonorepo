import Foundation
import GRDB
import IMV2Core

/// SDK entry point for confirmed moderation. It never refreshes a user's observed revisions.
public actor V2MessageModerationOperationService {
    private let accountID:UserID
    private let activationID:UUID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2MessageModerationOperationClient
    private var deadlines:[UUID:ContinuousClock.Instant]=[:]
    public init(accountID:UserID,activationID:UUID,store:GRDBV2LocalSyncStore,client:any V2MessageModerationOperationClient) {
        self.accountID=accountID;self.activationID=activationID;self.store=store;self.client=client
    }
    public func baseline(roomID:RoomID,messageID:MessageID) async throws -> V2MessageModerationBaseline {
        let client=self.client
        let value = try await V2HTTPRequestDeadline.run(until:.now.advanced(by:.seconds(15)),service:"accountAPI") { try await client.baseline(roomID:roomID,messageID:messageID) }
        guard value.roomID==roomID,value.messageID==messageID else { throw V2MessageModerationValidationError.invalidIntent }
        return value
    }
    /// Call only on explicit user confirmation of this exact baseline and reason.
    public func enqueue(baseline:V2MessageModerationBaseline,reason:V2ModerationReasonCode, confirmedUntil:Date? = nil) async throws -> UUID {
        try Task.checkCancellation()
        let now=Date()
        let end=confirmedUntil ?? now.addingTimeInterval(120)
        guard end>now,end.timeIntervalSince(now)<=120 else { throw V2MessageModerationValidationError.invalidIntent }
        let monotonic=ContinuousClock.now.advanced(by:.seconds(end.timeIntervalSince(now)))
        let value=(now.timeIntervalSince1970*1000).rounded(.towardZero)
        guard value.isFinite,value>0,value<Double(Int64.max)-120_000,UInt64(exactly:value) != nil else { throw V2MessageModerationValidationError.invalidIntent }
        let intent=try V2MessageModerationIntent(roomID:baseline.roomID,actorUserID:accountID,operationID:.init(UUID().uuidString),messageID:baseline.messageID,reasonCode:reason,expectedMessageRevision:baseline.messageRevision,expectedMembershipRevision:baseline.membershipRevision,confirmedUntilMilliseconds:UInt64((end.timeIntervalSince1970*1000).rounded(.towardZero)))
        let id=try await store.enqueueMessageModeration(intent,activationID:activationID,now:now)
        deadlines[id]=monotonic
        return id
    }
    public func updates() -> AsyncThrowingStream<[V2MessageModerationPending],any Error> { store.messageModerationUpdates() }
    public func resume(id:UUID) async throws {
        try Task.checkCancellation()
        let pending=try await store.messageModerationPending(id:id)
        guard pending.intent.actorUserID==accountID else { throw V2OperationWorkError.accountMismatch }
        try await store.retryOperationWorkByUser(id:id,now:Date())
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.kind == .moderation,claim.work.identity.accountID==accountID else { throw V2OperationWorkError.accountMismatch }
        let pending=try await store.messageModerationPending(id:claim.work.id)
        let intent=pending.intent
        guard pending.work.identity==claim.work.identity,pending.work.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        let remaining=max(0,Double(intent.confirmedUntilMilliseconds)/1000-Date().timeIntervalSince1970)
        let wallDeadline=ContinuousClock.now.advanced(by:.seconds(min(remaining,120)))
        // Wall-clock expiry also closes the local window; a later clock rollback
        // cannot reopen the monotonic deadline retained for this confirmation.
        let deadline=min(deadlines[claim.work.id] ?? wallDeadline,wallDeadline)
        deadlines[claim.work.id]=deadline
        // A restarted, not-yet-admitted confirmation cannot obtain new authority.
        let mayAdmit=pending.activationID==activationID && deadline > .now
        do {
            try Task.checkCancellation()
            let result:V2MessageModerationRecoveryResult
            if deadline <= .now || (pending.admission==nil && !mayAdmit) {
                result=try await client.recover(intent,action:.closeIfAbsent)
            } else if claim.action == .reconcile {
                result=try await client.recover(intent,action:.query)
            } else if let admission=pending.admission {
                if Double(admission.expiresAtMilliseconds)/1000<=Date().timeIntervalSince1970 {
                    result=try await client.recover(intent,action:.closeIfAbsent)
                } else {
                    let client=self.client,command=try V2MessageModerationCommand(intent:intent,admission:admission)
                    result=try await V2HTTPRequestDeadline.run(until:min(deadline,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await client.submit(command) }
                }
            } else {
                let client=self.client
                let admitted=try await V2HTTPRequestDeadline.run(until:min(deadline,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await client.admit(intent) }
                try Task.checkCancellation()
                switch admitted {
                case .admitted(let admission):
                    try await store.saveMessageModerationAdmission(admission,claim:claim)
                    try await store.deferOperationWork(claim,until:Date(),code:"MODERATION_ADMITTED",nextAction:.submit)
                    return
                case .terminal(let receipt):result = .receipt(receipt)
                case .currentUnavailable:
                    try await store.deferOperationWork(claim,until:Date(),code:"MODERATION_CONFIRMATION_UNAVAILABLE",scheduling:.needsAttention)
                    return
                case .fingerprintConflict:result = .fingerprintConflict
                }
            }
            try Task.checkCancellation()
            switch result {
            case .receipt(let receipt):
                try await store.completeMessageModeration(receipt,id:claim.work.id)
                deadlines.removeValue(forKey:claim.work.id)
            case .fingerprintConflict:
                try await store.deferOperationWork(claim,until:Date(),code:"MODERATION_IDENTITY_CONFLICT",scheduling:.needsAttention)
            case .unresolved:
                try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"MODERATION_UNRESOLVED",nextAction:deadline > .now && (pending.admission != nil || mayAdmit) ? .submit:.reconcile)
            case .deferred(let hint):
                guard hint.validates(identity:claim.work.identity,fingerprint:claim.work.fingerprint) else { throw V2OperationWorkError.identityConflict }
                try await deferFailure(claim,floor:Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1000),malformed:false)
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"MODERATION_INTERRUPTED")
            throw CancellationError()
        } catch {
            try await deferFailure(claim,floor:(error as? V2HTTPFailure)?.retryAfter,malformed:error is V2OperationWorkError || error is V2MessageModerationValidationError || error is DecodingError || error is DatabaseError)
            if error is DatabaseError { throw error }
        }
    }
    private func deferFailure(_ claim:V2OperationWorkClaim,floor:Date?,malformed:Bool) async throws {
        let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,end=claim.work.reconciliationRoundDeadline ?? Date().addingTimeInterval(V2NetworkWorkPolicy.commandRecovery.totalBudget)
        let retry=policy.nextAttempt(now:now,startedAt:end.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
        try await store.deferOperationWork(claim,until:max(retry ?? now,floor ?? now),code:"MODERATION_CONFIRMATION_REQUIRED",scheduling:malformed || retry==nil ? .needsAttention:.backingOff)
    }
}
