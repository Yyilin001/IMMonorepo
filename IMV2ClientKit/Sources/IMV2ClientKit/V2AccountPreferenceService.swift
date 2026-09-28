import Foundation
import GRDB
import IMV2Core

public actor V2AccountPreferenceService {
    private let activationID:UUID
    private var confirmationEnds:[UUID:ContinuousClock.Instant]=[:]
    private var preparationEnds:[UUID:ContinuousClock.Instant]=[:]
    private var preparing=false
    private let accountID:UserID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2AccountPreferenceClient
    private var deadlines:[UUID:ContinuousClock.Instant]=[:]
    public init(accountID:UserID,activationID:UUID=UUID(),store:GRDBV2LocalSyncStore,client:any V2AccountPreferenceClient) { self.activationID=activationID;self.accountID=accountID;self.store=store;self.client=client }
    public func updates() -> AsyncThrowingStream<[V2AccountPreferencePending],any Error> { store.accountPreferenceUpdates() }
    public func cachedBaseline(kind:V2OperationKind) async throws -> V2AccountPreferenceSnapshot? { try await store.cachedAccountPreference(kind:kind) }
    public func refreshAuthority() async {
        await withTaskGroup(of:Void.self) { group in
            for kind:V2OperationKind in [.strangerMessagePreference,.userAddPreference,.readReceiptPreference,.liveActivityPreference] {
                group.addTask { _ = try? await self.baseline(kind:kind) }
            }
        }
    }
    public func baseline(kind:V2OperationKind) async throws -> V2AccountPreferenceSnapshot {
        let client=self.client
        let snapshot=try await V2HTTPRequestDeadline.run(until:.now.advanced(by:.seconds(15)),service:"accountAPI") { try await client.baseline(kind:kind) }
        guard snapshot.ownerUserID==accountID,snapshot.value.kind==kind else { throw V2AccountPreferenceValidationError.invalidSnapshot }
        try await store.saveAccountPreferenceAuthority(snapshot);return snapshot
    }
    public func draftUpdates() -> AsyncThrowingStream<[V2AccountPreferenceDraft],any Error> { store.accountPreferenceDraftUpdates() }
    @discardableResult public func enqueue(value:V2AccountPreferenceValue) async throws -> UUID {
        let patch:V2AccountPreferencePatch
        switch value { case .strangerMessage(let value):patch = .strangerMessage(value);case .userAdd(let value):patch = .userAdd(value);case .readReceipt(let direct,let group):patch = .readReceipt(direct:direct,group:group);case .liveActivity(let online,let typing):patch = .liveActivity(online:online,typing:typing) }
        return try await enqueue(patch:patch)
    }
    @discardableResult public func enqueue(patch:V2AccountPreferencePatch) async throws -> UUID {
        try Task.checkCancellation()
        let id=UUID();confirmationEnds[id] = .now.advanced(by:.seconds(120))
        do { return try await store.enqueueAccountPreferenceDraft(accountID:accountID,patch:patch,activationID:activationID,id:id) }
        catch { confirmationEnds.removeValue(forKey:id);throw error }
    }
    public func discardDraft(id:UUID) async throws {
        try await store.discardAccountPreferenceDraft(id:id,accountID:accountID);confirmationEnds.removeValue(forKey:id);preparationEnds.removeValue(forKey:id)
    }
    public func reconfirmDraft(id:UUID) async throws {
        let replacement=UUID();confirmationEnds[replacement] = .now.advanced(by:.seconds(120))
        do { _ = try await store.reconfirmAccountPreferenceDraft(id:id,accountID:accountID,activationID:activationID,replacement:replacement) }
        catch { confirmationEnds.removeValue(forKey:replacement);throw error }
    }
    public func runPreparation() async throws {
        _ = try? await baseline(kind:.liveActivityPreference)
        _ = try? await baseline(kind:.readReceiptPreference)
        let schedule=await store.accountPreferencePreparationSchedule()
        try await V2CommandRetryScheduler(schedule:schedule,flush:{ _ = try await self.prepareNext() }).run()
    }
    @discardableResult public func prepareNext() async throws -> Bool {
        guard !preparing else { return false };preparing=true;defer { preparing=false }
        guard let draft=try await store.beginAccountPreferenceDraft() else { return false }
        guard draft.activationID==activationID,let confirmationEnd=confirmationEnds[draft.id],confirmationEnd > .now else {
            try await store.deferAccountPreferenceDraft(id:draft.id,until:Date(),paused:true);return true
        }
        let roundEnd=preparationEnds[draft.id] ?? min(confirmationEnd,.now.advanced(by:.seconds(60)));preparationEnds[draft.id]=roundEnd
        guard roundEnd > .now else { try await store.deferAccountPreferenceDraft(id:draft.id,until:Date(),paused:true);return true }
        do {
            let client=self.client
            let snapshot=try await V2NetworkWorkScope.$context.withValue(.init(service:"accountAPI",priority:.recovery,isRetry:draft.attempts>1)) {
                try await V2HTTPRequestDeadline.run(until:min(roundEnd,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await client.baseline(kind:draft.patch.kind) }
            }
            try Task.checkCancellation()
            guard snapshot.ownerUserID==accountID,snapshot.value.kind==draft.patch.kind,roundEnd > .now else { throw V2AccountPreferenceValidationError.invalidSnapshot }
            try await store.saveAccountPreferenceAuthority(snapshot)
            let value=try draft.patch.applying(to:snapshot),reference:V2OperationReference
            switch value { case .strangerMessage:reference = .strangerMessagePreference(.init(uuid:draft.id));case .userAdd:reference = .userAddPreference(.init(uuid:draft.id));case .readReceipt:reference = .readReceiptPreference(.init(uuid:draft.id));case .liveActivity:reference = .liveActivityPreference(.init(uuid:draft.id)) }
            let command=try V2AccountPreferenceCommand(identity:.init(accountID:accountID,scope:.account(accountID),operation:reference),value:value,expectedRevision:snapshot.revision,firstSubmissionDeadlineMilliseconds:UInt64(draft.deadline.timeIntervalSince1970*1000))
            let workID=try await store.freezeAccountPreferenceDraft(draft,command:command);deadlines[workID]=confirmationEnd;confirmationEnds.removeValue(forKey:draft.id);preparationEnds.removeValue(forKey:draft.id)
        } catch is CancellationError { try await store.deferAccountPreferenceDraft(id:draft.id,until:Date(),paused:false);throw CancellationError() }
        catch {
            let now=Date(),failure=error as? V2HTTPFailure,policy=V2NetworkWorkPolicy.commandRecovery
            let retry=policy.nextAttempt(now:now,startedAt:draft.deadline.addingTimeInterval(-120),attemptsCompleted:draft.attempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:failure?.retryAfter)
            try await store.deferAccountPreferenceDraft(id:draft.id,until:max(retry ?? now,failure?.retryAfter ?? now),paused:retry == nil || error is V2AccountPreferenceValidationError)
            if error is DatabaseError { throw error }
        }
        return true
    }
    @discardableResult public func enqueue(value:V2AccountPreferenceValue,snapshot:V2AccountPreferenceSnapshot,confirmedAt:Date=Date(),deadline:ContinuousClock.Instant=ContinuousClock.now.advanced(by:.seconds(120))) async throws -> UUID {
        try Task.checkCancellation()
        guard snapshot.ownerUserID==accountID,snapshot.value.kind==value.kind else { throw V2OperationWorkError.accountMismatch }
        let reference:V2OperationReference
        switch value {
        case .strangerMessage:reference = .strangerMessagePreference(.init(uuid:UUID()))
        case .userAdd:reference = .userAddPreference(.init(uuid:UUID()))
        case .readReceipt:reference = .readReceiptPreference(.init(uuid:UUID()))
        case .liveActivity:reference = .liveActivityPreference(.init(uuid:UUID()))
        }
        let identity=try V2OperationIdentity(accountID:accountID,scope:.account(accountID),operation:reference)
        let timestamp=confirmedAt.timeIntervalSince1970*1000
        guard timestamp.isFinite,timestamp>0,timestamp<Double(Int64.max-120_000) else { throw V2OperationWorkError.invalidRecord }
        let command=try V2AccountPreferenceCommand(identity:identity,value:value,expectedRevision:snapshot.revision,firstSubmissionDeadlineMilliseconds:UInt64(timestamp)+120_000)
        let id=try await store.enqueueAccountPreference(command);deadlines[id]=deadline;return id
    }
    public func resumeConfirmation(workID:UUID) async throws {
        guard let work=try await store.operationWork(id:workID),work.identity.accountID==accountID,[.strangerMessagePreference,.userAddPreference,.readReceiptPreference,.liveActivityPreference].contains(work.identity.kind) else { throw V2OperationWorkError.accountMismatch }
        try await store.retryOperationWorkByUser(id:workID,now:Date())
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,[.strangerMessagePreference,.userAddPreference,.readReceiptPreference,.liveActivityPreference].contains(claim.work.identity.kind) else { throw V2OperationWorkError.accountMismatch }
        let command=try await store.accountPreferenceCommand(workID:claim.work.id)
        guard command.identity==claim.work.identity,try command.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        let remaining=max(0,Double(command.firstSubmissionDeadlineMilliseconds)/1000-Date().timeIntervalSince1970)
        let local=deadlines[claim.work.id] ?? ContinuousClock.now.advanced(by:.seconds(min(remaining,120)))
        deadlines[claim.work.id]=local
        do {
            let client=self.client
            let result:V2AccountPreferenceRecoveryResult
            if claim.action == .submit,local > .now {
                result=try await V2HTTPRequestDeadline.run(until:min(local,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await client.submit(command) }
            } else { result=try await client.recover(command,action:local <= .now ? .closeIfAbsent : .query) }
            switch result {
            case .receipt(let receipt):
                guard receipt.validates(command:command) else { throw V2OperationWorkError.identityConflict }
                let state:V2OperationExecutionState
                switch receipt.outcome { case .applied:state = .committed;case .closed:state = .closed;case .rejected(.revisionConflict):state = .conflicted;case .rejected:state = .rejected }
                try await store.completeAccountPreference(command,receipt:receipt,state:state);deadlines.removeValue(forKey:claim.work.id)
            case .fingerprintConflict:try await store.deferOperationWork(claim,until:Date(),code:"ACCOUNT_PREFERENCE_IDENTITY_CONFLICT",scheduling:.needsAttention)
            case .unresolved:try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"ACCOUNT_PREFERENCE_UNRESOLVED",nextAction:local > .now ? .submit : .reconcile)
            case .deferred(let hint):
                guard hint.validates(identity:command.identity,fingerprint:try command.fingerprint) else { throw V2OperationWorkError.identityConflict }
                try await deferFailure(claim,floor:Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1000),malformed:false)
            }
        } catch is CancellationError { try await store.deferOperationWork(claim,until:Date(),code:"ACCOUNT_PREFERENCE_INTERRUPTED");throw CancellationError() }
        catch { let failure=error as? V2HTTPFailure;try await deferFailure(claim,floor:failure?.retryAfter,malformed:error is V2OperationWorkError || error is V2AccountPreferenceValidationError);if error is DatabaseError { throw error } }
    }
    private func deferFailure(_ claim:V2OperationWorkClaim,floor:Date?,malformed:Bool) async throws {
        let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,end=claim.work.reconciliationRoundDeadline ?? Date().addingTimeInterval(V2NetworkWorkPolicy.commandRecovery.totalBudget)
        let retry=policy.nextAttempt(now:now,startedAt:end.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
        try await store.deferOperationWork(claim,until:max(retry ?? now,floor ?? now),code:"ACCOUNT_PREFERENCE_CONFIRMATION_REQUIRED",scheduling:malformed || retry == nil ? .needsAttention : .backingOff)
    }
}
