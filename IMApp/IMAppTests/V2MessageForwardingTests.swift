import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("Forwarding reports durable whole-plan outcomes")
struct V2MessageForwardingTests {
    @Test("already cancelled page action never persists or starts network work")
    func cancelledForward() async throws {
        try await withStore { local,_,_ in
            let client=ForwardOutcomeTransport(),service=self.service(local,client:client)
            let forwarder=V2OperationMessageForwarder(service:service)
            let task=Task { withUnsafeCurrentTask{$0?.cancel()};return try await forwarder.forward(sources:self.references(1),targetRoomIDs:self.targets(1)) }
            await #expect(throws:CancellationError.self) { try await task.value }
            let due=try await local.dueOperationWork(now:Date(),kinds:[.forwardMessage])
            #expect(due.isEmpty)
            #expect(await client.commands.isEmpty)
            let outcome=try await forwarder.forward(sources:self.references(1),targetRoomIDs:self.targets(1))
            #expect(outcome == .queued)
            #expect(await client.commands.isEmpty)
        }
    }
    @Test("large page action saves frozen manifest before network and survives reopen")
    func largePlanResumes() async throws {
        try await withStore { local,url,binding in
            let client=ForwardOutcomeTransport(),service=self.service(local,client:client)
            #expect(try await V2OperationMessageForwarder(service:service).forward(sources:self.references(100),targetRoomIDs:self.targets(2)) == .queued)
            let work=try #require(try await local.dueOperationWork(now:Date(),kinds:[.forwardMessage]).first)
            let original=try await local.forwardPlanSnapshot(workID:work.id)
            #expect(original.command.childCount==10 && original.unresolved==200)
            #expect(await client.commands.isEmpty)
            try await local.close()
            let reopened=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:binding,userID:self.actor)
            let restored=try await reopened.forwardPlanSnapshot(workID:work.id)
            #expect(restored.command==original.command)
            let resumed=self.service(reopened,client:client)
            guard case .claimed(let claim)=try await reopened.claimOperationWork(id:work.id,ownerID:UUID(),action:.submit,now:Date()) else { throw V2OperationWorkError.invalidTransition }
            try await resumed.execute(claim)
            #expect(await client.commands.first==original.command)
            #expect(try await reopened.forwardPlanSnapshot(workID:work.id).unresolved==200)
            try await reopened.close()
        }
    }
    @Test("cancelling observation keeps durable work and explicit stop never invents submission")
    func pageObservationDoesNotCancelWork() async throws {
        try await withStore { local,_,_ in
            let service=self.service(local,client:ForwardOutcomeTransport())
            let id=try await service.enqueue(sources:self.references(1),targetRoomIDs:self.targets(1).map(RoomID.init))
            let stream=await service.updates(sourceRoomID:try RoomID(self.targets(1)[0]))
            let observer=Task { for try await _ in stream { try Task.checkCancellation() } }
            observer.cancel();_ = await observer.result
            #expect(try await local.forwardPlanSnapshot(workID:id).work.scheduling == .ready)
            try await service.cancelRemaining(workID:id)
            #expect(try await local.forwardPlanSnapshot(workID:id).work.execution == .cancelledLocally)
        }
    }

    @Test("the conversation dismisses durable selection without claiming the first chunk completed everything")
    func conversationShowsQueuedPlan() async throws {
        try await withStore { local, _, _ in
            let messages = self.sources(40).enumerated().map { index, id in
                V2ConversationMessageItem(id: id, roomSequence: UInt64(index + 1), revision: 1, text: "selected", createdAt: .now, isOutgoing: false, isWithdrawn: false)
            }
            let service = self.service(local, client: ForwardOutcomeTransport())
            let store = V2ConversationDetailStore(environment: .init(
                userID: self.targets(1)[0],
                projections: .init(dataSource: ForwardOutcomeDataSource(messages: messages)),
                messages: .init(forwarder: V2OperationMessageForwarder(service:service))
            ), context: .init(roomID: self.targets(1)[0], kind: .group))
            await store.refresh()
            #expect(store.messages.count == 40)
            store.beginForwardSelection()
            for message in store.messages { store.toggleForwardSelection(for: message) }
            #expect(await store.forwardSelectedMessages(to: self.targets(1)))
            #expect(store.messageActionFeedback == "转发任务已保存，剩余消息会继续处理。")
            #expect(!store.isSelectingMessagesForForward)
            #expect(store.selectedForwardMessageIDs.isEmpty)
            let work=try #require(try await local.dueOperationWork(now:Date(),kinds:[.forwardMessage]).first)
            #expect(try await local.forwardPlanSnapshot(workID:work.id).unresolved==40)
        }
    }

    @Test("selection keeps its original version even if the projection edits or leaves the window", arguments: [false, true])
    func selectedVersionIsStable(removed: Bool) async throws {
        try await withStore { local, _, _ in
            let id = self.sources(1)[0]
            let original = V2ConversationMessageItem(id: id, revision: 3, text: "selected version", createdAt: .now, isOutgoing: false, isWithdrawn: false)
            let replacement = V2ConversationMessageItem(id: id, revision: 5, text: "later edit", createdAt: .now, isOutgoing: false, isWithdrawn: false)
            let source = ForwardOutcomeDataSource(messages: [original])
            let transport = ForwardOutcomeTransport()
            let service = self.service(local, client: transport)
            let room = self.targets(1)[0]
            let store = V2ConversationDetailStore(environment: .init(
                userID: room, projections: .init(dataSource: source),
                messages: .init(forwarder: V2OperationMessageForwarder(service:service))
            ), context: .init(roomID: room, kind: .group))
            await store.refresh()
            store.beginForwardSelection(with: original)
            await source.setMessages(removed ? [] : [replacement])
            await store.refresh()
            #expect(store.selectedForwardMessageIDs == [id])
            #expect(await store.forwardSelectedMessages(to: [room]))
            #expect(await transport.commands.isEmpty)
            let work=try #require(try await local.dueOperationWork(now:Date(),kinds:[.forwardMessage]).first)
            let command=try await local.forwardPlanSnapshot(workID:work.id).command.command
            let expected = V2ForwardMessageReference(roomID: try .init(room), messageID: try .init(id), revision: try .init(3))
            #expect(command.sources == [expected])
        }
    }

    @Test("capacity rejection keeps page selection and reports the durable queue limit")
    func pageCapacityKeepsSelection() async throws {
        try await withStore { local,_,_ in
            let filling=self.service(local,client:ForwardOutcomeTransport())
            var full=false
            for _ in 0..<40 {
                do { _ = try await filling.enqueue(sources:[.init(roomID:RoomID(self.targets(1)[0]),messageID:.init(uuid:UUID()),revision:.init(1))],targetRoomIDs:self.targets(1).map(RoomID.init)) }
                catch V2OperationWorkError.capacityExceeded { full=true;break }
            }
            #expect(full)
            let message=V2ConversationMessageItem(id:self.sources(1)[0],revision:1,text:"keep",createdAt:.now,isOutgoing:false,isWithdrawn:false)
            let store=V2ConversationDetailStore(environment:.init(userID:self.actor.rawValue,projections:.init(dataSource:ForwardOutcomeDataSource(messages:[message])),messages:.init(forwarder:V2OperationMessageForwarder(service:self.service(local,client:ForwardOutcomeTransport())))),context:.init(roomID:self.targets(1)[0],kind:.group))
            await store.refresh();store.beginForwardSelection(with:message)
            #expect(await store.forwardSelectedMessages(to:self.targets(1))==false)
            #expect(store.isSelectingMessagesForForward && store.selectedForwardMessageIDs==[message.id])
            #expect(store.messageActionFeedback=="待处理任务已达上限，已选择的消息和目标仍保留。")
            let forward=try await local.dueOperationWork(now:Date(),kinds:[.forwardMessage])
            for work in forward {
                let saved=try await local.forwardPlanSnapshot(workID:work.id)
                #expect(!saved.command.command.sources.contains(where:{$0.messageID.rawValue==message.id}))
            }
        }
    }
    @Test("paused page explicitly continues and cancels the original plan without renewing its floor")
    func pageContinuationAndCancellation() async throws {
        try await withStore { local,_,_ in
            let client=ForwardOutcomeTransport(),service=self.service(local,client:client)
            let id=try await service.enqueue(sources:self.references(1),targetRoomIDs:self.targets(1).map(RoomID.init))
            guard case .claimed(let claim)=try await local.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:Date()) else { throw V2OperationWorkError.invalidTransition }
            let floor=Date().addingTimeInterval(120)
            try await local.deferOperationWork(claim,until:floor,code:"UNKNOWN",scheduling:.needsAttention)
            let before=try await local.forwardPlanSnapshot(workID:id)
            let store=V2ConversationDetailStore(environment:.init(userID:self.actor.rawValue,projections:.init(dataSource:ForwardOutcomeDataSource(messages:[])),messages:.init(forwarder:V2OperationMessageForwarder(service:service))),context:.init(roomID:self.targets(1)[0],kind:.group))
            let observer=Task { await store.observeForwardPlans() };defer { observer.cancel() }
            for _ in 0..<200 { if store.forwardPlans.contains(where:{$0.work.id==id}) { break };try await Task.sleep(for:.milliseconds(10)) }
            #expect(store.forwardPlans.first?.work.scheduling == .needsAttention)
            await store.resumeForwardPlan(id)
            #expect(try await local.operationWork(id:id)?.nextActionAt==before.work.nextActionAt)
            await store.cancelRemainingForwardPlan(id)
            let after=try await local.forwardPlanSnapshot(workID:id)
            #expect(after.cancellationRequested && after.work.nextAction == .reconcile && after.work.nextActionAt==before.work.nextActionAt)
            #expect(after.command==before.command && after.work.execution == .awaitingConfirmation)
            #expect(await client.commands.isEmpty)
            observer.cancel();await observer.value
        }
    }

    private var actor:UserID { .init(uuid:UUID(uuidString:"00000000-0000-0000-0000-00000000aa01")!) }

    private func sources(_ count: Int) -> [String] {
        (1...count).map { String(format: "00000000-0000-0000-0000-%012x", $0) }
    }

    private func references(_ count: Int) throws -> [V2ForwardMessageReference] {
        try sources(count).map { .init(roomID: try .init(targets(1)[0]), messageID: try .init($0), revision: try .init(1)) }
    }

    private func targets(_ count: Int) -> [String] {
        (1...count).map { String(format: "00000000-0000-0000-0000-%012x", 0xf100 + $0) }
    }

    private func service(_ store:GRDBV2LocalSyncStore,client:ForwardOutcomeTransport) -> V2ForwardPlanOperationService {
        .init(accountID:actor,store:store,client:client)
    }

    private func withStore(_ body: @MainActor (GRDBV2LocalSyncStore, URL, V2LocalInstallationBinding) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-forward-outcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "main.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding,userID:actor)
        do {
            try await body(local, url, binding)
            try await local.close()
        } catch {
            try? await local.close()
            throw error
        }
    }
}

private actor ForwardOutcomeTransport: V2ForwardPlanOperationClient {
    private(set) var commands:[V2ForwardPlanOperationCommand] = []
    func submit(_ command:V2ForwardPlanOperationCommand) async throws -> V2ForwardPlanRecoveryResult { commands.append(command);return .unresolved }
    func recover(_ command:V2ForwardPlanOperationCommand,action:V2ForwardPlanRecoveryAction) async throws -> V2ForwardPlanRecoveryResult { commands.append(command);return .unresolved }
}

private actor ForwardOutcomeDataSource: V2ConversationDataSource {
    private var messages: [V2ConversationMessageItem]
    func setMessages(_ messages: [V2ConversationMessageItem]) { self.messages = messages }
    init(messages: [V2ConversationMessageItem]) { self.messages = messages }
    func conversationSummaryPage(for userID: String, isArchived: Bool, before cursor: V2ClientConversationListCursor?, limit: Int) async throws -> V2ConversationListPage {
        .init(items: [], nextCursor: nil)
    }
    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation {
        Issue.record("Forwarding tests do not request timeline location")
        return .unavailable
    }
    func timelinePage(in roomID: String, for userID: String, before cursor: V2ConversationTimelineCursor?, limit: Int) async throws -> V2ConversationTimelinePage {
        .init(items: messages.map { .message($0, timelineSequence: $0.roomSequence) }, olderCursor: nil)
    }
}
