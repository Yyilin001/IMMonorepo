import Foundation
import GRDB
import IMV2Core

private enum V2ProfilePreparationError: Error { case dependencyDeferred, deadlineExpired }

/// Account-owned single-step adapter; page lifetime never owns network submission.
public actor V2ProfileIntentService: V2ProfileIntentManaging {
    private let store: GRDBV2LocalSyncStore
    private let accountID: UserID
    private let manager: any V2OwnProfileManaging
    private let avatars: (any V2ProfileAvatarPreparing)?
    private let wake: @Sendable () async -> Void
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var preparing = false
    public init(store: GRDBV2LocalSyncStore, accountID: UserID, manager: any V2OwnProfileManaging,
                avatars: (any V2ProfileAvatarPreparing)? = nil, wake: @escaping @Sendable () async -> Void = {},
                sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
                    try await Task.sleep(until: $0, clock: .continuous)
                }) {
        self.store = store; self.accountID = accountID; self.manager = manager; self.avatars = avatars; self.wake = wake
        self.sleepUntil = sleepUntil
    }
    public func pendingIntent() async throws -> V2ProfileIntent? { try await store.latestRecoverableProfileIntent(accountID: accountID) }
    /// The confirmed self-profile is an allowed local snapshot, not a display lease.
    /// Avatar bytes still require the existing presentation repository's authorization.
    public func localProfile() async throws -> V2ProfileView? {
        try Task.checkCancellation()
        let profile = try await store.ownProfileSnapshot(accountID: accountID)
        try Task.checkCancellation()
        return profile
    }
    public func currentProfile() async throws -> V2ProfileView {
        if let local = try await localProfile() { return local }
        return try await refreshProfile()
    }
    public func refreshProfile() async throws -> V2ProfileView {
        let profile = try await manager.currentProfile()
        try Task.checkCancellation()
        guard profile.userID == accountID else { throw V2OperationWorkError.accountMismatch }
        try await store.saveOwnProfileSnapshot(profile)
        // A late replica response cannot replace a newer confirmed snapshot.
        let latest = try await localProfile()
        return latest ?? profile
    }
    public func enqueue(expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, avatarUpload: V2ProfileAvatarUpload? = nil) async throws -> V2ProfileIntent {
        let intent = try await store.enqueueProfileIntent(accountID: accountID, expectedRevision: expectedRevision, patch: patch, avatarUpload: avatarUpload)
        await wake()
        return intent
    }
    public func resumeOrReapply(intentID: UUID) async throws -> V2ProfileIntent {
        guard let intent = try await store.profileIntent(id: intentID), intent.accountID == accountID else { throw V2OperationWorkError.accountMismatch }
        if let workID = intent.workID, let work = try await store.operationWork(id: workID), !work.execution.isTerminal {
            try await store.retryOperationWorkByUser(id: workID, now: Date())
            await wake()
            return intent
        }
        if intent.workID == nil, try await store.resumeProfilePreparation(id: intentID) {
            await wake()
            return intent
        }
        // Reapplication uses the highest confirmed durable revision. A late
        // replica response must not freeze a replacement against an older base.
        let latest = try await refreshProfile()
        try Task.checkCancellation()
        let replacement = try await enqueue(expectedRevision: latest.revision, patch: intent.patch, avatarUpload: intent.avatarUpload)
        try await store.discardProfileIntentSource(id: intentID)
        return replacement
    }
    public func discard(intentID: UUID) async throws {
        guard let intent = try await store.profileIntent(id: intentID), intent.accountID == accountID else { throw V2OperationWorkError.accountMismatch }
        try await store.discardProfileIntentSource(id: intentID)
    }
    public func observe(intentID: UUID) async -> AsyncThrowingStream<V2ProfileIntentStatus, Error> { await store.profileIntentUpdates(id: intentID) }
    public func schedule() async -> V2CommandRetrySchedule { await store.profilePreparationSchedule(accountID: accountID) }
    public func runPreparation() async throws {
        let schedule = await schedule()
        try await V2CommandRetryScheduler(schedule: schedule, flush: {
            do { _ = try await self.prepareNextIntent() }
            catch is CancellationError { throw CancellationError() }
            catch V2ProfilePreparationError.dependencyDeferred { }
            catch { throw error }
        }).run()
    }
    /// The caller owns scheduling. No network permit is held while awaiting the upload dependency.
    @discardableResult
    public func prepareNextIntent(now: Date = Date()) async throws -> Bool {
        guard !preparing else { return false }
        preparing = true; defer { preparing = false }
        guard let intent = try await store.firstUnfinishedProfileIntent(accountID: accountID), intent.workID == nil else { return false }
        if intent.deadline <= now {
            try await store.expireUnfrozenProfileIntent(id: intent.id)
            return true
        }
        let avatar: V2AvatarReference?
        if let source = intent.avatarUpload {
            do {
                guard let avatars else { throw V2OperationWorkError.dependencyUnavailable }
                let remaining = max(0, intent.deadline.timeIntervalSince(Date()))
                let deadline = ContinuousClock.now.advanced(by: .seconds(remaining))
                let waitUntilDeadline = sleepUntil
                avatar = try await withThrowingTaskGroup(of: V2AvatarReference.self) { group in
                    group.addTask { try await avatars.ensureReady(source) }
                    group.addTask {
                        try await waitUntilDeadline(deadline)
                        throw V2ProfilePreparationError.deadlineExpired
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try Task.checkCancellation()
                guard avatar?.mediaID == MediaID(uuid: source.id) else { throw V2OperationWorkError.identityConflict }
            } catch V2ProfilePreparationError.deadlineExpired {
                try await store.expireUnfrozenProfileIntent(id: intent.id)
                return true
            } catch {
                try await store.deferProfilePreparation(intent: intent, now: Date())
                if error is CancellationError { throw CancellationError() }
                throw V2ProfilePreparationError.dependencyDeferred
            }
        } else { avatar = nil }
        guard try await store.firstUnfinishedProfileIntent(accountID: accountID)?.id == intent.id else { return false }
        if intent.deadline <= Date() { try await store.expireUnfrozenProfileIntent(id: intent.id); return true }
        _ = try await store.freezeProfileIntent(id: intent.id, avatar: avatar, now: Date())
        return true
    }
    public func execute(_ claim: V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID == accountID, claim.work.identity.kind == .profileUpdate,
              let intent = try await store.profileIntent(forWorkID: claim.work.id) else { throw V2OperationWorkError.accountMismatch }
        let command = try GRDBV2LocalSyncStore.profileCommand(intent: intent)
        guard command.fingerprint == claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        do {
            switch claim.action {
            case .submit:
                let result = try await manager.patchProfile(command)
                try await store.completeProfileIntent(intent: intent, result: result)
            case .reconcile:
                let result = try await manager.recoverProfile(.init(actorUserID: accountID, operationID: command.operationID, fingerprint: command.fingerprint, action: intent.deadline > Date() ? .query : .closeIfAbsent))
                switch result {
                case .receipt(let receipt, let snapshot): try await store.completeProfileIntent(intent: intent, result: .init(receipt: receipt, currentSnapshot: snapshot))
                case .unresolved:
                    try await store.deferOperationWork(claim, until: Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt: claim.work.reconciliationRoundAttempts)), code: "PROFILE_UNRESOLVED", nextAction: intent.deadline > Date() ? .submit : .reconcile)
                case .fingerprintConflict:
                    try await store.deferOperationWork(claim, until: Date(), code: "PROFILE_FINGERPRINT_CONFLICT", scheduling: .needsAttention)
                }
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim, until: Date(), code: "PROFILE_INTERRUPTED")
            throw CancellationError()
        } catch {
            let now = Date()
            let clientError = error as? V2OwnProfileClientError
            let unavailable = clientError == .authorizationUnavailable || clientError == .authorizationDenied
            let httpFailure = error as? V2HTTPFailure
            let permanent = clientError == .authorizationDenied || clientError == .invalidResponse || clientError == .invalidRequest || clientError == .invalidEndpoint ||
                httpFailure.map { [.invalidEndpoint, .invalidResponse, .responseTooLarge].contains($0.kind) || [400, 404, 409, 413, 415, 422].contains($0.statusCode ?? 0) } == true || error is V2OperationWorkError
            let policy = V2NetworkWorkPolicy.commandRecovery
            let deadline = claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
            let next = policy.nextAttempt(now: now, startedAt: deadline.addingTimeInterval(-policy.totalBudget), attemptsCompleted: claim.work.reconciliationRoundAttempts,
                                          randomUnit: Double.random(in: 0...1), serverRetryNotBefore: httpFailure?.retryAfter)
            try await store.deferOperationWork(claim, until: max(next ?? now, httpFailure?.retryAfter ?? now), code: unavailable ? "PROFILE_AUTH_REQUIRED" : "PROFILE_CONFIRMATION_REQUIRED",
                scheduling: permanent || next == nil ? .needsAttention : .backingOff)
        }
    }
}

extension GRDBV2LocalSyncStore {
    func completeProfileIntent(intent: V2ProfileIntent, result: V2ProfileUpdateResult, now: Date = Date()) throws {
        let command = try Self.profileCommand(intent: intent)
        guard result.receipt.validates(actorUserID: intent.accountID, operationID: intent.operationID, fingerprint: command.fingerprint),
              result.currentSnapshot.map({ $0.userID == intent.accountID }) ?? true else { throw V2OperationWorkError.identityConflict }
        let state: V2OperationExecutionState
        switch result.receipt.outcome {
        case .committed(let revision, _):
            guard revision > intent.expectedRevision, result.currentSnapshot.map({ $0.revision >= revision }) ?? true else { throw V2OperationWorkError.invalidRecord }
            state = .committed
        case .rejected(.revisionConflict): state = .conflicted
        case .rejected: state = .rejected
        case .closed: state = .closed
        }
        let identity = try V2OperationIdentity(accountID: intent.accountID, scope: .account(intent.accountID), operation: .profileUpdate(intent.operationID))
        let outcome = try V2VerifiedOperationOutcome(identity: identity, fingerprint: command.fingerprint, state: state, receipt: result.receipt)
        try databasePool.write { db in
            try Self.completeOperationWork(outcome, now: now, db: db)
            if let snapshot = result.currentSnapshot { try Self.persistOwnProfileSnapshot(snapshot, db: db) }
            if state == .committed { try db.execute(sql: "UPDATE v2_profile_intents SET source_released=1 WHERE intent_id=?", arguments: [intent.id.uuidString]) }
        }
    }
    func deferProfilePreparation(intent: V2ProfileIntent, now: Date) throws {
        try databasePool.write { db in
            let attempts = try Int.fetchOne(db, sql: "SELECT preparation_attempts FROM v2_profile_intents WHERE intent_id=?", arguments: [intent.id.uuidString]) ?? 0
            let next = attempts >= 4 ? intent.deadline : min(intent.deadline, now.addingTimeInterval(pow(2, Double(attempts + 1))))
            try db.execute(sql: "UPDATE v2_profile_intents SET preparation_attempts=preparation_attempts+1,preparation_next_at=?,preparation_error='PROFILE_UPLOAD_PENDING' WHERE intent_id=? AND work_id IS NULL AND local_terminal IS NULL", arguments: [next.timeIntervalSince1970, intent.id.uuidString])
        }
    }
    func resumeProfilePreparation(id: UUID) throws -> Bool {
        try databasePool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_profile_intents WHERE intent_id=? AND work_id IS NULL AND local_terminal IS NULL)", arguments: [id.uuidString]) == true else { return false }
            try db.execute(sql: "UPDATE v2_profile_intents SET preparation_attempts=0,preparation_error=NULL,preparation_next_at=? WHERE intent_id=?", arguments: [Date().timeIntervalSince1970,id.uuidString])
            return true
        }
    }
    public func discardProfileIntentSource(id: UUID) throws {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT i.work_id,w.scheduling_state FROM v2_profile_intents i LEFT JOIN v2_operation_work w ON w.work_id=i.work_id WHERE i.intent_id=?", arguments: [id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let workID: String? = row["work_id"]
            guard workID == nil || row["scheduling_state"] as String? == "finished" else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql: "UPDATE v2_profile_intents SET source_released=1,local_terminal=CASE WHEN work_id IS NULL THEN 'cancelledLocally' ELSE local_terminal END,preparation_next_at=NULL WHERE intent_id=?", arguments: [id.uuidString])
        }
    }
    func expireUnfrozenProfileIntent(id: UUID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_profile_intents SET local_terminal='expiredUnsubmitted',preparation_next_at=NULL WHERE intent_id=? AND work_id IS NULL AND local_terminal IS NULL", arguments: [id.uuidString])
        }
    }
    public func profilePreparationSchedule(accountID: UserID) -> V2CommandRetrySchedule {
        let pool = databasePool
        let query = """
            SELECT MIN(i.preparation_next_at) FROM v2_profile_intents i
            WHERE i.account_id=? AND i.work_id IS NULL AND i.local_terminal IS NULL
                AND NOT EXISTS(SELECT 1 FROM v2_profile_intents predecessor LEFT JOIN v2_operation_work w ON w.work_id=predecessor.work_id
                    WHERE predecessor.account_id=i.account_id AND predecessor.local_sequence<i.local_sequence
                    AND predecessor.local_terminal IS NULL AND (predecessor.work_id IS NULL OR w.scheduling_state<>'finished'))
            """
        return .init(nextAttemptAt: {
            try await pool.read { try Double.fetchOne($0, sql: query, arguments: [accountID.rawValue]).map(Date.init(timeIntervalSince1970:)) }
        }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    do {
                        let observation = ValueObservation.tracking { try Double.fetchOne($0, sql: query, arguments: [accountID.rawValue]) }.removeDuplicates()
                        for try await _ in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(()) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }
}
