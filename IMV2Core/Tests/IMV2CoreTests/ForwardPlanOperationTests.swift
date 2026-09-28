import Foundation
import Testing
@testable import IMV2Core

struct ForwardPlanOperationTests {
    @Test func completeManifestDigestAndBoundedTerminalReceipt() throws {
        let actor=UserID(uuid:UUID()),sourceRoom=RoomID(uuid:UUID()),targets=(0..<10).map { _ in RoomID(uuid:UUID()) }
        let sources=try (0..<100).map { _ in try V2ForwardMessageReference(roomID:sourceRoom,messageID:.init(uuid:UUID()),revision:.init(1)) }
        let domain=try V2ForwardMessagesCommand(operationID:.init(uuid:UUID()),sources:sources,targetRoomIDs:targets)
        let command=try V2ForwardPlanOperationCommand(actorUserID:actor,command:domain,firstSubmissionDeadlineMilliseconds:1000)
        #expect(command.childCount==50)
        #expect(try command.childCommand(index:10).sources==Array(sources[20..<40]))
        #expect(try command.childCommand(index:10).targetRoomIDs==[targets[0]])
        #expect(try command.childCommand(index:10).operationID==V2ForwardChunkIdentity.operationID(planID:domain.operationID,chunkIndex:10))
        var children:[V2ForwardPlanChildProgress]=[]
        for index in 0..<command.childCount {
            let child=try command.childCommand(index:index)
            let results=try child.sources.enumerated().map { ordinal,source in
                try V2ForwardPlanItemResult(sourceMessageID:source.messageID,targetRoomID:child.targetRoomIDs[0],outcome:.accepted(.init(messageID:.init(uuid:UUID()),roomSequence:index/10*20+UInt64(ordinal)+1)))
            }
            let receipt=try V2ForwardPlanChildReceipt(parentIdentity:command.identity,parentFingerprint:command.fingerprint,index:index,operationID:child.operationID,outcome:.completed(results),resolvedAtMilliseconds:1000)
            children.append(try .init(index:index,operationID:child.operationID,state:.resolved(receipt)))
        }
        let progress=try V2ForwardPlanProgress(identity:command.identity,fingerprint:command.fingerprint,executionState:.completed,children:children)
        #expect(progress.validates(command:command))
        let summary=try V2ForwardPlanCompletionSummary.derive(command:command,progress:progress)
        #expect(summary.childCount==50 && summary.succeededItemCount==1000 && summary.rejectedItemCount==0 && summary.cancelledItemCount==0)
        let receipt=try V2ForwardPlanReceipt(identity:command.identity,fingerprint:command.fingerprint,outcome:.completed(summary),resolvedAtMilliseconds:1000)
        let resolved=try V2ForwardPlanResolvedResult(receipt:receipt,progress:progress)
        #expect(resolved.validates(command:command))
        #expect(try JSONEncoder().encode(receipt).count<65_536)
        #expect(try JSONEncoder().encode(progress).count<1_048_576)
        #expect(try JSONDecoder().decode(V2ForwardPlanResolvedResult.self,from:JSONEncoder().encode(resolved)).validates(command:command))
        let pendingChildren=try children.map { try V2ForwardPlanChildProgress(index:$0.index,operationID:$0.operationID,state:.pending) }
        let pending=try V2ForwardPlanProgress(identity:command.identity,fingerprint:command.fingerprint,executionState:.waitingToStart,children:pendingChildren)
        #expect(progress.canAdvance(from:pending,command:command))
        #expect(!pending.canAdvance(from:progress,command:command))
        let reversed=try V2ForwardPlanOperationCommand(actorUserID:actor,command:.init(operationID:domain.operationID,sources:Array(sources.reversed()),targetRoomIDs:targets),firstSubmissionDeadlineMilliseconds:1000)
        #expect(try reversed.identity==command.identity && reversed.fingerprint != command.fingerprint)
        #expect(!resolved.validates(command:reversed))
    }
    @Test func handedOffChildCannotRegressToNeverStartedCancellation() throws {
        let actor=UserID(uuid:UUID()),source=try V2ForwardMessageReference(roomID:.init(uuid:UUID()),messageID:.init(uuid:UUID()),revision:.init(1))
        let command=try V2ForwardPlanOperationCommand(actorUserID:actor,command:.init(operationID:.init(uuid:UUID()),sources:[source],targetRoomIDs:[.init(uuid:UUID())]),firstSubmissionDeadlineMilliseconds:1000)
        let child=try command.childCommand(index:0)
        let started=try V2ForwardPlanProgress(identity:command.identity,fingerprint:command.fingerprint,executionState:.processing,children:[.init(index:0,operationID:child.operationID,state:.processing)])
        let cancelled=try V2ForwardPlanChildReceipt(parentIdentity:command.identity,parentFingerprint:command.fingerprint,index:0,operationID:child.operationID,outcome:.cancelledBeforeStart,resolvedAtMilliseconds:1000)
        let falseCancellation=try V2ForwardPlanProgress(identity:command.identity,fingerprint:command.fingerprint,executionState:.completed,children:[.init(index:0,operationID:child.operationID,state:.resolved(cancelled))])
        #expect(!falseCancellation.canAdvance(from:started,command:command))
        let recover=try V2ForwardPlanRecoveryRequest(command:command,action:.closeIfUnstarted)
        #expect(try JSONDecoder().decode(V2ForwardPlanRecoveryRequest.self,from:JSONEncoder().encode(recover))==recover)
    }

}
