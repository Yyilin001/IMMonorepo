import Foundation
import GRDB
import IMV2Core

/// Preparation is account owned. A local confirmation authorizes at most 120 seconds;
/// only the server admission becomes part of an immutable execution command.
public actor V2MemberAdministrationOperationService {
    private let accountID:UserID
    private let activationID:UUID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2MemberAdministrationOperationClient
    private var confirmations:[String:ContinuousClock.Instant]=[:]
    private var preparationEnds:[String:ContinuousClock.Instant]=[:]
    private let confirmationClock:@Sendable () -> ContinuousClock.Instant
    private var preparing=false
    public init(accountID:UserID,activationID:UUID,store:GRDBV2LocalSyncStore,client:any V2MemberAdministrationOperationClient) {
        self.accountID=accountID;self.activationID=activationID;self.store=store;self.client=client;self.confirmationClock={ .now }
    }
    init(accountID:UserID,activationID:UUID,store:GRDBV2LocalSyncStore,client:any V2MemberAdministrationOperationClient,confirmationClock:@escaping @Sendable () -> ContinuousClock.Instant) {
        self.accountID=accountID;self.activationID=activationID;self.store=store;self.client=client;self.confirmationClock=confirmationClock
    }
    @discardableResult public func enqueue(roomID:RoomID,targetUserID:UserID,action:V2MemberAdministrationAction,reasonCode:V2ModerationReasonCode,expectedMembershipRevision:UInt64) async throws -> UUID {
        try Task.checkCancellation()
        let now=Date(),deadline=confirmationClock().advanced(by:.seconds(120))
        let intent=try V2MemberAdministrationIntent(roomID:roomID,actorUserID:accountID,operationID:.init(uuid:UUID()),targetUserID:targetUserID,action:action,reasonCode:reasonCode,expectedMembershipRevision:expectedMembershipRevision,confirmedUntilMilliseconds:UInt64((now.timeIntervalSince1970+120)*1_000))
        let identity=try intent.identity.storageKey
        confirmations[identity]=deadline
        do { return try await store.enqueueMemberAdministration(intent,activationID:activationID,now:now) }
        catch { confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity);throw error }
    }
    public func updates(roomID:RoomID) -> AsyncThrowingStream<[V2MemberAdministrationPending],any Error> { store.memberAdministrationUpdates(roomID:roomID) }
    public func discardDraft(id:UUID) async throws {
        let pending=try await store.memberAdministrationPending(id:id)
        try await store.discardMemberAdministrationDraft(id:id,accountID:accountID)
        confirmations.removeValue(forKey:try pending.intent.identity.storageKey)
        preparationEnds.removeValue(forKey:try pending.intent.identity.storageKey)
    }
    /// Resumes only the original frozen identity; it never obtains a replacement admission.
    public func resumeConfirmation(id:UUID) async throws {
        let pending=try await store.memberAdministrationPending(id:id)
        guard pending.intent.actorUserID==accountID,let work=pending.work else { throw V2MemberAdministrationAdmissionError.confirmationRequired }
        try await store.retryOperationWorkByUser(id:work.id,now:Date())
    }
    /// A new click replaces only an unfrozen draft and preserves its server backpressure floor.
    public func reconfirmDraft(id:UUID,expectedMembershipRevision:UInt64) async throws -> UUID {
        try Task.checkCancellation()
        let previous=try await store.memberAdministrationPending(id:id),now=Date()
        guard previous.intent.actorUserID==accountID else { throw V2OperationWorkError.accountMismatch }
        if case .mute(let until)=previous.intent.action,Double(until)/1000<=now.timeIntervalSince1970 { throw V2MemberAdministrationAdmissionError.confirmationRequired }
        let intent=try V2MemberAdministrationIntent(roomID:previous.intent.roomID,actorUserID:accountID,operationID:.init(uuid:UUID()),targetUserID:previous.intent.targetUserID,action:previous.intent.action,reasonCode:previous.intent.reasonCode,expectedMembershipRevision:expectedMembershipRevision,confirmedUntilMilliseconds:UInt64((now.timeIntervalSince1970+120)*1000))
        let key=try intent.identity.storageKey
        confirmations[key] = confirmationClock().advanced(by:.seconds(120))
        do {
            let replacement=try await store.replaceMemberAdministrationDraft(id:id,intent:intent,activationID:activationID,now:now)
            confirmations.removeValue(forKey:try previous.intent.identity.storageKey)
            preparationEnds.removeValue(forKey:try previous.intent.identity.storageKey)
            return replacement
        } catch { confirmations.removeValue(forKey:key);throw error }
    }
    public func runPreparation() async throws {
        let schedule=await store.memberAdministrationPreparationSchedule()
        try await V2CommandRetryScheduler(schedule:schedule,flush:{ _ = try await self.prepareNextIntent() }).run()
    }
    @discardableResult public func prepareNextIntent(now:Date=Date()) async throws -> Bool {
        guard !preparing else { return false };preparing=true;defer { preparing=false }
        guard let pending=try await store.beginMemberAdministrationPreparation(now:now) else { return false }
        let identity=try pending.intent.identity.storageKey
        guard pending.intent.actorUserID==accountID else { throw V2OperationWorkError.accountMismatch }
        guard pending.confirmationActivationID==activationID,let deadline=confirmations[identity],deadline > confirmationClock() else {
            confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity)
            try await store.pauseMemberAdministrationPreparation(id:pending.id,code:"CONFIRMATION_REQUIRED");return true
        }
        let roundEnd=preparationEnds[identity] ?? min(deadline,confirmationClock().advanced(by:.seconds(60)))
        preparationEnds[identity]=roundEnd
        guard roundEnd > confirmationClock() else {
            try await store.pauseMemberAdministrationPreparation(id:pending.id,code:"CONFIRMATION_REQUIRED");confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity);return true
        }
        do {
            let client=self.client,intent=pending.intent
            let result=try await V2NetworkWorkScope.$context.withValue(.init(service:"accountAPI",priority:.recovery,isRetry:pending.preparationAttempts>1)) {
                try await V2HTTPRequestDeadline.run(until:min(roundEnd,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await client.admit(intent) }
            }
            try Task.checkCancellation()
            guard roundEnd > confirmationClock() else { throw V2MemberAdministrationAdmissionError.confirmationRequired }
            switch result {
            case .admitted(let admission):
                _ = try await store.freezeMemberAdministration(id:pending.id,admission:admission)
                confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity)
            case .currentUnavailable,.fingerprintConflict:
                try await store.pauseMemberAdministrationPreparation(id:pending.id,code:"ADMISSION_CONFIRMATION_REQUIRED")
                confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity)
            }
            return true
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure=error as? V2HTTPFailure,now=Date()
            let paused=roundEnd <= confirmationClock() || pending.preparationAttempts>=5 || error is V2MemberAdministrationAdmissionError || error is DatabaseError || error is V2MemberAdministrationValidationError
            let retry=max(now.addingTimeInterval(min(8,pow(2,Double(pending.preparationAttempts)))),failure?.retryAfter ?? now)
            let withinWindow=retry.timeIntervalSince1970*1_000<Double(pending.intent.confirmedUntilMilliseconds)
            try await store.pauseMemberAdministrationPreparation(id:pending.id,until:retry,code:"ADMISSION_CONFIRMATION_REQUIRED",paused:paused || !withinWindow)
            if paused || !withinWindow { confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity) }
            if error is DatabaseError { throw error };return false
        }
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,[V2OperationKind.memberMute,.moderatedMemberRemoval].contains(claim.work.identity.kind) else { throw V2OperationWorkError.accountMismatch }
        let command=try await store.memberAdministrationCommand(workID:claim.work.id)
        guard try command.identity==claim.work.identity,try command.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        do {
            let open=Date().timeIntervalSince1970*1_000<Double(command.admission.expiresAtMilliseconds)
            let result:V2MemberAdministrationRecoveryResult
            if claim.action == .submit && open {
                let remaining=max(0,Double(command.admission.expiresAtMilliseconds)/1000-Date().timeIntervalSince1970)
                let client=self.client
                result=try await V2HTTPRequestDeadline.run(until:.now.advanced(by:.seconds(min(15,remaining))),service:"accountAPI",certainty:.outcomeUnknown) { try await client.submit(command) }
            } else { result=try await client.recover(command,action:open ? .query:.closeIfAbsent) }
            switch result {
            case .receipt(let receipt):try await store.completeMemberAdministration(receipt,command:command)
            case .fingerprintConflict:try await store.deferOperationWork(claim,until:Date(),code:"ADMINISTRATION_FINGERPRINT_CONFLICT",scheduling:.needsAttention)
            case .unresolved:try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"ADMINISTRATION_UNRESOLVED",nextAction:open ? .submit:.reconcile)
            case .deferred(let hint):
                guard hint.validates(identity:claim.work.identity,fingerprint:claim.work.fingerprint) else { throw V2OperationWorkError.identityConflict }
                try await deferFailure(claim,floor:Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1_000),malformed:false)
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"ADMINISTRATION_INTERRUPTED");throw CancellationError()
        } catch {
            try await deferFailure(claim,floor:(error as? V2HTTPFailure)?.retryAfter,malformed:error is DatabaseError || error is V2OperationWorkError || error is V2MemberAdministrationValidationError)
            if error is DatabaseError { throw error }
        }
    }
    private func deferFailure(_ claim:V2OperationWorkClaim,floor:Date?,malformed:Bool) async throws {
        let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
        let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
        try await store.deferOperationWork(claim,until:max(retry ?? now,floor ?? now),code:"ADMINISTRATION_CONFIRMATION_REQUIRED",scheduling:malformed || retry == nil ? .needsAttention:.backingOff)
    }
}
