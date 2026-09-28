import Foundation
import IMV2Core

public actor V2NameOperationService {
    private let accountID: UserID
    private let store: GRDBV2LocalSyncStore
    private let client: any V2NameOperationClient
    private let didCommit: @Sendable (V2NameTarget) async -> Void
    public init(accountID: UserID, store: GRDBV2LocalSyncStore, client: any V2NameOperationClient,
                didCommit: @escaping @Sendable (V2NameTarget) async -> Void = { _ in }) {
        self.accountID = accountID; self.store = store; self.client = client
        self.didCommit = didCommit
    }
    public func cached(_ target: V2NameTarget) async throws -> V2NameSnapshot? { try await store.nameSnapshot(target: target) }
    public func refresh(_ target: V2NameTarget) async throws -> V2NameSnapshot {
        let value: V2NameSnapshot
        switch target {
        case .contact(let id):
            let remote = try await client.contactSnapshot(owner: accountID, target: id)
            guard remote.ownerUserID == accountID, remote.targetUserID == id else { throw V2OperationWorkError.accountMismatch }
            value = .init(target: target, name: remote.value?.remarkName, revision: remote.value?.revision)
        case .group(let room):
            let remote = try await client.groupSnapshot(actor: accountID, room: room)
            guard remote.actorUserID == accountID, remote.roomID == room else { throw V2OperationWorkError.accountMismatch }
            value = .init(target: target, name: remote.value?.groupNickname, revision: remote.value?.revision)
        }
        try Task.checkCancellation()
        try await store.saveNameSnapshot(value, accountID: accountID)
        guard let current = try await store.nameSnapshot(target: target) else { throw V2OwnProfileClientError.invalidResponse }
        return current
    }
    @discardableResult public func save(_ target: V2NameTarget, name: String?, expectedRevision: V2ProfileRevision?) async throws -> UUID {
        try Task.checkCancellation()
        return try await store.enqueueNameOperation(accountID: accountID, target: target, name: name, expectedRevision: expectedRevision)
    }
    public func updates(_ target: V2NameTarget) -> AsyncThrowingStream<V2NameIntentSnapshot?, any Error> { store.nameIntentUpdates(target: target) }
    public func baselineUpdates(_ target: V2NameTarget) -> AsyncThrowingStream<V2NameSnapshot?, any Error> { store.nameSnapshotUpdates(target: target) }
    public func continueConfirmation(id: UUID) async throws { try await store.retryOperationWorkByUser(id: id, now: Date()) }
    public func discard(id: UUID) async throws { try await store.requestNameOperationClose(id: id) }
    public func execute(_ claim: V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID == accountID, [.contactAlias,.groupNickname].contains(claim.work.identity.kind) else { throw V2OperationWorkError.accountMismatch }
        let (command, closeRequested) = try await store.nameCommand(workID: claim.work.id)
        guard command.identity == claim.work.identity, command.fingerprint == claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        do {
            let receipt: V2NameReceipt?
            var conflict = false
            let inWindow = (claim.work.admissionDeadline ?? .distantPast) > Date()
            if claim.action == .submit && !closeRequested {
                switch command {
                case .contact(let c): receipt = .contact(try await client.submit(c))
                case .group(let c): receipt = .group(try await client.submit(c))
                }
            } else {
                let action: V2OperationRecoveryRequest.Action = closeRequested || !inWindow ? .closeIfAbsent : .query
                switch command {
                case .contact:
                    switch try await client.recover(V2ContactAliasRecoveryRequest(identity: command.identity, fingerprint: command.fingerprint, action: action)) {
                    case .receipt(let r): receipt = .contact(r)
                    case .unresolved: receipt = nil
                    case .fingerprintConflict: receipt = nil; conflict = true
                    }
                case .group:
                    switch try await client.recover(V2GroupNicknameRecoveryRequest(identity: command.identity, fingerprint: command.fingerprint, action: action)) {
                    case .receipt(let r): receipt = .group(r)
                    case .unresolved: receipt = nil
                    case .fingerprintConflict: receipt = nil; conflict = true
                    }
                }
            }
            if let receipt {
                try await store.completeNameOperation(command, receipt: receipt)
                if receipt.state == .committed { await didCommit(command.target) }
                return
            }
            try await store.deferOperationWork(claim,
                until: Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt: claim.work.reconciliationRoundAttempts)),
                code: conflict ? "NAME_FINGERPRINT_CONFLICT" : "NAME_UNRESOLVED", scheduling: conflict ? .needsAttention : .backingOff,
                nextAction: inWindow && !closeRequested ? .submit : .reconcile)
        } catch is CancellationError {
            try await store.deferOperationWork(claim, until: Date(), code: "NAME_INTERRUPTED")
            throw CancellationError()
        } catch {
            let now = Date(), failure = error as? V2HTTPFailure
            let permanent = error is V2OperationWorkError || (error as? V2OwnProfileClientError) == .invalidResponse ||
                (failure.map { [.invalidEndpoint,.invalidResponse,.responseTooLarge].contains($0.kind) || [400,403,404,409,413,415,422].contains($0.statusCode ?? 0) } ?? false)
            let policy = V2NetworkWorkPolicy.commandRecovery
            let deadline = claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
            let next = policy.nextAttempt(now: now, startedAt: deadline.addingTimeInterval(-policy.totalBudget),
                attemptsCompleted: claim.work.reconciliationRoundAttempts, randomUnit: Double.random(in: 0...1), serverRetryNotBefore: failure?.retryAfter)
            try await store.deferOperationWork(claim, until: max(next ?? now, failure?.retryAfter ?? now), code: "NAME_CONFIRMATION_REQUIRED", scheduling: permanent || next == nil ? .needsAttention : .backingOff)
        }
    }
}
