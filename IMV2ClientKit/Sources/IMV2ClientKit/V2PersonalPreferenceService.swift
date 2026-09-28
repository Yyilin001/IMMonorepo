import Foundation
import IMV2Core

/// Account-owned intent preparation and one-step submission/reconciliation.
public actor V2PersonalPreferenceService {
    private let accountID: UserID
    private let store: GRDBV2LocalSyncStore
    private let transport: any V2ClientConversationCapabilitiesTransport
    private let recovery: any V2PersonalPreferenceRecovering
    public init(accountID: UserID, store: GRDBV2LocalSyncStore, transport: any V2ClientConversationCapabilitiesTransport,
                recovery: any V2PersonalPreferenceRecovering) {
        self.accountID = accountID; self.store = store; self.transport = transport; self.recovery = recovery
    }
    @discardableResult
    public func enqueue(_ target: V2PersonalPreferenceTarget) async throws -> UUID {
        try Task.checkCancellation()
        return try await store.enqueuePersonalPreference(accountID: accountID, target: target)
    }
    public func runPreparation() async throws {
        try await V2CommandRetryScheduler(schedule: store.personalPreferencePreparationSchedule(), flush: {
            _ = try await self.store.preparePersonalPreferences(accountID: self.accountID)
        }).run()
    }
    public func pendingUpdates(limit: Int = 200) -> AsyncThrowingStream<[V2PersonalPreferencePending], any Error> {
        store.personalPreferencePendingUpdates(accountID: accountID, limit: limit)
    }
    public func desiredTarget(fallback: V2PersonalPreferenceTarget) async throws -> V2PersonalPreferenceTarget {
        try await store.personalPreferenceTarget(accountID: accountID, fallback: fallback)
    }
    public func resumeConfirmation(intentID: UUID) async throws {
        try await store.resumePersonalPreference(id: intentID, accountID: accountID)
    }
    public func discard(intentID: UUID) async throws {
        try await store.discardPersonalPreference(id: intentID, accountID: accountID)
    }
    public func execute(_ claim: V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID == accountID,
              [.conversationPreference, .messageFavorite].contains(claim.work.identity.kind) else { throw V2OperationWorkError.accountMismatch }
        let command = try await store.personalPreferenceCommand(workID: claim.work.id)
        guard claim.work.identity == (try command.identity(accountID: accountID)),
              claim.work.fingerprint == (try command.fingerprint(accountID: accountID)) else { throw V2OperationWorkError.identityConflict }
        do {
            let receipt: V2PersonalPreferenceReceipt
            switch claim.action {
            case .submit:
                switch command {
                case .conversation(let value): receipt = try await transport.setConversationState(command: value)
                case .favorite(let value): receipt = try await transport.setMessageFavorite(command: value)
                }
            case .reconcile:
                let inWindow = (claim.work.admissionDeadline ?? .distantPast) > Date()
                let result = try await recovery.recover(.init(identity: claim.work.identity, fingerprint: claim.work.fingerprint,
                                                             action: inWindow ? .query : .closeIfAbsent))
                switch result {
                case .receipt(let value): receipt = value
                case .unresolved:
                    try await store.deferOperationWork(claim, until: Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt: claim.work.reconciliationRoundAttempts)),
                        code: "PERSONAL_PREFERENCE_UNRESOLVED", nextAction: inWindow ? .submit : .reconcile)
                    return
                case .fingerprintConflict:
                    try await store.deferOperationWork(claim, until: Date(), code: "PERSONAL_PREFERENCE_FINGERPRINT_CONFLICT", scheduling: .needsAttention)
                    return
                }
            }
            // A validated success remains authoritative even if caller cancellation raced with its arrival.
            try await store.completePersonalPreference(command: command, receipt: receipt, accountID: accountID)
        } catch is CancellationError {
            try await store.deferOperationWork(claim, until: Date(), code: "PERSONAL_PREFERENCE_INTERRUPTED")
            throw CancellationError()
        } catch {
            let now = Date(), failure = error as? V2HTTPFailure
            var permanent = error is V2OperationWorkError || (error as? V2OwnProfileClientError) == .invalidResponse
            if let failure {
                permanent = permanent || [.invalidEndpoint, .invalidResponse, .responseTooLarge].contains(failure.kind) || [400,403,404,409,413,415,422].contains(failure.statusCode ?? 0)
            }
            var retryNotBefore = failure?.retryAfter
            if case V2RealtimeTransportError.server(_, let retryable, let delay, _) = error {
                permanent = permanent || !retryable
                retryNotBefore = now.addingTimeInterval(Double(delay))
            }
            let policy = V2NetworkWorkPolicy.commandRecovery
            let deadline = claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
            let next = policy.nextAttempt(now: now, startedAt: deadline.addingTimeInterval(-policy.totalBudget),
                attemptsCompleted: claim.work.reconciliationRoundAttempts, randomUnit: Double.random(in: 0...1), serverRetryNotBefore: retryNotBefore)
            // Transport errors do not prove rejection. Even permanent errors leave the original intent unknown.
            try await store.deferOperationWork(claim, until: max(next ?? now, retryNotBefore ?? now), code: "PERSONAL_PREFERENCE_CONFIRMATION_REQUIRED",
                scheduling: permanent || next == nil ? .needsAttention : .backingOff)
        }
    }
}
