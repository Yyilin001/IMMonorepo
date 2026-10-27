import Foundation
import GRDB
import IMV2Core

private enum V2ProfilePreparationError: Error { case dependencyDeferred, deadlineExpired }
private struct V2ProfilePreparationHead: Equatable, Sendable { let id: String; let due: Double }

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
    public func enqueueImportedAvatar(expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, source: V2ProfileAvatarImport) async throws -> V2ProfileIntent {
        let intent = try await store.enqueueProfileImportIntent(accountID: accountID, expectedRevision: expectedRevision, patch: patch, source: source)
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
        let replacement: V2ProfileIntent
        if let source = intent.avatarImport {
            let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: source.request.source,
                targetUsage: .userAvatar, targetMediaID: .init(uuid: UUID()))
            replacement = try await store.enqueueProfileImportIntent(accountID: accountID, expectedRevision: latest.revision,
                patch: intent.patch, source: .init(id: UUID(), request: request))
        } else {
            var upload = intent.avatarUpload
            if let source = upload, let job = try await store.resourceTransfer(id: source.id) {
                let now = Date()
                let renew: Bool
                switch job.stage {
                case .cancelled, .rejected, .expired: renew = true
                case .ready: renew = job.cancellationRequested || job.session?.bindableUntil.map { $0 <= now } != false
                default: renew = job.cancellationRequested || job.session.map { $0.expiresAt <= now } == true
                }
                if renew {
                    // A new, known-unsubmitted profile operation may need new
                    // upload admission. Keep the original asset: enqueue binds
                    // its replacement consumer before the old one is released.
                    upload = try .init(id: UUID(), localAssetID: source.localAssetID,
                        displayName: source.displayName, contentType: source.contentType, byteCount: source.byteCount)
                }
            }
            replacement = try await store.enqueueProfileIntent(accountID: accountID, expectedRevision: latest.revision, patch: intent.patch, avatarUpload: upload, adoptingFromIntentID: intentID)
        }
        await wake()
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
        if let source = intent.avatarImport {
            guard let job = try await store.resourceImport(id: source.id), job.request == source.request,
                  !job.cancellationRequested, job.attempts < 5,
                  job.status.map({ ![.cancelled,.failed].contains($0.state) }) ?? true else {
                try await store.failUnfrozenProfilePreparation(id: intent.id)
                return true
            }
            guard let status = job.status, status.state == .ready else {
                try await store.deferProfilePreparation(intent: intent, now: now)
                return false
            }
            guard let until = status.bindableUntilUnixMilliseconds, Double(until) / 1000 > now.timeIntervalSince1970 else {
                try await store.expireUnfrozenProfileIntent(id: intent.id)
                return true
            }
            avatar = .init(mediaID: source.request.targetMediaID)
        } else if let source = intent.avatarUpload {
            if let job = try await store.resourceTransfer(id: source.id),
               job.cancellationRequested || [.cancelled, .rejected, .expired].contains(job.stage) {
                // A terminal transfer cannot satisfy this unsubmitted change.
                // Retain its draft/source for explicit reapplication instead of
                // deferring the same impossible dependency until the deadline.
                try await store.failUnfrozenProfilePreparation(id: intent.id)
                return true
            }
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
        do { _ = try await store.freezeProfileIntent(id: intent.id, avatar: avatar, now: Date()) }
        catch V2ResourceJournalError.bindingExpired {
            try await store.expireUnfrozenProfileIntent(id: intent.id)
        } catch V2OperationWorkError.dependencyUnavailable {
            try await store.deferProfilePreparation(intent: intent, now: Date())
            return false
        }
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
            if state == .committed {
                if let source = intent.avatarUpload { try Self.releaseLocalResourceAssetConsumer(source.localAssetID, consumer: .profileIntent(intent.id), db: db) }
                try db.execute(sql: "UPDATE v2_profile_intents SET source_released=1 WHERE intent_id=?", arguments: [intent.id.uuidString])
            }
        }
    }
    func deferProfilePreparation(intent: V2ProfileIntent, now: Date) throws {
        try databasePool.write { db in
            let attempts = try Int.fetchOne(db, sql: "SELECT preparation_attempts FROM v2_profile_intents WHERE intent_id=?", arguments: [intent.id.uuidString]) ?? 0
            let next = attempts >= 4 ? intent.deadline : min(intent.deadline, now.addingTimeInterval(pow(2, Double(attempts + 1))))
            try db.execute(sql: "UPDATE v2_profile_intents SET preparation_attempts=preparation_attempts+1,preparation_next_at=?,preparation_error='PROFILE_AVATAR_PENDING' WHERE intent_id=? AND work_id IS NULL AND local_terminal IS NULL", arguments: [next.timeIntervalSince1970, intent.id.uuidString])
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
        try databasePool.write { try Self.discardProfileIntentSource(id: id, db: $0) }
    }
    static func discardProfileIntentSource(id: UUID, db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT i.work_id,i.local_asset_id,i.upload_job_id,i.import_job_id,w.scheduling_state FROM v2_profile_intents i LEFT JOIN v2_operation_work w ON w.work_id=i.work_id WHERE i.intent_id=?", arguments: [id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
        let workID: String? = row["work_id"]
        guard workID == nil || row["scheduling_state"] as String? == "finished" else { throw V2OperationWorkError.invalidTransition }
        if let raw: String = row["local_asset_id"], let assetID = UUID(uuidString: raw) {
            try Self.releaseLocalResourceAssetConsumer(.init(assetID), consumer: .profileIntent(id), db: db)
        }
        try db.execute(sql: "UPDATE v2_profile_intents SET source_released=1,local_terminal=CASE WHEN work_id IS NULL THEN 'cancelledLocally' ELSE local_terminal END,preparation_next_at=NULL WHERE intent_id=?", arguments: [id.uuidString])
        if let raw: String = row["upload_job_id"], let job = UUID(uuidString: raw) { try Self.requestUnboundAvatarUploadCancellation(job, db: db) }
        if let raw: String = row["import_job_id"], let job = UUID(uuidString: raw) { try Self.requestUnboundAvatarImportCancellation(job, db: db) }
    }
    func failUnfrozenProfilePreparation(id: UUID) throws {
        try databasePool.write { try $0.execute(sql: "UPDATE v2_profile_intents SET local_terminal='preparationFailed',preparation_next_at=NULL WHERE intent_id=? AND work_id IS NULL AND local_terminal IS NULL", arguments: [id.uuidString]) }
    }
    func expireUnfrozenProfileIntent(id: UUID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_profile_intents SET local_terminal='expiredUnsubmitted',preparation_next_at=NULL WHERE intent_id=? AND work_id IS NULL AND local_terminal IS NULL", arguments: [id.uuidString])
        }
    }
    public func profilePreparationSchedule(accountID: UserID) -> V2CommandRetrySchedule {
        let pool = databasePool
        let query = """
            SELECT i.intent_id,CASE WHEN r.stage IN ('ready','cancelled','failed') OR r.attempts>=5 THEN 0 ELSE i.preparation_next_at END AS preparation_next_at
            FROM v2_profile_intents i LEFT JOIN v2_resource_import_jobs r ON r.job_id=i.import_job_id
            WHERE i.account_id=? AND i.work_id IS NULL AND i.local_terminal IS NULL AND i.preparation_next_at IS NOT NULL
                AND NOT EXISTS(SELECT 1 FROM v2_profile_intents predecessor LEFT JOIN v2_operation_work w ON w.work_id=predecessor.work_id
                    WHERE predecessor.account_id=i.account_id AND predecessor.local_sequence<i.local_sequence
                    AND predecessor.local_terminal IS NULL AND (predecessor.work_id IS NULL OR w.scheduling_state<>'finished'))
            ORDER BY i.preparation_next_at,i.local_sequence LIMIT 1
            """
        return .init(nextAttemptAt: {
            try await pool.read { try Row.fetchOne($0, sql: query, arguments: [accountID.rawValue]).map { Date(timeIntervalSince1970: $0["preparation_next_at"]) } }
        }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    do {
                        let observation = ValueObservation.tracking { db -> V2ProfilePreparationHead? in
                            try Row.fetchOne(db, sql: query, arguments: [accountID.rawValue]).map { .init(id: $0["intent_id"], due: $0["preparation_next_at"]) }
                        }.removeDuplicates()
                        for try await _ in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(()) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }
}
