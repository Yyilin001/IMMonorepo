import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Forward original plan recovery")
struct V2ForwardPlanRecoveryTests {
    @Test("lost acceptance reopens SQLite and queries original manifest without another parent submission")
    func lostSubmitRecoversOriginal() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let terminal=try f.resolved(f.progress(resolvedCount:4))
        let remote=ForwardRecoveryRemote(command:f.command,terminal:terminal,loseSubmit:true)
        let store=try f.open(),id=try await store.enqueueForwardPlanOperation(f.command)
        let service=V2ForwardPlanOperationService(accountID:f.user,store:store,client:remote)
        guard case .claimed(let submit)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:Date()) else { throw V2OperationWorkError.invalidTransition }
        try await service.execute(submit)
        let unknown=try await store.forwardPlanSnapshot(workID:id)
        #expect(unknown.work.execution == .awaitingConfirmation && unknown.work.nextAction == .reconcile)
        try await store.close()
        let reopened=try f.open()
        let resumed=V2ForwardPlanOperationService(accountID:f.user,store:reopened,client:remote)
        guard case .claimed(let query)=try await reopened.claimOperationWork(id:id,ownerID:UUID(),action:.reconcile,now:unknown.work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        try await resumed.execute(query)
        let complete=try await reopened.forwardPlanSnapshot(workID:id)
        #expect(complete.work.execution == .committed && complete.succeeded==50 && complete.unresolved==0)
        #expect(await remote.submissionCount==1)
        #expect(await remote.recoveryCount==1)
        #expect(complete.command==f.command)
        try await reopened.close()
    }
    @Test("partial acceptance keeps its proof while explicit cancellation resolves only pending children")
    func cancelRemainingKeepsAcceptedProof() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let full=try f.progress(resolvedCount:4)
        let partial=try V2ForwardPlanProgress(identity:f.command.identity,fingerprint:f.command.fingerprint,executionState:.processing,children:full.children.enumerated().map { index,child in
            index==0 ? child : try .init(index:child.index,operationID:child.operationID,state:.pending)
        })
        let cancelled=try V2ForwardPlanProgress(identity:f.command.identity,fingerprint:f.command.fingerprint,executionState:.completed,children:full.children.enumerated().map { index,child in
            index==0 ? child : try .init(index:child.index,operationID:child.operationID,state:.resolved(.init(parentIdentity:f.command.identity,parentFingerprint:f.command.fingerprint,index:child.index,operationID:child.operationID,outcome:.cancelledBeforeStart,resolvedAtMilliseconds:1_800_000_000_000)))
        })
        let remote=ForwardRecoveryRemote(command:f.command,terminal:try f.resolved(cancelled),partial:partial)
        let store=try f.open(),id=try await store.enqueueForwardPlanOperation(f.command)
        let service=V2ForwardPlanOperationService(accountID:f.user,store:store,client:remote)
        guard case .claimed(let submit)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:Date()) else { throw V2OperationWorkError.invalidTransition }
        try await service.execute(submit)
        let processing=try await store.forwardPlanSnapshot(workID:id)
        #expect(processing.succeeded==20 && processing.unresolved==30 && processing.work.execution == .processing)
        try await service.cancelRemaining(workID:id)
        guard case .claimed(let cancel)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.reconcile,now:processing.work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        try await service.execute(cancel)
        let complete=try await store.forwardPlanSnapshot(workID:id)
        #expect(complete.succeeded==20 && complete.cancelled==30 && complete.rejected==0 && complete.unresolved==0)
        #expect(complete.progress?.children[0]==partial.children[0])
        #expect(await remote.lastAction == .cancelRemaining)
        try await store.close()
    }
}
private actor ForwardRecoveryRemote:V2ForwardPlanOperationClient {
    let command:V2ForwardPlanOperationCommand,terminal:V2ForwardPlanResolvedResult,partial:V2ForwardPlanProgress?,loseSubmit:Bool
    private(set) var submissionCount=0,recoveryCount=0
    private(set) var lastAction:V2ForwardPlanRecoveryAction?
    init(command:V2ForwardPlanOperationCommand,terminal:V2ForwardPlanResolvedResult,partial:V2ForwardPlanProgress?=nil,loseSubmit:Bool=false) {
        self.command=command;self.terminal=terminal;self.partial=partial;self.loseSubmit=loseSubmit
    }
    func submit(_ command:V2ForwardPlanOperationCommand) throws -> V2ForwardPlanRecoveryResult {
        guard command==self.command else { throw V2OperationWorkError.identityConflict }
        submissionCount+=1
        if loseSubmit { throw URLError(.networkConnectionLost) }
        return partial.map(V2ForwardPlanRecoveryResult.processing) ?? .receipt(terminal)
    }
    func recover(_ command:V2ForwardPlanOperationCommand,action:V2ForwardPlanRecoveryAction) throws -> V2ForwardPlanRecoveryResult {
        guard command==self.command else { throw V2OperationWorkError.identityConflict }
        recoveryCount+=1;lastAction=action;return .receipt(terminal)
    }
}
