import Foundation
import Synchronization
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Member administration confirmation and recovery",.serialized)
struct V2MemberAdministrationWorkTests {
    @Test("restart does not renew unfrozen user confirmation")
    func unfrozenRestart() async throws {
        let f=try AdministrationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(roomID:f.room,targetUserID:f.target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0)
        try await f.store.close()
        let reopened=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        let service=V2MemberAdministrationOperationService(accountID:f.account,activationID:UUID(),store:reopened,client:f.remote)
        #expect(try await service.prepareNextIntent())
        #expect(await f.remote.admissions==0)
        #expect(try await reopened.memberAdministrationPending(id:id).confirmationRequired)
        #expect(try await reopened.memberAdministrationPending(id:id).work==nil)
        let replacement=try await service.reconfirmDraft(id:id,expectedMembershipRevision:0)
        #expect(replacement != id)
        #expect(try await service.prepareNextIntent())
        #expect(await f.remote.admissions==1)
        try await reopened.close()
    }
    @Test("lost submit response recovers original frozen admission after restart")
    func frozenRestart() async throws {
        let f=try AdministrationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(roomID:f.room,targetUserID:f.target,action:.mute(untilMilliseconds:UInt64((Date().timeIntervalSince1970+600)*1000)),reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0)
        #expect(try await f.service.prepareNextIntent())
        let original=try #require(try await f.store.memberAdministrationPending(id:id).command)
        let work=try #require(try await f.store.memberAdministrationPending(id:id).work)
        try await f.service.execute(f.claim(work.id))
        #expect(try await f.store.operationWork(id:work.id)?.execution == .awaitingConfirmation)
        try await f.store.close()
        let reopened=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        let service=V2MemberAdministrationOperationService(accountID:f.account,activationID:UUID(),store:reopened,client:f.remote)
        #expect(!(try await service.prepareNextIntent()))
        let pending=try #require(try await reopened.operationWork(id:work.id))
        guard case .claimed(let claim)=try await reopened.claimOperationWork(id:work.id,ownerID:UUID(),action:.reconcile,now:pending.nextActionAt) else { Issue.record("missing claim");return }
        try await service.execute(claim)
        #expect(try await reopened.operationWork(id:work.id)?.execution == .committed)
        #expect(try await reopened.memberAdministrationCommand(workID:work.id)==original)
        #expect(await f.remote.admissions==1)
        #expect(await f.remote.submissions==1)
        try await reopened.close()
    }
    @Test("draft cancellation cannot be resurrected by a late admission")
    func lateAdmission() async throws {
        let f=try AdministrationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(roomID:f.room,targetUserID:f.target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0)
        let pending=try await f.store.memberAdministrationPending(id:id)
        let admission=try await f.remote.admit(pending.intent)
        try await f.service.discardDraft(id:id)
        if case .admitted(let context)=admission { #expect(try await f.store.freezeMemberAdministration(id:id,admission:context)==nil) }
        #expect(try await f.store.memberAdministrationPending(id:id).preparationState == .cancelled)
        try await f.store.close()
    }
}
struct AdministrationFixture {
    let url=FileManager.default.temporaryDirectory.appending(path:"member-admin-"+UUID().uuidString).appending(path:"state.sqlite")
    let binding=V2LocalInstallationBinding(value:UUID()),account=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),target=UserID(uuid:UUID())
    let store:GRDBV2LocalSyncStore,remote:AdministrationRemote,service:V2MemberAdministrationOperationService
    init() throws {
        store=try .init(databaseURL:url,installationBinding:binding,userID:account)
        remote=AdministrationRemote()
        service = .init(accountID:account,activationID:UUID(),store:store,client:remote)
    }
    func claim(_ id:UUID) async throws -> V2OperationWorkClaim {
        let work=try #require(try await store.operationWork(id:id))
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition };return claim
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
actor AdministrationRemote:V2MemberAdministrationOperationClient {
    var admissions=0,submissions=0
    var saved:V2MemberAdministrationReceipt?
    var closes=0
    var closeAbsent=false
    func enableAbsentClose() { closeAbsent=true }
    func admit(_ intent:V2MemberAdministrationIntent) async throws -> V2MemberAdministrationAdmissionResult {
        admissions += 1
        return .admitted(try .init(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,membershipRevision:intent.expectedMembershipRevision,targetJoinedRevision:0,issuedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000),expiresAtMilliseconds:intent.confirmedUntilMilliseconds))
    }
    func submit(_ command:V2MemberAdministrationCommand) async throws -> V2MemberAdministrationRecoveryResult {
        submissions += 1
        let outcome:V2MemberAdministrationTerminalOutcome
        switch command.intent.action {
        case .mute(let until):outcome = .alreadySatisfied(muteUntilMilliseconds:until,membershipRevision:command.intent.expectedMembershipRevision)
        case .remove:outcome = .applied(.removed(membershipRevision:command.intent.expectedMembershipRevision+1,roomSequence:1,eventID:.init(uuid:UUID())))
        }
        saved=try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:outcome,resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000))
        throw URLError(.networkConnectionLost)
    }
    func recover(_ command:V2MemberAdministrationCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2MemberAdministrationRecoveryResult {
        if let saved { return .receipt(saved) }
        if closeAbsent,action == .closeIfAbsent {
            closes += 1
            return .receipt(try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:.closed,resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000)))
        }
        return .unresolved
    }
}

extension V2MemberAdministrationWorkTests {
    @Test("an expired frozen admission claims reconciliation and closes authority without submitting")
    func expiredFrozenClosesOriginal() async throws {
        let f=try AdministrationFixture();defer { f.remove() }
        let now=Date().addingTimeInterval(-200),issued=UInt64(now.timeIntervalSince1970*1000)
        let intent=try V2MemberAdministrationIntent(roomID:f.room,actorUserID:f.account,operationID:.init(uuid:UUID()),targetUserID:f.target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0,confirmedUntilMilliseconds:issued+120_000)
        let id=try await f.store.enqueueMemberAdministration(intent,activationID:UUID(),now:now)
        let context=try V2MemberAdministrationAdmission(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,membershipRevision:0,targetJoinedRevision:0,issuedAtMilliseconds:issued,expiresAtMilliseconds:issued+120_000)
        let workID=try #require(try await f.store.freezeMemberAdministration(id:id,admission:context,now:now))
        guard case .claimed(let claim)=try await f.store.claimOperationWork(id:workID,ownerID:UUID(),action:.submit,now:Date()) else { Issue.record("missing authority close claim");return }
        #expect(claim.action == .reconcile)
        #expect(claim.work.submissionRoundAttempts==0)
        #expect(claim.work.reconciliationRoundAttempts==1)
        await f.remote.enableAbsentClose()
        try await f.service.execute(claim)
        #expect(await f.remote.submissions==0)
        #expect(await f.remote.closes==1)
        #expect(try await f.store.operationWork(id:workID)?.execution == .closed)
        #expect(try await f.store.memberAdministrationCommand(workID:workID).admission==context)
        try await f.store.close()
    }
    @Test("a backwards wall clock cannot extend monotonic user confirmation")
    func monotonicExpiry() async throws {
        let f=try AdministrationFixture();defer { f.remove() }
        let clock=AdministrationClock()
        let service=V2MemberAdministrationOperationService(accountID:f.account,activationID:UUID(),store:f.store,client:f.remote,confirmationClock:{ clock.now() })
        let id=try await service.enqueue(roomID:f.room,targetUserID:f.target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0)
        clock.advance(seconds:121)
        #expect(try await service.prepareNextIntent(now:Date()))
        #expect(await f.remote.admissions==0)
        #expect(try await f.store.memberAdministrationPending(id:id).confirmationRequired)
        try await f.store.close()
    }
    @Test("ordinary enqueue cannot resume an unknown frozen target")
    func cannotReplaceUnknown() async throws {
        let f=try AdministrationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(roomID:f.room,targetUserID:f.target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0)
        #expect(try await f.service.prepareNextIntent())
        let work=try #require(try await f.store.memberAdministrationPending(id:id).work)
        try await f.service.execute(f.claim(work.id))
        await #expect(throws:V2MemberAdministrationAdmissionError.confirmationRequired) {
            _ = try await f.service.enqueue(roomID:f.room,targetUserID:f.target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:1)
        }
        await #expect(throws:V2OperationWorkError.invalidTransition) { _ = try await f.service.reconfirmDraft(id:id,expectedMembershipRevision:1) }
        #expect(await f.remote.admissions==1)
        try await f.service.resumeConfirmation(id:id)
        #expect(try await f.store.memberAdministrationCommand(workID:work.id).intent.expectedMembershipRevision==0)
        try await f.store.close()
    }
    @Test("explicit draft confirmation retains durable server backpressure")
    func reconfirmKeepsFloor() async throws {
        let f=try AdministrationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(roomID:f.room,targetUserID:f.target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0)
        try await f.store.pauseMemberAdministrationPreparation(id:id,until:Date().addingTimeInterval(500),code:"RATE_LIMITED")
        let original=try await f.store.memberAdministrationPending(id:id)
        let replacement=try await f.service.reconfirmDraft(id:id,expectedMembershipRevision:1)
        let next=try await f.store.memberAdministrationPending(id:replacement)
        #expect(next.nextPreparationAt==original.nextPreparationAt)
        #expect(next.intent.operationID != original.intent.operationID)
        #expect(!(try await f.service.prepareNextIntent()))
        #expect(await f.remote.admissions==0)
        try await f.store.close()
    }
}

private final class AdministrationClock:Sendable {
    private let instant=Mutex(ContinuousClock.now)
    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(seconds:Int) { instant.withLock { $0 = $0.advanced(by:.seconds(seconds)) } }
}
