import Foundation
import GRDB
import IMV2Core

/// Preparation is account owned. A local confirmation authorizes at most 120 seconds;
/// only the server admission becomes part of an immutable execution command.
public actor V2GroupCapabilityOperationService {
    private let accountID:UserID
    private let activationID:UUID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2GroupCapabilityOperationClient
    private var confirmations:[String:ContinuousClock.Instant]=[:]
    private var preparationEnds:[String:ContinuousClock.Instant]=[:]
    private let confirmationClock:@Sendable () -> ContinuousClock.Instant
    private var preparing=false
    public init(accountID:UserID,activationID:UUID,store:GRDBV2LocalSyncStore,client:any V2GroupCapabilityOperationClient) {
        self.accountID=accountID;self.activationID=activationID;self.store=store;self.client=client;self.confirmationClock={ .now }
    }
    init(accountID:UserID,activationID:UUID,store:GRDBV2LocalSyncStore,client:any V2GroupCapabilityOperationClient,confirmationClock:@escaping @Sendable () -> ContinuousClock.Instant) {
        self.accountID=accountID;self.activationID=activationID;self.store=store;self.client=client;self.confirmationClock=confirmationClock
    }
    public nonisolated func confirmationWindow(roomID:RoomID,action:V2GroupCapabilityAction) throws -> V2GroupCapabilityConfirmationWindow {
        try .init(accountID:accountID,roomID:roomID,action:action,activationID:activationID)
    }
    public func pinBaseline(roomID:RoomID,messageID:MessageID) async throws -> V2PinnedMessageBaseline {
        let client=self.client
        return try await V2HTTPRequestDeadline.run(until:.now.advanced(by:.seconds(15)),service:"accountAPI") {
            try await client.pinBaseline(roomID:roomID,messageID:messageID)
        }
    }
    @discardableResult public func enqueue(confirmation:V2GroupCapabilityConfirmationWindow) async throws -> UUID {
        try Task.checkCancellation()
        guard confirmation.intent.identity.accountID==accountID,
            confirmation.validates(activationID:activationID,now:confirmationClock()) else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
        let intent=confirmation.intent,identity=intent.identity.storageKey
        confirmations[identity]=confirmation.deadline
        do { return try await store.enqueueGroupCapability(intent,activationID:activationID) }
        catch { confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity);throw error }
    }
    public func updates(roomID:RoomID) -> AsyncThrowingStream<[V2GroupCapabilityPending],any Error> { store.groupCapabilityUpdates(roomID:roomID) }
    public func discardDraft(id:UUID) async throws {
        let pending=try await store.groupCapabilityPending(id:id)
        try await store.discardGroupCapabilityDraft(id:id,accountID:accountID)
        confirmations.removeValue(forKey:pending.intent.identity.storageKey)
        preparationEnds.removeValue(forKey:pending.intent.identity.storageKey)
    }
    /// Resumes only the original frozen identity; it never obtains a replacement admission.
    public func resumeConfirmation(id:UUID) async throws {
        let pending=try await store.groupCapabilityPending(id:id)
        guard pending.intent.identity.accountID==accountID,let work=pending.work else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
        try await store.retryOperationWorkByUser(id:work.id,now:Date())
    }
    /// A new click replaces only an unfrozen draft and preserves its server backpressure floor.
    public func reconfirmDraft(id:UUID,confirmation:V2GroupCapabilityConfirmationWindow) async throws -> UUID {
        try Task.checkCancellation()
        let previous=try await store.groupCapabilityPending(id:id)
        guard previous.intent.identity.accountID==accountID,previous.intent.roomID==confirmation.intent.roomID,
            confirmation.intent.identity.accountID==accountID,
            confirmation.validates(activationID:activationID,now:confirmationClock()) else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
        let intent=confirmation.intent
        let key=intent.identity.storageKey
        confirmations[key]=confirmation.deadline
        do {
            let replacement=try await store.replaceGroupCapabilityDraft(id:id,intent:intent,activationID:activationID,now:Date())
            confirmations.removeValue(forKey:previous.intent.identity.storageKey);preparationEnds.removeValue(forKey:previous.intent.identity.storageKey)
            return replacement
        } catch { confirmations.removeValue(forKey:key);throw error }
    }
    public func runPreparation() async throws {
        let schedule=await store.groupCapabilityPreparationSchedule()
        try await V2CommandRetryScheduler(schedule:schedule,flush:{ _ = try await self.prepareNextIntent() }).run()
    }
    @discardableResult public func prepareNextIntent(now:Date=Date()) async throws -> Bool {
        guard !preparing else { return false };preparing=true;defer { preparing=false }
        guard let pending=try await store.beginGroupCapabilityPreparation(now:now) else { return false }
        let identity=pending.intent.identity.storageKey
        guard pending.intent.identity.accountID==accountID else { throw V2OperationWorkError.accountMismatch }
        guard pending.confirmationActivationID==activationID,let deadline=confirmations[identity],deadline > confirmationClock() else {
            confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity)
            try await store.pauseGroupCapabilityPreparation(id:pending.id,code:"CONFIRMATION_REQUIRED");return true
        }
        let roundEnd=preparationEnds[identity] ?? min(deadline,confirmationClock().advanced(by:.seconds(60)))
        preparationEnds[identity]=roundEnd
        guard roundEnd > confirmationClock() else {
            try await store.pauseGroupCapabilityPreparation(id:pending.id,code:"CONFIRMATION_REQUIRED");confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity);return true
        }
        do {
            let client=self.client,intent=pending.intent
            let result=try await V2NetworkWorkScope.$context.withValue(.init(service:"accountAPI",priority:.recovery,isRetry:pending.preparationAttempts>1)) {
                try await V2HTTPRequestDeadline.run(until:min(roundEnd,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await client.admit(intent) }
            }
            try Task.checkCancellation()
            guard roundEnd > confirmationClock() else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
            switch result {
            case .admitted(let admission):
                _ = try await store.freezeGroupCapability(id:pending.id,admission:admission)
                confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity)
            case .currentUnavailable,.fingerprintConflict:
                try await store.pauseGroupCapabilityPreparation(id:pending.id,code:"ADMISSION_CONFIRMATION_REQUIRED")
                confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity)
            }
            return true
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure=error as? V2HTTPFailure,now=Date()
            let paused=roundEnd <= confirmationClock() || pending.preparationAttempts>=5 || error is V2GroupCapabilityAdmissionError || error is DatabaseError || error is V2GroupCapabilityValidationError
            let retry=max(now.addingTimeInterval(min(8,pow(2,Double(pending.preparationAttempts)))),failure?.retryAfter ?? now)
            let withinWindow=retry.timeIntervalSince1970*1_000<Double(pending.intent.confirmedUntilMilliseconds)
            try await store.pauseGroupCapabilityPreparation(id:pending.id,until:retry,code:"ADMISSION_CONFIRMATION_REQUIRED",paused:paused || !withinWindow)
            if paused || !withinWindow { confirmations.removeValue(forKey:identity);preparationEnds.removeValue(forKey:identity) }
            if error is DatabaseError { throw error };return false
        }
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,[V2OperationKind.pinnedMessage,.groupAnnouncement,.groupPermission,.groupRole].contains(claim.work.identity.kind) else { throw V2OperationWorkError.accountMismatch }
        let command=try await store.groupCapabilityCommand(workID:claim.work.id)
        guard command.identity==claim.work.identity,try command.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        do {
            let open=Date().timeIntervalSince1970*1_000<Double(command.admission.expiresAtMilliseconds)
            let result:V2GroupCapabilityRecoveryResult
            if claim.action == .submit && open {
                let remaining=max(0,Double(command.admission.expiresAtMilliseconds)/1000-Date().timeIntervalSince1970)
                let client=self.client
                result=try await V2HTTPRequestDeadline.run(until:.now.advanced(by:.seconds(min(15,remaining))),service:"accountAPI",certainty:.outcomeUnknown) { try await client.submit(command) }
            } else { result=try await client.recover(command,action:open ? .query:.closeIfAbsent) }
            switch result {
            case .receipt(let receipt):try await store.completeGroupCapability(receipt,command:command)
            case .fingerprintConflict:try await store.deferOperationWork(claim,until:Date(),code:"GROUP_CAPABILITY_FINGERPRINT_CONFLICT",scheduling:.needsAttention)
            case .unresolved:try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"GROUP_CAPABILITY_UNRESOLVED",nextAction:open ? .submit:.reconcile)
            case .deferred(let hint):
                guard hint.validates(identity:claim.work.identity,fingerprint:claim.work.fingerprint) else { throw V2OperationWorkError.identityConflict }
                try await deferFailure(claim,floor:Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1_000),malformed:false)
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"GROUP_CAPABILITY_INTERRUPTED");throw CancellationError()
        } catch {
            try await deferFailure(claim,floor:(error as? V2HTTPFailure)?.retryAfter,malformed:error is DatabaseError || error is V2OperationWorkError || error is V2GroupCapabilityValidationError)
            if error is DatabaseError { throw error }
        }
    }
    private func deferFailure(_ claim:V2OperationWorkClaim,floor:Date?,malformed:Bool) async throws {
        let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,deadline=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
        let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
        try await store.deferOperationWork(claim,until:max(retry ?? now,floor ?? now),code:"GROUP_CAPABILITY_CONFIRMATION_REQUIRED",scheduling:malformed || retry == nil ? .needsAttention:.backingOff)
    }
}
