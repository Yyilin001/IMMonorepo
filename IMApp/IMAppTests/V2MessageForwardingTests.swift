import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("Forwarding reports durable whole-plan outcomes")
struct V2MessageForwardingTests {
    @Test("an already cancelled forward does not persist a plan or send a chunk")
    func cancelledForward() async throws {
        try await withStore { local, _, _ in
            let transport = ForwardOutcomeTransport()
            let outbox = self.engine(local, transport: transport)
            let forwarder = V2OutboxMessageForwarder(outbox: outbox)
            let sources = try self.references(1)
            let targets = self.targets(1)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await forwarder.forward(sources: sources, targetRoomIDs: targets)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await outbox.plan(operationID: self.planID) == nil)
            #expect(await transport.commands.isEmpty)
            #expect(try await forwarder.forward(sources: sources, targetRoomIDs: targets) == .completed(succeeded: 1, failed: 0))
            #expect(await transport.commands.count == 1)
        }
    }

    @Test("100 messages across two targets stay queued after the first chunk and resume after reopen")
    func largePlanResumes() async throws {
        try await withStore { local, url, binding in
            let transport = ForwardOutcomeTransport()
            let outbox = self.engine(local, transport: transport)
            let outcome = try await V2OutboxMessageForwarder(outbox: outbox).forward(
                sources: try self.references(100), targetRoomIDs: self.targets(2)
            )
            #expect(outcome == .queued)
            let first = try #require(await outbox.plan(operationID: self.planID))
            #expect(first.state == .active && first.succeededCount == 20 && first.totalForwardCount == 200)
            #expect(await transport.commands.count == 1)
            try await local.close()
            let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
            do {
                let resumed = self.engine(reopened, transport: transport)
                for _ in 0..<9 { _ = try await resumed.flushOnce() }
                #expect(try await resumed.flushOnce() == .idle)
                let completed = try #require(await resumed.plan(operationID: self.planID))
                #expect(completed.state == .completed && completed.succeededCount == 200 && completed.failedCount == 0)
                let commands = await transport.commands
                #expect(commands.count == 10)
                #expect(commands.allSatisfy { $0.operationID.uuidValue != nil })
                #expect(Set(commands.map(\.operationID)).count == 10)
                #expect(Set(commands.flatMap { command in command.sourceMessageIDs.map { $0.rawValue + command.targetRoomIDs[0].rawValue } }).count == 200)
                // Reusing the same durable plan returns its aggregate even
                // when there is no chunk left for this invocation to flush.
                let repeated = try await V2OutboxMessageForwarder(outbox: resumed).forward(
                    sources: try self.references(100), targetRoomIDs: self.targets(2)
                )
                #expect(repeated == .completed(succeeded: 200, failed: 0))
                #expect(await transport.commands.count == 10)
                try await reopened.close()
            } catch {
                try? await reopened.close()
                throw error
            }
        }
    }

    @Test("a terminally rejected first chunk does not terminate its remaining plan")
    func rejectedChunkKeepsPlanActive() async throws {
        try await withStore { local, _, _ in
            let transport = ForwardOutcomeTransport(mode: .reject)
            let outbox = self.engine(local, transport: transport)
            let outcome = try await V2OutboxMessageForwarder(outbox: outbox).forward(
                sources: try self.references(40), targetRoomIDs: self.targets(1)
            )
            #expect(outcome == .queued)
            let plan = try #require(await outbox.plan(operationID: self.planID))
            #expect(plan.state == .active && plan.failedCount == 20 && plan.succeededCount == 0)
            await transport.setMode(.success)
            let final = try await V2OutboxMessageForwarder(outbox: outbox).forward(
                sources: try self.references(40), targetRoomIDs: self.targets(1)
            )
            #expect(final == .completed(succeeded: 20, failed: 20))
        }
    }

    @Test("final completion includes earlier partial failures instead of only the last chunk")
    func completionUsesAllChunks() async throws {
        try await withStore { local, _, _ in
            let transport = ForwardOutcomeTransport(mode: .mixed)
            let outbox = self.engine(local, transport: transport)
            _ = try await outbox.enqueue(sources: try self.references(40), targetRoomIDs: self.targets(1).map(RoomID.init))
            _ = try await outbox.flushOnce()
            await transport.setMode(.success)
            let final = try await V2OutboxMessageForwarder(outbox: outbox).forward(
                sources: try self.references(40), targetRoomIDs: self.targets(1)
            )
            #expect(final == .completed(succeeded: 30, failed: 10))
        }
    }

    @Test("single-chunk partial results and rejection are terminal whole-plan counts", arguments: [false, true])
    func singleChunk(rejected: Bool) async throws {
        try await withStore { local, _, _ in
            let outbox = self.engine(local, transport: ForwardOutcomeTransport(mode: rejected ? .reject : .mixed))
            let outcome = try await V2OutboxMessageForwarder(outbox: outbox).forward(
                sources: try self.references(3), targetRoomIDs: self.targets(1)
            )
            #expect(outcome == .completed(succeeded: rejected ? 0 : 2, failed: rejected ? 3 : 1))
        }
    }

    @Test("a flush for an older plan cannot report success for the new plan")
    func otherPlanFlush() async throws {
        try await withStore { local, _, _ in
            let transport = ForwardOutcomeTransport()
            let older = V2BulkForwardMessagesOutboxEngine(store: local, transport: transport, now: { Date(timeIntervalSince1970: 100) })
            let prior = try await older.enqueue(sources: try self.references(1), targetRoomIDs: self.targets(1).map(RoomID.init))
            let outbox = self.engine(local, transport: transport)
            let outcome = try await V2OutboxMessageForwarder(outbox: outbox).forward(
                sources: try self.references(2), targetRoomIDs: self.targets(1)
            )
            #expect(outcome == .queued)
            #expect(try await older.plan(operationID: prior.operationID)?.state == .completed)
            let current = try #require(await outbox.plan(operationID: self.planID))
            #expect(current.state == .active && current.succeededCount == 0 && current.failedCount == 0)
        }
    }

    @Test("retryable pending results remain queued without incrementing completion counts")
    func retryablePending() async throws {
        try await withStore { local, _, _ in
            let transport = ForwardOutcomeTransport(mode: .pending)
            let outbox = self.engine(local, transport: transport)
            let outcome = try await V2OutboxMessageForwarder(outbox: outbox).forward(
                sources: try self.references(1), targetRoomIDs: self.targets(1)
            )
            #expect(outcome == .queued)
            let current = try #require(await outbox.plan(operationID: self.planID))
            #expect(current.state == .active && current.succeededCount == 0 && current.failedCount == 0)
            #expect(try await outbox.flushOnce() == .idle)
            #expect(await transport.commands.count == 1)
        }
    }

    @Test("cancelled plans are never described as queued or completed")
    func cancelledPlan() async throws {
        try await withStore { local, _, _ in
            let transport = ForwardOutcomeTransport()
            let outbox = self.engine(local, transport: transport)
            let plan = try await outbox.enqueue(sources: try self.references(1), targetRoomIDs: self.targets(1).map(RoomID.init))
            try await outbox.cancel(operationID: plan.operationID)
            let outcome = try await V2OutboxMessageForwarder(outbox: outbox).forward(
                sources: try self.references(1), targetRoomIDs: self.targets(1)
            )
            #expect(outcome == .rejected(code: "CANCELLED"))
            #expect(await transport.commands.isEmpty)
        }
    }

    @Test("the conversation dismisses durable selection without claiming the first chunk completed everything")
    func conversationShowsQueuedPlan() async throws {
        try await withStore { local, _, _ in
            let messages = self.sources(40).enumerated().map { index, id in
                V2ConversationMessageItem(id: id, roomSequence: UInt64(index + 1), revision: 1, text: "selected", createdAt: .now, isOutgoing: false, isWithdrawn: false)
            }
            let outbox = self.engine(local, transport: ForwardOutcomeTransport())
            let store = V2ConversationDetailStore(environment: .init(
                userID: self.targets(1)[0],
                projections: .init(dataSource: ForwardOutcomeDataSource(messages: messages)),
                messages: .init(forwarder: V2OutboxMessageForwarder(outbox: outbox))
            ), context: .init(roomID: self.targets(1)[0], kind: .group))
            await store.refresh()
            #expect(store.messages.count == 40)
            store.beginForwardSelection()
            for message in store.messages { store.toggleForwardSelection(for: message) }
            #expect(await store.forwardSelectedMessages(to: self.targets(1)))
            #expect(store.messageActionFeedback == "转发任务已保存，剩余消息会继续处理。")
            #expect(!store.isSelectingMessagesForForward)
            #expect(store.selectedForwardMessageIDs.isEmpty)
            let plan = try await outbox.plan(operationID: self.planID)
            #expect(plan?.state == .active)
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
            let outbox = self.engine(local, transport: transport)
            let room = self.targets(1)[0]
            let store = V2ConversationDetailStore(environment: .init(
                userID: room, projections: .init(dataSource: source),
                messages: .init(forwarder: V2OutboxMessageForwarder(outbox: outbox))
            ), context: .init(roomID: room, kind: .group))
            await store.refresh()
            store.beginForwardSelection(with: original)
            await source.setMessages(removed ? [] : [replacement])
            await store.refresh()
            #expect(store.selectedForwardMessageIDs == [id])
            #expect(await store.forwardSelectedMessages(to: [room]))
            let commands = await transport.commands
            #expect(commands.count == 1)
            let expected = V2ForwardMessageReference(roomID: try .init(room), messageID: try .init(id), revision: try .init(3))
            #expect(commands.first?.sources == [expected])
        }
    }

    private var planID: MessageForwardOperationID { get throws { try .init("00000000-0000-0000-0000-00000000f001") } }

    private func sources(_ count: Int) -> [String] {
        (1...count).map { String(format: "00000000-0000-0000-0000-%012x", $0) }
    }

    private func references(_ count: Int) throws -> [V2ForwardMessageReference] {
        try sources(count).map { .init(roomID: try .init(targets(1)[0]), messageID: try .init($0), revision: try .init(1)) }
    }

    private func targets(_ count: Int) -> [String] {
        (1...count).map { String(format: "00000000-0000-0000-0000-%012x", 0xf100 + $0) }
    }

    private func engine(_ local: GRDBV2LocalSyncStore, transport: ForwardOutcomeTransport) -> V2BulkForwardMessagesOutboxEngine {
        .init(store: local, transport: transport, makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-00000000f001")! }, now: { Date(timeIntervalSince1970: 200) })
    }

    private func withStore(_ body: @MainActor (GRDBV2LocalSyncStore, URL, V2LocalInstallationBinding) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-forward-outcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "main.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        do {
            try await body(local, url, binding)
            try await local.close()
        } catch {
            try? await local.close()
            throw error
        }
    }
}

private actor ForwardOutcomeTransport: V2ClientForwardMessagesTransport {
    enum Mode: Sendable { case success, mixed, reject, pending }
    private var mode: Mode
    private(set) var commands: [V2ForwardMessagesCommand] = []

    init(mode: Mode = .success) { self.mode = mode }
    func setMode(_ mode: Mode) { self.mode = mode }

    func forwardMessages(command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        commands.append(command)
        switch mode {
        case .reject: throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        case .pending: throw V2RealtimeTransportError.server(code: "FORWARD_PENDING", retryable: true, retryAfterSeconds: 60, currentRevision: nil)
        case .success, .mixed:
            return try command.sourceMessageIDs.enumerated().map { index, source in
                if mode == .mixed && index % 2 == 1 {
                    return try .init(sourceMessageID: source, targetRoomID: command.targetRoomIDs[0], messageID: nil, roomSequence: nil, errorCode: "FORBIDDEN")
                }
                return try .init(sourceMessageID: source, targetRoomID: command.targetRoomIDs[0], messageID: source, roomSequence: UInt64(index + 1), errorCode: nil)
            }
        }
    }
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
