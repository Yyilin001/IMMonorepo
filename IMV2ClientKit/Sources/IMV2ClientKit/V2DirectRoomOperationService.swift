import Foundation
import GRDB
import IMV2Core

/// Persists the original opening request before any network work is admitted.
public actor V2DirectRoomOperationService {
    private let accountID:UserID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2DirectRoomOperationClient
    private var deadlines:[UUID:ContinuousClock.Instant]=[:]

    public init(accountID:UserID,store:GRDBV2LocalSyncStore,client:any V2DirectRoomOperationClient) {
        self.accountID=accountID;self.store=store;self.client=client
    }
    public func enqueue(publicIdentity:V2PublicIdentity) async throws -> UUID {
        try Task.checkCancellation()
        let monotonicDeadline=ContinuousClock.now.advanced(by:.seconds(600))
        let now=Date(),milliseconds=(now.timeIntervalSince1970*1000).rounded(.towardZero)
        guard milliseconds.isFinite,milliseconds>0,milliseconds<Double(Int64.max)-600_000,
              let time=UInt64(exactly:milliseconds) else { throw V2DirectRoomOperationValidationError.invalidCommand }
        let command=try V2DirectRoomOperationCommand(actorUserID:accountID,operationID:.init(UUID().uuidString),targetUserID:publicIdentity.userID,firstSubmissionDeadlineMilliseconds:time+600_000)
        let id=try await store.enqueueDirectRoomOperation(command,publicIdentity:publicIdentity,now:now)
        let original=try await store.directRoomCommand(workID:id)
        if original.operationID==command.operationID { deadlines[id]=monotonicDeadline }
        return id
    }
    public func updates() -> AsyncThrowingStream<[V2DirectRoomPending],any Error> { store.directRoomUpdates() }
    public func resume(id:UUID) async throws {
        try Task.checkCancellation()
        let command=try await store.directRoomCommand(workID:id)
        guard command.actorUserID==accountID else { throw V2OperationWorkError.accountMismatch }
        try await store.retryOperationWorkByUser(id:id,now:Date())
    }
    public func resumeIfNeeded(id:UUID) async throws {
        try Task.checkCancellation()
        guard let work=try await store.operationWork(id:id),work.identity.accountID==accountID,work.identity.kind == .directRoom else { throw V2OperationWorkError.accountMismatch }
        if work.scheduling == .needsAttention { try await store.retryOperationWorkByUser(id:id,now:Date()) }
    }
    public func receipt(id:UUID) async throws -> V2DirectRoomOperationReceipt? {
        try await store.directRoomReceipt(workID:id,accountID:accountID)
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,claim.work.identity.kind == .directRoom else { throw V2OperationWorkError.accountMismatch }
        let command=try await store.directRoomCommand(workID:claim.work.id)
        guard try command.identity==claim.work.identity,try command.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        let remaining=max(0,Double(command.firstSubmissionDeadlineMilliseconds)/1000-Date().timeIntervalSince1970)
        let wallDeadline=ContinuousClock.now.advanced(by:.seconds(min(remaining,600)))
        // Either clock may shorten the original window; neither may extend it.
        let deadline=min(deadlines[claim.work.id] ?? wallDeadline,wallDeadline)
        deadlines[claim.work.id]=deadline
        do {
            try Task.checkCancellation()
            let result:V2DirectRoomOperationResult
            if claim.action == .submit,claim.work.execution != .processing,deadline > .now {
                let client=self.client
                result=try await V2HTTPRequestDeadline.run(until:min(deadline,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await client.submit(command) }
            } else {
                result=try await client.recover(command,action:deadline <= .now ? .closeIfAbsent:.query)
            }
            try Task.checkCancellation()
            switch result {
            case .receipt(let receipt):
                guard receipt.validates(command:command) else { throw V2DirectRoomOperationValidationError.invalidReceipt }
                try await store.completeDirectRoom(receipt,workID:claim.work.id)
                deadlines.removeValue(forKey:claim.work.id)
            case .processing(let proof):
                guard proof.validates(command:command) else { throw V2DirectRoomOperationValidationError.invalidProof }
                try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"DIRECT_ROOM_PROCESSING",processing:true,nextAction:.reconcile)
            case .unresolved:
                try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"DIRECT_ROOM_UNRESOLVED",nextAction:deadline > .now && claim.work.execution != .processing ? .submit:.reconcile)
            case .fingerprintConflict:
                try await store.deferOperationWork(claim,until:Date(),code:"DIRECT_ROOM_IDENTITY_CONFLICT",scheduling:.needsAttention)
            case .deferred(let hint):
                guard hint.validates(identity:try command.identity,fingerprint:try command.fingerprint) else { throw V2OperationWorkError.identityConflict }
                try await deferFailure(claim,floor:Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1000),malformed:false)
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"DIRECT_ROOM_INTERRUPTED")
            throw CancellationError()
        } catch {
            try await deferFailure(claim,floor:(error as? V2HTTPFailure)?.retryAfter,malformed:error is V2OperationWorkError || error is V2DirectRoomOperationValidationError || error is DecodingError || error is DatabaseError)
            if error is DatabaseError { throw error }
        }
    }
    private func deferFailure(_ claim:V2OperationWorkClaim,floor:Date?,malformed:Bool) async throws {
        let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery
        let end=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
        let retry=policy.nextAttempt(now:now,startedAt:end.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
        try await store.deferOperationWork(claim,until:max(retry ?? now,floor ?? now),code:"DIRECT_ROOM_CONFIRMATION_REQUIRED",scheduling:malformed || retry==nil ? .needsAttention:.backingOff)
    }
}
