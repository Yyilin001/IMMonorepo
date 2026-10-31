import Foundation
import IMV2Core

/// Account-owned recovery. Cancelling a page waiter does not cancel the mutation.
/// Its shared transfer engine is owned and closed separately by the account.
public actor V2GroupAvatarIntentEngine {
    private let actorUserID: UserID
    private let store: GRDBV2LocalSyncStore
    private let transfers: V2ResourceTransferEngine
    private let submissions: any V2GroupAvatarCommandSubmitting
    private let recovery: (any V2GroupAvatarOperationRecovering)?
    private let now: @Sendable () -> Date
    private var flights: [GroupAvatarOperationID: V2SharedOperation<V2GroupAvatarIntent>] = [:]
    private var waiters = 0
    private var closed = false
    private let operations = V2ResourceOperationScope(limit: 64)

    public init(actorUserID: UserID, store: GRDBV2LocalSyncStore, transfers: V2ResourceTransferEngine,
                submissions: any V2GroupAvatarCommandSubmitting, recovery: (any V2GroupAvatarOperationRecovering)? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.actorUserID = actorUserID; self.store = store; self.transfers = transfers
        self.submissions = submissions; self.recovery = recovery; self.now = now
    }

    public func resume(_ id: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard waiters < 64 else { throw V2GroupAvatarIntentError.busy }
        waiters += 1
        defer { waiters -= 1 }
        return try await flight(for: id).value
    }

    /// Wake a frozen command without making the management page wait for an
    /// upload. The account owns this flight; its existing recovery loop retries
    /// a bounded-admission failure by reading the same journal identity.
    public func start(_ id: GroupAvatarOperationID) throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        _ = try flight(for: id)
    }

    private func flight(for id: GroupAvatarOperationID) throws -> V2SharedOperation<V2GroupAvatarIntent> {
        if let flight = flights[id] { return flight }
        guard flights.count < 2 else { throw V2GroupAvatarIntentError.busy }
        let flight = V2SharedOperation { try await self.perform(id) }
        flights[id] = flight
        return flight
    }

    /// One bounded pass. The account runtime decides when to wake after backoff.
    public func recoverOnce() async throws {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performRecoveryPass() }
    }

    private func performRecoveryPass() async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if recovery != nil { try await store.reconcileGroupAvatarRecovery(now: now()) }
        for id in try await store.dueGroupAvatarIntents(now: now()) {
            try Task.checkCancellation()
            do { _ = try await resume(id) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Durable state and per-command backoff determine the next pass. */ }
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if recovery != nil { try await store.reconcileGroupAvatarRecovery(now: now()) }
        try await transfers.releaseFinishedSources()
    }

    public func retry(_ id: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performRetry(id) }
    }

    private func performRetry(_ id: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let value = try await requireIntent(id)
        try requireOpen()
        if !value.submissionStarted, let job = value.uploadJobID { try await store.retryResourceTransfer(id: job) }
        if !value.submissionStarted, let job = value.importJobID { try await store.retryResourceImport(id: job) }
        try requireOpen()
        try await store.retryGroupAvatarIntent(id)
        return try await resume(id)
    }

    public func cancel(_ id: GroupAvatarOperationID) async throws {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performCancel(id) }
    }

    private func performCancel(_ id: GroupAvatarOperationID) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let value = try await requireIntent(id)
        try requireOpen()
        try await store.cancelGroupAvatarIntent(id)
        if let flight = flights[id] { flight.cancel(); _ = await flight.result }
        if let job = value.uploadJobID { try await transfers.cancel(id: job) }
        try await transfers.releaseFinishedSources()
    }

    public func resolve(_ id: GroupAvatarOperationID, action: V2GroupAvatarRecoveryRequest.Action) async throws -> V2GroupAvatarIntent {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performResolve(id, action: action) }
    }

    private func performResolve(_ id: GroupAvatarOperationID, action: V2GroupAvatarRecoveryRequest.Action) async throws -> V2GroupAvatarIntent {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard recovery != nil else { throw V2GroupAvatarIntentError.recoveryUnavailable }
        guard waiters < 64 else { throw V2GroupAvatarIntentError.busy }
        waiters += 1
        defer { waiters -= 1 }
        _ = try await requireIntent(id)
        try requireOpen()
        try await store.requestGroupAvatarRecovery(id, action: action)
        // Persist first, then drain an older submission. Its positive receipt may
        // still win; its failure cannot overwrite the newly requested mode.
        if let flight = flights[id] { _ = try? await flight.value }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return try await resume(id)
    }

    public func abandonClosed(_ id: GroupAvatarOperationID) async throws {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performAbandonClosed(id) }
    }

    private func performAbandonClosed(_ id: GroupAvatarOperationID) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let value = try await requireIntent(id)
        try requireOpen()
        try await store.abandonClosedGroupAvatarIntent(id)
        if let job = value.uploadJobID { try? await transfers.cancel(id: job) }
        try await transfers.releaseFinishedSources()
    }

    /// The caller obtains a fresh revision before choosing to replace a closed
    /// command. This only journals the replacement; resume drives its upload.
    public func replaceClosed(_ id: GroupAvatarOperationID, expectedRevision: UInt64) async throws -> GroupAvatarOperationID {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performReplaceClosed(id, expectedRevision: expectedRevision) }
    }

    private func performReplaceClosed(_ id: GroupAvatarOperationID, expectedRevision: UInt64) async throws -> GroupAvatarOperationID {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let value = try await requireIntent(id)
        try requireOpen()
        let replacement = try await store.replaceClosedGroupAvatarIntent(id, expectedRevision: expectedRevision, now: now())
        if let job = value.uploadJobID { try? await transfers.cancel(id: job) }
        try await transfers.releaseFinishedSources()
        return replacement
    }

    /// Account activity cancellation drains shared command I/O before network admission closes.
    public func stopRecoveryAndDrain() async {
        let running = Array(flights.values)
        for flight in running { flight.cancel() }
        for flight in running { _ = await flight.result }
    }

    public func close() async {
        closed = true
        async let drainOperations: Void = operations.close()
        let running = Array(flights.values)
        for flight in running { flight.cancel() }
        for flight in running { _ = await flight.result }
        flights.removeAll()
        await drainOperations
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    private func requireIntent(_ id: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent {
        guard let value = try await store.groupAvatarIntent(id) else { throw V2GroupAvatarIntentError.missing }
        guard value.actorUserID == actorUserID else { throw V2GroupAvatarIntentError.accountMismatch }
        return value
    }

    private func perform(_ id: GroupAvatarOperationID) async throws -> V2GroupAvatarIntent {
        defer { flights.removeValue(forKey: id) }
        let value = try await requireIntent(id)
        if [.committed, .cancelled, .closed, .needsAttention].contains(value.stage) { return value }
        if value.recoveryAction != nil && recovery == nil { throw V2GroupAvatarIntentError.recoveryUnavailable }
        // Match the journal's Unix-seconds comparison: a Foundation Date
        // round trip can otherwise move an exactly due retry fractionally ahead.
        guard value.retryAt.timeIntervalSince1970 <= now().timeIntervalSince1970 else {
            throw V2GroupAvatarIntentError.busy
        }
        if !value.submissionStarted, let jobID = value.importJobID {
            guard let job = try await store.resourceImport(id: jobID) else { throw V2GroupAvatarIntentError.invalidRecord }
            if job.status?.state != .ready || job.cancellationRequested {
                if job.cancellationRequested || job.attempts >= 5 || job.status?.state == .failed || job.status?.state == .cancelled {
                    try await store.pauseGroupAvatarPreparation(id)
                }
                return try await requireIntent(id)
            }
        }
        if !value.submissionStarted, let jobID = value.uploadJobID {
            do {
                guard let job = try await store.resourceTransfer(id: jobID) else { throw V2GroupAvatarIntentError.invalidRecord }
                if job.stage != .ready || job.cancellationRequested {
                    if job.cancellationRequested || job.needsAttention || [.cancelled,.rejected,.expired].contains(job.stage) {
                        try await store.pauseGroupAvatarPreparation(id)
                    }
                    return try await requireIntent(id)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try requireOpen()
                try await store.pauseGroupAvatarPreparation(id)
                throw error
            }
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let claim: V2GroupAvatarSubmissionClaim
        do { claim = try await store.claimGroupAvatarSubmission(id, now: now()) }
        catch V2ResourceJournalError.bindingExpired { try await store.pauseGroupAvatarPreparation(id); throw V2ResourceJournalError.bindingExpired }
        do {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "groupAvatar", priority: .recovery, isRetry: claim.intent.attempts>1)) {
                try await V2HTTPRequestDeadline.$current.withValue(ContinuousClock.now.advanced(by: .seconds(15))) {
                    if let action = claim.intent.recoveryAction {
                        guard let recovery else { throw V2GroupAvatarIntentError.recoveryUnavailable }
                        let request = V2GroupAvatarRecoveryRequest(command: claim.intent.command, action: action)
                        let response = try await recovery.recoverGroupAvatar(request)
                        try await store.finishGroupAvatarRecovery(claim, response: response, now: now())
                    } else {
                        let response = try await submissions.submitGroupAvatar(claim.intent.command)
                        try await store.finishGroupAvatarSubmission(claim, response: response, now: now())
                    }
                }
            }
        } catch {
            let issue: V2GroupAvatarIntent.Issue
            let attention: Bool
            var delay = Double.random(in: 0.5...1) * min(30, pow(2, Double(min(5, claim.intent.attempts))))
            switch error {
            case V2GroupAvatarSubmissionError.authorizationUnavailable: issue = .authorizationUnavailable; attention = false
            case V2GroupAvatarSubmissionError.authorizationDenied: issue = .forbidden; attention = true
            case V2GroupAvatarSubmissionError.invalidResponse: issue = .invalidResponse; attention = true
            case V2GroupAvatarSubmissionError.operationClosed: issue = .outcomeUnknown; attention = true
            case V2GroupAvatarSubmissionError.throttled(let retry):
                issue = .throttled
                // A lower bound outside this recovery step's budget requires user attention.
                attention = !retry.isFinite || retry < 0 || retry > V2NetworkWorkPolicy.commandRecovery.totalBudget
                if retry.isFinite && retry>=0 { delay = max(delay,retry) }
            default: issue = .outcomeUnknown; attention = false
            }
            try await store.failGroupAvatarSubmission(claim, issue: issue, retryAt: now().addingTimeInterval(delay), attention: attention)
            throw error
        }
        let completed = try await requireIntent(id)
        if completed.stage == .committed { try? await transfers.releaseFinishedSources() }
        return completed
    }
}
