import Foundation
import GRDB
import IMV2Core

public struct V2InvitationConfirmationWindow:Sendable {
    public let intent:V2GroupInvitationOperationIntent
    public let deadline:ContinuousClock.Instant
    let activationID:UUID
}

/// Account-owned preparation; an unlocked bearer is needed only to admit/submit,
/// never to query or close the original immutable identity.
public actor V2InvitationOperationService {
    private let accountID:UserID
    private let activationID:UUID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2InvitationOperationClient
    private let secrets:any V2InvitationSecretStoring
    private var confirmations:[String:ContinuousClock.Instant]=[:]
    private var roundEnds:[String:ContinuousClock.Instant]=[:]
    private var preparing=false
    public init(accountID:UserID,activationID:UUID,store:GRDBV2LocalSyncStore,client:any V2InvitationOperationClient,secrets:any V2InvitationSecretStoring) {
        self.accountID=accountID;self.activationID=activationID;self.store=store;self.client=client;self.secrets=secrets
    }
    public func baseline(roomID:RoomID) async throws -> V2GroupInvitationOperationBaseline {
        let client=self.client
        return try await V2HTTPRequestDeadline.run(until:.now.advanced(by:.seconds(15)),service:"accountAPI") {try await client.baseline(roomID:roomID)}
    }
    public func confirmation(roomID:RoomID,action:V2GroupInvitationOperationAction,operationID:UUID=UUID()) throws -> V2InvitationConfirmationWindow {
        let reference:V2OperationReference
        switch action.kind {
        case .groupInvite:reference = .groupInvite(.init(uuid:operationID))
        case .groupJoinRequest:reference = .groupJoinRequest(.init(uuid:operationID))
        case .groupJoinDecision:reference = .groupJoinDecision(.init(uuid:operationID))
        default:throw V2OperationWorkError.invalidRecord
        }
        let milliseconds=(Date().timeIntervalSince1970*1000).rounded(.towardZero)
        guard milliseconds>=0,milliseconds<Double(Int64.max)-120_000,let timestamp=UInt64(exactly:milliseconds) else {throw V2OperationWorkError.invalidRecord}
        let identity=try V2OperationIdentity(accountID:accountID,scope:.room(roomID),operation:reference)
        return .init(intent:try .init(identity:identity,action:action,confirmedUntilMilliseconds:timestamp+120_000),deadline:.now.advanced(by:.seconds(120)),activationID:activationID)
    }
    @discardableResult public func enqueue(_ confirmation:V2InvitationConfirmationWindow,authorization:V2GroupInvitationSecretAuthorization?=nil) async throws -> UUID {
        try Task.checkCancellation()
        guard confirmation.activationID==activationID,confirmation.intent.identity.accountID==accountID,confirmation.deadline > .now else {throw V2InvitationPreparationError.confirmationRequired}
        let reference:UUID?
        if case .submit = confirmation.intent.action {
            guard let authorization,authorization.validates(intent:confirmation.intent) else {throw V2GroupInvitationOperationValidationError.invalidSecretBinding}
            reference=UUID();try secrets.save(authorization,reference:reference!,accountID:accountID)
        } else {guard authorization==nil else {throw V2GroupInvitationOperationValidationError.invalidSecretBinding};reference=nil}
        let key=confirmation.intent.identity.storageKey
        confirmations[key]=confirmation.deadline
        let id:UUID
        do {id=try await store.enqueueInvitation(confirmation.intent,activationID:activationID,secretReference:reference)}
        catch {confirmations.removeValue(forKey:key);if let reference {try? secrets.remove(reference:reference,accountID:accountID)};throw error}
        // Idempotent reuse owns the original reference. Never leak a newly saved
        // bearer, and never delete the durable reference on a later DB read error.
        if let reference,let pending=try? await store.invitationPending(id:id),pending.secretReference != reference {try? secrets.remove(reference:reference,accountID:accountID)}
        return id
    }
    public func updates(roomID:RoomID) -> AsyncThrowingStream<[V2InvitationPending],any Error> {store.invitationUpdates(roomID:roomID)}
    public func discard(id:UUID) async throws {try await store.discardInvitationDraft(id:id,accountID:accountID);try await releaseSecrets()}
    public func resume(id:UUID) async throws {
        let pending=try await store.invitationPending(id:id)
        guard pending.intent.identity.accountID==accountID,let work=pending.work else {throw V2InvitationPreparationError.confirmationRequired}
        try await store.retryOperationWorkByUser(id:work.id,now:Date())
    }
    public func closeOriginal(id:UUID) async throws {
        let pending=try await store.invitationPending(id:id)
        guard pending.intent.identity.accountID==accountID else {throw V2OperationWorkError.accountMismatch}
        let workID=try await store.trackInvitationRecovery(id:id)
        if let work=try await store.invitationPending(id:id).work,work.scheduling == .needsAttention {try await store.retryOperationWorkByUser(id:workID,now:Date())}
    }
    public func reconfirm(id:UUID,confirmation:V2InvitationConfirmationWindow) async throws -> UUID {
        let pending=try await store.invitationPending(id:id)
        guard pending.intent.identity.accountID==accountID,confirmation.activationID==activationID,confirmation.deadline > .now else {throw V2InvitationPreparationError.confirmationRequired}
        let key=confirmation.intent.identity.storageKey;confirmations[key]=confirmation.deadline
        do {return try await store.replaceInvitationDraft(id:id,intent:confirmation.intent,activationID:activationID,now:Date())}
        catch {confirmations.removeValue(forKey:key);throw error}
    }
    public func runPreparation() async throws {
        try await releaseSecrets()
        let schedule=await store.invitationPreparationSchedule()
        try await V2CommandRetryScheduler(schedule:schedule,flush:{_ = try await self.prepareNext()}).run()
    }
    private func authorization(_ pending:V2InvitationPending) throws -> V2GroupInvitationSecretAuthorization? {
        guard case .submit = pending.intent.action else {return nil}
        guard let reference=pending.secretReference else {throw V2InvitationSecretStoreError.missing}
        let value=try secrets.load(reference:reference,accountID:accountID)
        guard value.validates(intent:pending.intent) else {throw V2GroupInvitationOperationValidationError.invalidSecretBinding};return value
    }
    @discardableResult public func prepareNext() async throws -> Bool {
        guard !preparing else {return false};preparing=true;defer {preparing=false}
        guard let pending=try await store.beginInvitationPreparation() else {return false}
        let key=pending.intent.identity.storageKey
        guard pending.intent.identity.accountID==accountID else {throw V2OperationWorkError.accountMismatch}
        guard pending.confirmationActivationID==activationID,let end=confirmations[key],end > .now else {
            try await store.pauseInvitationPreparation(id:pending.id,code:"CONFIRMATION_REQUIRED");return true
        }
        let round=roundEnds[key] ?? min(end,.now.advanced(by:.seconds(60)));roundEnds[key]=round
        do {
            guard round > .now else {throw V2InvitationPreparationError.confirmationRequired}
            let request=try V2GroupInvitationAdmissionRequest(intent:pending.intent,secretAuthorization:authorization(pending)),client=self.client
            let result=try await V2NetworkWorkScope.$context.withValue(.init(service:"accountAPI",priority:.recovery,isRetry:pending.preparationAttempts>1)) {
                try await V2HTTPRequestDeadline.run(until:min(round,.now.advanced(by:.seconds(15))),service:"accountAPI") {try await client.admit(request)}
            }
            try Task.checkCancellation()
            switch result {
            case .admitted(let admission):
                guard round > .now else {throw V2InvitationPreparationError.confirmationRequired}
                _ = try await store.freezeInvitation(id:pending.id,admission:admission)
            case .terminal(let receipt):
                guard receipt.validates(intent:pending.intent) else {throw V2GroupInvitationOperationValidationError.invalidReceipt}
                // The dispatcher performs a real original-identity query under its
                // durable reconciliation claim before installing the proof.
                _ = try await store.trackInvitationRecovery(id:pending.id)
            case .currentUnavailable,.fingerprintConflict:try await store.pauseInvitationPreparation(id:pending.id,code:"ADMISSION_CONFIRMATION_REQUIRED")
            }
            if case .admitted = result {} else {confirmations.removeValue(forKey:key)}
            roundEnds.removeValue(forKey:key);return true
        } catch is CancellationError {throw CancellationError()}
        catch {
            let now=Date(),floor=(error as? V2HTTPFailure)?.retryAfter ?? now
            let retry=max(now.addingTimeInterval(min(8,pow(2,Double(pending.preparationAttempts)))),floor)
            let paused=round <= .now || pending.preparationAttempts>=5 || retry.timeIntervalSince1970*1000>=Double(pending.intent.confirmedUntilMilliseconds) || error is V2InvitationSecretStoreError || error is V2InvitationPreparationError || error is DatabaseError
            try await store.pauseInvitationPreparation(id:pending.id,until:retry,code:"ADMISSION_CONFIRMATION_REQUIRED",paused:paused)
            if error is DatabaseError {throw error};return false
        }
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,[.groupInvite,.groupJoinRequest,.groupJoinDecision].contains(claim.work.identity.kind) else {throw V2OperationWorkError.accountMismatch}
        let pending=try await store.invitationPending(workID:claim.work.id)
        let wallOpen=Date().timeIntervalSince1970*1000<Double(pending.command?.admission.expiresAtMilliseconds ?? pending.intent.confirmedUntilMilliseconds)
        let open=wallOpen && (confirmations[pending.intent.identity.storageKey].map {$0 > .now} ?? true)
        do {
            let result:V2GroupInvitationOperationRecoveryResult
            if claim.action == .submit,open,let command=pending.command {
                let submission=try V2GroupInvitationSubmission(command:command,secretAuthorization:authorization(pending)),client=self.client
                result=try await V2HTTPRequestDeadline.run(until:min(confirmations[pending.intent.identity.storageKey] ?? .now.advanced(by:.seconds(15)),.now.advanced(by:.seconds(15))),service:"accountAPI",certainty:.outcomeUnknown) {try await client.submit(submission)}
            } else {
                // No frozen command means the user requested only recovery/close,
                // or admission already exposed an original terminal receipt.
                // Existing proof wins over close without acquiring new authority.
                result=try await client.recover(pending.intent,action:pending.command == nil || !open ? .closeIfAbsent:.query)
            }
            switch result {
            case .receipt(let receipt):try await store.completeInvitation(receipt,intent:pending.intent);confirmations.removeValue(forKey:pending.intent.identity.storageKey);try await releaseSecrets()
            case .fingerprintConflict:try await store.deferOperationWork(claim,until:Date(),code:"INVITATION_FINGERPRINT_CONFLICT",scheduling:.needsAttention)
            case .unresolved:try await store.deferOperationWork(claim,until:Date().addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt:claim.work.reconciliationRoundAttempts)),code:"INVITATION_UNRESOLVED",nextAction:open && pending.command != nil ? .submit:.reconcile)
            case .deferred(let hint):
                guard hint.validates(identity:claim.work.identity,fingerprint:claim.work.fingerprint) else {throw V2OperationWorkError.identityConflict}
                try await deferFailure(claim,floor:Date().addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1000),paused:false)
            }
        } catch is CancellationError {try await store.deferOperationWork(claim,until:Date(),code:"INVITATION_INTERRUPTED");throw CancellationError()}
        catch {
            try await deferFailure(claim,floor:(error as? V2HTTPFailure)?.retryAfter,paused:error is DatabaseError || error is V2OperationWorkError || error is V2InvitationSecretStoreError)
            if error is DatabaseError {throw error}
        }
    }
    private func deferFailure(_ claim:V2OperationWorkClaim,floor:Date?,paused:Bool) async throws {
        let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery,end=claim.work.reconciliationRoundDeadline ?? now.addingTimeInterval(policy.totalBudget)
        let next=policy.nextAttempt(now:now,startedAt:end.addingTimeInterval(-policy.totalBudget),attemptsCompleted:claim.work.reconciliationRoundAttempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
        try await store.deferOperationWork(claim,until:max(next ?? now,floor ?? now),code:"INVITATION_CONFIRMATION_REQUIRED",scheduling:paused || next==nil ? .needsAttention:.backingOff)
    }
    public func releaseProtectedSecrets() async throws {try await releaseSecrets()}
    private func releaseSecrets() async throws {
        while true {
            try Task.checkCancellation()
            let values=try await store.invitationSecretsForRelease()
            var released=0
            for pending in values {
                try Task.checkCancellation()
                guard pending.intent.identity.accountID==accountID,let reference=pending.secretReference else {continue}
                do {try secrets.remove(reference:reference,accountID:accountID);try await store.markInvitationSecretReleased(id:pending.id);released+=1}
                catch is V2InvitationSecretStoreError {continue}
            }
            if values.count<100 || released==0 {return}
        }
    }
}
