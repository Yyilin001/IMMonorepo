import Foundation
import GRDB
import IMV2Core

/// Every dispatcher claim advances at most one bounded page or one recovery call.
public actor V2GroupCreationOperationService {
    private let accountID:UserID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2GroupCreationOperationClient
    public init(accountID:UserID,store:GRDBV2LocalSyncStore,client:any V2GroupCreationOperationClient) {
        self.accountID=accountID;self.store=store;self.client=client
    }
    public func enqueue(title:String,members:[UserID]) async throws -> UUID {
        try Task.checkCancellation()
        let now=Date(),canonical=try V2GroupCreationAudience.canonical(members,actorUserID:accountID)
        guard let capacity=V2GroupCapacityPolicy().capacityClass(forInitialMemberCount:canonical.count+1) else { throw V2GroupCreationValidationError.invalidIntent }
        let milliseconds=(now.timeIntervalSince1970*1000).rounded(.towardZero)
        guard milliseconds.isFinite,milliseconds>0,milliseconds<Double(Int64.max)-600_000,let time=UInt64(exactly:milliseconds) else { throw V2GroupCreationValidationError.invalidIntent }
        let intent=try V2GroupCreationIntent(identity:.init(accountID:accountID,scope:.account(accountID),operation:.groupRoom(.init(uuid:UUID()))),title:title,capacityClass:capacity,initialMemberCount:canonical.count,audienceDigest:V2GroupCreationAudience.digest(canonical),firstSubmissionDeadlineMilliseconds:time+V2ClientSubmissionWindow.milliseconds(maximum:600_000))
        return try await store.enqueueGroupCreationOperation(intent,members:canonical,now:now)
    }
    public func updates() -> AsyncThrowingStream<Void,any Error> { store.groupCreationUpdates() }
    public func latest() async throws -> V2GroupCreationPending? { try await store.latestGroupCreation() }
    public func pending(id:UUID) async throws -> V2GroupCreationPending { try await store.groupCreationPending(id:id) }
    public func requestCancellation(id:UUID) async throws {
        try Task.checkCancellation()
        try await store.requestGroupCreationCancellation(id:id,accountID:accountID)
        let pending=try await store.groupCreationPending(id:id)
        if pending.work.scheduling == .needsAttention { try await store.retryOperationWorkByUser(id:id,now:Date()) }
    }
    public func resume(id:UUID) async throws {
        try Task.checkCancellation()
        let pending=try await store.groupCreationPending(id:id)
        guard pending.intent.identity.accountID==accountID else { throw V2OperationWorkError.accountMismatch }
        try await store.retryOperationWorkByUser(id:id,now:Date())
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,claim.work.identity.kind == .groupRoom else { throw V2OperationWorkError.accountMismatch }
        let pending=try await store.groupCreationPending(id:claim.work.id)
        guard pending.work.identity==claim.work.identity,pending.work.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        let intent=pending.intent
        do {
            let open=Date().timeIntervalSince1970*1000<Double(intent.firstSubmissionDeadlineMilliseconds)
            let result:V2GroupCreationOperationResult
            if pending.cancellationRequested || !open {
                result=try await client.recover(intent,action:.closeIfAbsent)
            } else if claim.action == .reconcile || pending.progress?.phase == .finalizing {
                result=try await client.recover(intent,action:.query)
            } else if let progress=pending.progress {
                if progress.acceptedMemberCount<intent.initialMemberCount {
                    let end=min(intent.initialMemberCount,progress.acceptedMemberCount+V2GroupCreationAudience.maximumPageMembers)
                    result=try await client.append(.init(intent:intent,offset:progress.acceptedMemberCount,memberUserIDs:Array(pending.members[progress.acceptedMemberCount..<end])))
                } else { result=try await client.finalize(intent) }
            } else { result=try await client.begin(intent) }
            try Task.checkCancellation()
            switch result {
            case .receipt(let receipt):
                if case .created(let room,_,_,_)=receipt.outcome,let progress=pending.progress,progress.roomID != room { throw V2GroupCreationValidationError.invalidReceipt }
                try await store.completeGroupCreation(receipt,intent:intent)
            case .progress(let progress):
                try await store.saveGroupCreationProgress(progress,claim:claim,nextAction:pending.cancellationRequested || !open || progress.phase == .finalizing ? .reconcile:.submit)
            case .unresolved:
                try await store.deferOperationWork(claim,until:Date().addingTimeInterval(1),code:"GROUP_CREATION_UNRESOLVED",nextAction:open && !pending.cancellationRequested ? .submit:.reconcile)
            case .fingerprintConflict:
                try await store.deferOperationWork(claim,until:Date(),code:"GROUP_CREATION_FINGERPRINT_CONFLICT",scheduling:.needsAttention)
            case .deferred(let hint):
                guard hint.validates(identity:intent.identity,fingerprint:try intent.fingerprint) else { throw V2OperationWorkError.identityConflict }
                try await deferFailure(claim,floor:Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1000),malformed:false)
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"GROUP_CREATION_INTERRUPTED")
            throw CancellationError()
        } catch {
            try await deferFailure(claim,floor:(error as? V2HTTPFailure)?.retryAfter,malformed:error is DatabaseError || error is V2OperationWorkError || error is V2GroupCreationValidationError)
            if error is DatabaseError { throw error }
        }
    }
    private func deferFailure(_ claim:V2OperationWorkClaim,floor:Date?,malformed:Bool) async throws {
        let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery
        let deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
        let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
        try await store.deferOperationWork(claim,until:max(retry ?? now,floor ?? now),code:"GROUP_CREATION_CONFIRMATION_REQUIRED",scheduling:malformed || retry==nil ? .needsAttention:.backingOff)
    }
}
