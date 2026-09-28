import Foundation
import Testing
import GRDB
import IMV2Core
@testable import IMV2ClientKit

@Suite("Durable forward plan authority")
struct V2ForwardPlanWorkTests {
    @Test("fresh schema persists original manifest and child identities across reopen")
    func restartIdentity() async throws {
        let f=try ForwardWorkFixture();defer { f.remove() }
        let store=try f.open()
        let original=try f.command()
        let id=try await store.enqueueForwardPlanOperation(original,now:f.now)
        let children=try (0..<original.childCount).map { try original.childCommand(index:$0).operationID }
        #expect(children.count==4)
        try await store.close()
        let reopened=try f.open()
        let snapshot=try await reopened.forwardPlanSnapshot(workID:id)
        #expect(snapshot.command==original)
        #expect(try (0..<snapshot.command.childCount).map { try snapshot.command.childCommand(index:$0).operationID }==children)
        let duplicate=try f.command()
        #expect(try await reopened.enqueueForwardPlanOperation(duplicate,now:f.now.addingTimeInterval(60))==id)
        #expect(try await reopened.forwardPlanSnapshot(workID:id).command.firstSubmissionDeadlineMilliseconds==original.firstSubmissionDeadlineMilliseconds)
        try await reopened.close()
    }

    @Test("admission reserves full progress and terminal proof before capacity fills")
    func progressReservation() async throws {
        let f=try ForwardWorkFixture();defer { f.remove() }
        let store=try f.open(),command=try f.command()
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let reserved=Int64(try encoder.encode(command).count)+1_048_576+65_536
        let limits=V2OperationWorkLimits(maximumPayloadBytes:reserved)
        let id=try await store.enqueueForwardPlanOperation(command,now:f.now,limits:limits)
        #expect(try await store.databasePool.read { try Int64.fetchOne($0,sql:"SELECT payload_bytes FROM v2_operation_work WHERE work_id=?",arguments:[id.uuidString]) }==reserved)
        let independent=try V2ForwardPlanOperationCommand(actorUserID:f.user,command:.init(operationID:.init(uuid:UUID()),sources:command.command.sources.map { .init(roomID:$0.roomID,messageID:.init(uuid:UUID()),revision:$0.revision) },targetRoomIDs:command.command.targetRoomIDs),firstSubmissionDeadlineMilliseconds:command.firstSubmissionDeadlineMilliseconds)
        await #expect(throws:V2OperationWorkError.capacityExceeded) { try await store.enqueueForwardPlanOperation(independent,now:f.now,limits:limits) }
        #expect(try await store.dueOperationWork(now:f.now,kinds:[.forwardMessage]).map(\.id)==[id])
        #expect(try await store.enqueueForwardPlanOperation(command,now:f.now,limits:limits)==id)
        try await store.close()
    }

    @Test("new finished history never hides an old unknown plan from its source page")
    func activePlanVisibility() async throws {
        let f=try ForwardWorkFixture();defer { f.remove() }
        let store=try f.open(),original=try f.command()
        let id=try await store.enqueueForwardPlanOperation(original,now:f.now)
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:f.now) else { throw V2OperationWorkError.invalidTransition }
        try await store.deferOperationWork(claim,until:f.now,code:"UNKNOWN",scheduling:.needsAttention)
        for _ in 0..<201 {
            let command=try V2ForwardPlanOperationCommand(actorUserID:f.user,command:.init(operationID:.init(uuid:UUID()),sources:[.init(roomID:f.room,messageID:.init(uuid:UUID()),revision:.init(1))],targetRoomIDs:[f.targets[0]]),firstSubmissionDeadlineMilliseconds:original.firstSubmissionDeadlineMilliseconds)
            let historyID=try await store.enqueueForwardPlanOperation(command,now:f.now)
            _ = try await store.claimOperationWork(id:historyID,ownerID:UUID(),action:.submit,now:f.now)
            let child=try V2ForwardPlanChildReceipt(parentIdentity:command.identity,parentFingerprint:command.fingerprint,index:0,operationID:command.childCommand(index:0).operationID,outcome:.cancelledBeforeStart,resolvedAtMilliseconds:1_800_000_000_000)
            let progress=try V2ForwardPlanProgress(identity:command.identity,fingerprint:command.fingerprint,executionState:.completed,children:[.init(index:0,operationID:child.operationID,state:.resolved(child))])
            try await store.completeForwardPlan(.init(receipt:.init(identity:command.identity,fingerprint:command.fingerprint,outcome:.closedBeforeStart,resolvedAtMilliseconds:1_800_000_000_000),progress:progress),workID:historyID,now:f.now)
        }
        let stream=store.forwardPlanUpdates(sourceRoomID:f.room)
        var iterator=stream.makeAsyncIterator()
        let visible=try #require(try await iterator.next())
        #expect(visible.first?.work.id==id && visible.first?.work.scheduling == .needsAttention)
        #expect(visible.count==202)
        try await store.close()
    }

    @Test("processing proof and server floor survive user continuation and cancellation")
    func processingAndCancellation() async throws {
        let f=try ForwardWorkFixture();defer { f.remove() }
        let store=try f.open(), command=try f.command()
        let id=try await store.enqueueForwardPlanOperation(command,now:f.now)
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:f.now) else { throw V2OperationWorkError.invalidTransition }
        let progress=try V2ForwardPlanProgress(identity:command.identity,fingerprint:command.fingerprint,executionState:.processing,children:(0..<command.childCount).map { index in
            try .init(index:index,operationID:command.childCommand(index:index).operationID,state:index==0 ? .processing : .pending)
        })
        let floor=f.now.addingTimeInterval(120)
        try await store.recordForwardPlanProgress(progress,claim:claim,until:floor,scheduling:.needsAttention)
        try await store.requestForwardPlanCancellation(workID:id,accountID:f.user,now:f.now.addingTimeInterval(1))
        let snapshot=try await store.forwardPlanSnapshot(workID:id)
        #expect(snapshot.work.execution == .processing)
        #expect(snapshot.work.nextAction == .reconcile && snapshot.work.nextActionAt==floor)
        #expect(snapshot.cancellationRequested && snapshot.progress==progress && snapshot.unresolved==50)
        await #expect(throws:V2ForwardPlanAdmissionError.confirmationRequired) {
            try await store.enqueueForwardPlanOperation(f.command(revision:2),now:f.now)
        }
        try await store.close()
    }
}

private struct ForwardWorkFixture:Sendable {
    let user=UserID(uuid:UUID()), binding=V2LocalInstallationBinding(value:UUID())
    let url=FileManager.default.temporaryDirectory.appending(path:"forward-work-"+UUID().uuidString).appending(path:"state.sqlite")
    let now=Date(timeIntervalSince1970:1_800_000_000)
    let room=RoomID(uuid:UUID()), targets=[RoomID(uuid:UUID()),RoomID(uuid:UUID())]
    let messages=(0..<25).map { _ in MessageID(uuid:UUID()) }
    func open() throws -> GRDBV2LocalSyncStore { try .init(databaseURL:url,installationBinding:binding,userID:user) }
    func command(revision:UInt64=1) throws -> V2ForwardPlanOperationCommand {
        try .init(actorUserID:user,command:.init(operationID:.init(uuid:UUID()),sources:messages.map { try .init(roomID:room,messageID:$0,revision:.init(revision)) },targetRoomIDs:targets),firstSubmissionDeadlineMilliseconds:UInt64(now.addingTimeInterval(86_400).timeIntervalSince1970*1_000))
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
