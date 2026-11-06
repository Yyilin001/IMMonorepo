import IMV2Core
import Foundation
import Testing
@testable import IMApp

@MainActor
struct V2ConversationSnapshotTests {
    @Test("后台搜索保留排序并且不索引私聊身份")
    func searchPreservesOrderAndIdentityBoundary() async throws {
        let builder = V2ConversationListSnapshotBuilder()
        let rows = [item("first", title: "needle", kind: .group),
                    item("private", title: "needle", kind: .direct(accountKind: .regular)), item("preview", preview: "needle")]
        let snapshot = try await builder.build(.init(conversations: rows, pending: [], query: " needle "))
        #expect(snapshot.rows.map(\.id) == [.conversation("first"), .conversation("preview")])
        let all = try await builder.build(.init(conversations: rows, pending: [], query: "  "))
        #expect(all.rows.map(\.id) == rows.map { .conversation($0.id) })
    }

    @Test("同帧只提交最新完成快照，连续输入不会阻止显示帧提交")
    func latestSnapshotWins() async throws {
        let frames = V2ConversationFrameDriver(automatic: false)
        let presentation = V2ConversationSnapshotPresentation(frames: frames)
        presentation.submit(.init(conversations: [item("old")], pending: [], query: ""))
        let consumer = Task { await presentation.run() }
        defer { consumer.cancel() }
        try await waitUntil { presentation.stagedCount == 1 }
        presentation.submit(.init(conversations: [item("new")], pending: [], query: ""))
        try await waitUntil { presentation.stagedCount == 2 }
        #expect(presentation.snapshot == .empty)
        frames.commitFrame()
        #expect(presentation.snapshot.rows.map(\.id) == [.conversation("new")])
        #expect(!frames.hasPendingFrame)
        consumer.cancel()
        await consumer.value
    }

    @Test("离页取消丢弃暂存快照，重新进入后消费最新输入")
    func cancellationDiscardsPendingSnapshot() async throws {
        let frames = V2ConversationFrameDriver(automatic: false)
        let presentation = V2ConversationSnapshotPresentation(frames: frames)
        presentation.submit(.init(conversations: [item("cancelled")], pending: [], query: ""))
        let consumer = Task { await presentation.run() }
        defer { consumer.cancel() }
        try await waitUntil { frames.hasPendingFrame }
        consumer.cancel()
        await consumer.value
        #expect(!frames.hasPendingFrame)
        frames.commitFrame()
        #expect(presentation.snapshot == .empty)
        presentation.submit(.init(conversations: [item("resumed")], pending: [], query: ""))
        let resumed = Task { await presentation.run() }
        defer { resumed.cancel() }
        try await waitUntil { frames.hasPendingFrame }
        frames.commitFrame()
        #expect(presentation.snapshot.rows.map(\.id) == [.conversation("resumed")])
        resumed.cancel()
        await resumed.value
    }

    private func item(_ id: String, title: String = "chat", preview: String = "text",
                      kind: V2ConversationKind = .group) -> V2ConversationListItem {
        .init(id: id, title: title, preview: preview, lastActivity: .distantPast, isOutgoing: false, kind: kind)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard .now < deadline else { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private enum WaitError: Error { case timedOut }
}
