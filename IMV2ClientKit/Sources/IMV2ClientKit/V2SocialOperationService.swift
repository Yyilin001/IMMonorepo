import Foundation
import GRDB
import IMV2Core

public actor V2SocialOperationService {
    private let accountID:UserID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2SocialOperationClient
    private var deadlines:[UUID:ContinuousClock.Instant]=[:]
    public init(accountID:UserID,store:GRDBV2LocalSyncStore,client:any V2SocialOperationClient) { self.accountID=accountID;self.store=store;self.client=client }
    public func updates() -> AsyncThrowingStream<[V2SocialOperationPending],any Error> { store.socialOperationUpdates() }
    public func proposalUpdates() -> AsyncThrowingStream<[V2SocialOperationProposal],any Error> { store.socialProposalUpdates() }
    public func saveProposal(action:V2SocialOperationAction,target:UserID) async throws -> UUID {
        try Task.checkCancellation();return try await store.enqueueSocialProposal(accountID:accountID,target:target,action:action)
    }
    public func discardProposal(id:UUID) async throws { try await store.discardSocialProposal(id:id,accountID:accountID) }
    public func confirmProposal(id:UUID,snapshot:V2SocialOperationSnapshot) async throws {
        let proposal=try await store.socialProposal(id:id,accountID:accountID)
        guard snapshot.actorUserID==accountID,snapshot.targetUserID==proposal.targetUserID else { throw V2SocialOperationValidationError.invalidSnapshot }
        _ = try await enqueue(action:proposal.action,snapshot:snapshot,proposalID:id)
    }
    public func baseline(targetUserID:UserID) async throws -> V2SocialOperationSnapshot {
        let client=self.client
        let snapshot=try await V2HTTPRequestDeadline.run(until:.now.advanced(by:.seconds(15)),service:"accountAPI") { try await client.baseline(targetUserID:targetUserID) }
        guard snapshot.actorUserID==accountID,snapshot.targetUserID==targetUserID else { throw V2SocialOperationValidationError.invalidSnapshot };return snapshot
    }
    @discardableResult public func enqueue(action:V2SocialOperationAction,targetUserID:UserID) async throws -> UUID {
        try Task.checkCancellation()
        let clicked=ContinuousClock.now,wall=Date()
        let outerDeadline=V2HTTPRequestDeadline.current
        let snapshot=try await baseline(targetUserID:targetUserID)
        // Resolution time belongs to the original click; it does not renew its window.
        let milliseconds=action.kind == .relationship ? 600_000 : 120_000
        let deadline=min(clicked.advanced(by:.milliseconds(milliseconds)),outerDeadline ?? clicked.advanced(by:.milliseconds(milliseconds)))
        guard deadline > .now else { throw V2OperationWorkError.invalidTransition }
        return try await enqueue(action:action,snapshot:snapshot,confirmedAt:wall,monotonicDeadline:deadline)
    }
    /// The action and observed revision belong to this click; reading later state cannot prove it ran.
    @discardableResult public func enqueue(action:V2SocialOperationAction,snapshot:V2SocialOperationSnapshot,proposalID:UUID?=nil,confirmedAt:Date=Date(),monotonicDeadline:ContinuousClock.Instant?=nil) async throws -> UUID {
        try Task.checkCancellation()
        guard snapshot.actorUserID==accountID else { throw V2OperationWorkError.accountMismatch }
        let window=action.kind == .relationship ? 600_000 : 120_000
        let timestamp=confirmedAt.timeIntervalSince1970*1000
        guard timestamp.isFinite,timestamp>0,timestamp<Double(Int64.max-Int64(window)) else { throw V2OperationWorkError.invalidRecord }
        let reference:V2OperationReference
        switch action { case .relationship:reference = .relationship(.init(uuid:UUID()));case .userBlock:reference = .userBlock(.init(uuid:UUID())) }
        let identity=try V2OperationIdentity(accountID:accountID,scope:.userPair(accountID,snapshot.targetUserID),operation:reference)
        let mono=monotonicDeadline ?? ContinuousClock.now.advanced(by:.milliseconds(window))
        let elapsed=ContinuousClock.now.duration(to:mono).components
        let remainingMilliseconds=max(0,Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
        let absolute=min(UInt64(timestamp)+UInt64(window),UInt64(Date().timeIntervalSince1970*1000+remainingMilliseconds))
        let command=try V2SocialOperationCommand(identity:identity,action:action,expectedRevision:action.kind == .relationship ? snapshot.relationshipRevision : snapshot.blockRevision,firstSubmissionDeadlineMilliseconds:absolute)
        let deadline=monotonicDeadline ?? ContinuousClock.now.advanced(by:.milliseconds(window))
        let id=try await store.enqueueSocialOperation(command,proposalID:proposalID)
        deadlines[id]=deadline
        return id
    }
    public func resumeConfirmation(workID:UUID) async throws {
        guard let work=try await store.operationWork(id:workID),work.identity.accountID==accountID,[.relationship,.userBlock].contains(work.identity.kind) else { throw V2OperationWorkError.accountMismatch }
        try await store.retryOperationWorkByUser(id:workID,now:Date())
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,[.relationship,.userBlock].contains(claim.work.identity.kind) else { throw V2OperationWorkError.accountMismatch }
        let command=try await store.socialOperationCommand(workID:claim.work.id)
        guard command.identity==claim.work.identity,try command.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        let remaining=max(0,Double(command.firstSubmissionDeadlineMilliseconds)/1000-Date().timeIntervalSince1970)
        let local=deadlines[claim.work.id] ?? ContinuousClock.now.advanced(by:.seconds(min(remaining,command.action.kind == .relationship ? 600 : 120)))
        deadlines[claim.work.id]=local
        do {
            let client=self.client
            let result:V2SocialOperationRecoveryResult
            if claim.action == .submit,local > .now {
                result=try await V2HTTPRequestDeadline.run(until:min(local,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await client.submit(command) }
            } else { result=try await client.recover(command,action:local <= .now ? .closeIfAbsent : .query) }
            switch result {
            case .receipt(let receipt):
                guard receipt.validates(command:command) else { throw V2OperationWorkError.identityConflict }
                let state:V2OperationExecutionState
                switch receipt.outcome { case .applied:state = .committed;case .closed:state = .closed;case .rejected(.revisionConflict):state = .conflicted;case .rejected:state = .rejected }
                try await store.completeOperationWork(.init(identity:command.identity,fingerprint:command.fingerprint,state:state,receipt:receipt),now:Date());deadlines.removeValue(forKey:claim.work.id)
            case .fingerprintConflict:try await store.deferOperationWork(claim,until:Date(),code:"SOCIAL_IDENTITY_CONFLICT",scheduling:.needsAttention)
            case .unresolved:try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"SOCIAL_UNRESOLVED",nextAction:local > .now ? .submit : .reconcile)
            case .deferred(let hint):
                guard hint.validates(identity:command.identity,fingerprint:try command.fingerprint) else { throw V2OperationWorkError.identityConflict }
                try await deferFailure(claim,floor:Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1000),malformed:false)
            }
        } catch is CancellationError { try await store.deferOperationWork(claim,until:Date(),code:"SOCIAL_INTERRUPTED");throw CancellationError() }
        catch { let failure=error as? V2HTTPFailure;try await deferFailure(claim,floor:failure?.retryAfter,malformed:error is V2OperationWorkError || error is V2SocialOperationValidationError);if error is DatabaseError { throw error } }
    }
    private func deferFailure(_ claim:V2OperationWorkClaim,floor:Date?,malformed:Bool) async throws {
        let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,end=claim.work.reconciliationRoundDeadline ?? Date().addingTimeInterval(V2NetworkWorkPolicy.commandRecovery.totalBudget)
        let retry=policy.nextAttempt(now:now,startedAt:end.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
        try await store.deferOperationWork(claim,until:max(retry ?? now,floor ?? now),code:"SOCIAL_CONFIRMATION_REQUIRED",scheduling:malformed || retry == nil ? .needsAttention : .backingOff)
    }
}
