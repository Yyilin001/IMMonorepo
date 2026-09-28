import Foundation
import IMV2Core

public protocol V2ReadReceiptOperationClient: Sendable {
    func submit(_ command: V2RecordReadReceiptCommand) async throws -> V2ReadReceiptOperationReceipt
    func recover(_ request: V2ReadReceiptRecoveryRequest) async throws -> V2ReadReceiptRecoveryResult
}

/// UI only persists a max intent. Account-owned activities freeze and dispatch its original operation.
public actor V2ReadReceiptOperationService {
    private let accountID: UserID
    private let store: GRDBV2LocalSyncStore
    private let client: any V2ReadReceiptOperationClient
    public init(accountID: UserID, store: GRDBV2LocalSyncStore, client: any V2ReadReceiptOperationClient) {
        self.accountID=accountID; self.store=store; self.client=client
    }
    @discardableResult public func enqueue(roomID: RoomID, readThrough: UInt64) async throws -> Bool {
        try Task.checkCancellation()
        return try await store.enqueueReadReceiptIntent(accountID:accountID,roomID:roomID,readThrough:readThrough)
    }
    /// Only an explicit user action starts a fresh bounded confirmation round.
    public func resumeConfirmation(roomID: RoomID) async throws {
        try Task.checkCancellation()
        if let head = try await store.readReceiptRecoveryNeedingAttention(roomID:roomID) {
            try await store.retryOperationWorkByUser(id:head,now:Date())
        }
    }
    public func archiveUnavailable(workID: UUID) async throws {
        try Task.checkCancellation()
        try await store.archiveReadReceiptWork(id: workID, accountID: accountID)
    }
    public func restoreArchive(workID: UUID) async throws {
        try Task.checkCancellation()
        try await store.restoreReadReceiptArchive(id: workID, accountID: accountID)
    }
    public func statusUpdates(roomID: RoomID) -> AsyncThrowingStream<V2ReadReceiptTrackingSnapshot, any Error> {
        store.readReceiptWorkUpdates(roomID:roomID)
    }
    public func runPreparation() async throws {
        for try await _ in store.readReceiptPreparationUpdates() {
            try Task.checkCancellation()
            do {
                while try await store.prepareNextReadReceiptIntent(accountID:accountID) { try Task.checkCancellation() }
            } catch V2OperationWorkError.capacityExceeded {
                // Keep the draft durable; a change in active work count wakes preparation again.
            }
        }
    }
    public func execute(_ claim: V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID == accountID, claim.work.identity.kind == .readReceipt else { throw V2OperationWorkError.accountMismatch }
        let command=try await store.readReceiptCommand(workID:claim.work.id)
        guard try command.identity == claim.work.identity, try command.fingerprint == claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        let controlOnly = try await store.readReceiptUsesControlAdmission(workID: claim.work.id)
        guard !controlOnly || claim.action == .reconcile else { throw V2OperationWorkError.invalidTransition }
        do {
            let result: V2ReadReceiptRecoveryResult
            if claim.action == .submit {
                guard try await store.allowsLocalReadReceiptPublication(roomID:command.roomID) else {
                    try await store.deferOperationWork(claim,until:Date(),code:"READ_RECEIPT_LOCAL_PRIVACY_PAUSED",scheduling:.needsAttention);return
                }
                result = .originalReceipt(try await client.submit(command))
            }
            else { result = try await client.recover(.init(command:command)) }
            switch result {
            case .originalReceipt, .watermarkProof:
                try await store.completeReadReceiptWork(command,result:result)
            case .currentUnavailable:
                try await store.deferOperationWork(claim,until:Date(),code:"READ_RECEIPT_CURRENT_UNAVAILABLE",scheduling:.needsAttention)
            case .fingerprintConflict:
                try await store.deferOperationWork(claim,until:Date(),code:"READ_RECEIPT_FINGERPRINT_CONFLICT",scheduling:.needsAttention)
            case .unresolved:
                let retryAt = Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts))
                if controlOnly {
                    // Transfer the same frozen identity to ordinary admission before
                    // permitting its existing resubmit semantics. Full ordinary
                    // capacity pauses control tracking; user continuation queries first.
                    try await store.resumeReadReceiptSubmissionFromControl(claim, until: retryAt)
                } else {
                    try await store.deferOperationWork(claim,until:retryAt,code:"READ_RECEIPT_UNRESOLVED",nextAction:.submit)
                }
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"READ_RECEIPT_INTERRUPTED")
            throw CancellationError()
        } catch {
            let now=Date(), failure=error as? V2HTTPFailure
            let malformed=error is V2ReadReceiptRecoveryValidationError || error is V2OperationWorkError || (failure.map { [.invalidEndpoint,.invalidResponse,.responseTooLarge].contains($0.kind) } ?? false)
            let policy=V2NetworkWorkPolicy.commandRecovery
            let deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
            let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:failure?.retryAfter)
            try await store.deferOperationWork(claim,until:max(retry ?? now,failure?.retryAfter ?? now),code:"READ_RECEIPT_CONFIRMATION_REQUIRED",scheduling:malformed || retry == nil ? .needsAttention : .backingOff)
        }
    }
}
