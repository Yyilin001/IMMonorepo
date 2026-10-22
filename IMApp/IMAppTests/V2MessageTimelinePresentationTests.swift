import Foundation
import MessagingTimelineCore
import Testing
@testable import IMApp

@MainActor
struct V2MessageTimelinePresentationTests {
    @Test func historyAndLiveUpdatesPreserveRendererIdentity() {
        let model = V2MessageTimelinePresentation()
        let identity = model.dataSource.id
        let middle = activity("middle", sequence: 2)
        #expect(model.apply([middle]))
        #expect(model.apply([activity("older", sequence: 1), middle]))
        #expect(model.dataSource.items.map(\.id) == ["activity-older", "activity-middle"])
        #expect(model.apply([activity("older", sequence: 1), middle, activity("newer", sequence: 3)]))
        let updated = activity("middle", sequence: 2, kind: .systemAccountReadOnly)
        #expect(model.apply([updated, activity("newer", sequence: 3)]))
        #expect(Array(model.dataSource.items) == [updated, activity("newer", sequence: 3)].map(V2MessageTimelineRow.committed))
        #expect(model.dataSource.id == identity)
    }

    @Test func duplicateSnapshotRetainsPreviousMessagesAndRecovers() {
        let model = V2MessageTimelinePresentation(), item = activity("one", sequence: 1)
        #expect(model.apply([item]))
        #expect(!model.apply([item, item]))
        #expect(model.hasInvalidSnapshot)
        #expect(Array(model.dataSource.items) == [.committed(item)])
        #expect(model.apply([]))
        #expect(!model.hasInvalidSnapshot)
        #expect(model.dataSource.items.isEmpty)
    }

    @Test func pendingMessagesAppearInTimelineAndLeaveAfterConfirmation() {
        let model = V2MessageTimelinePresentation()
        let pending = V2DurableConversationSendService.Pending(id: UUID(), createdAt: .now, text: "hello", completed: 0,
            total: 0, status: "正在发送", canRetry: false, retryTitle: "重试", canCancel: false)
        #expect(model.apply([], pending: [pending]))
        #expect(Array(model.dataSource.items) == [.pending(pending)])
        let identity = model.dataSource.id
        #expect(model.apply([activity("confirmed", sequence: 1)]))
        #expect(model.dataSource.items.count == 1)
        #expect(model.dataSource.items.first?.id == "activity-confirmed")
        #expect(model.dataSource.id == identity)
    }

    @Test func failuresAreMergedAtTheirOriginalTimesInsteadOfAfterNewMessages() {
        let model = V2MessageTimelinePresentation()
        let old = pending(at: 50), middle = pending(at: 150), newest = pending(at: 250)
        let first = activity("first", sequence: 1, createdAt: 100)
        let second = activity("second", sequence: 2, createdAt: 200)
        #expect(model.apply([first, second], pending: [newest, old, middle]))
        #expect(Array(model.dataSource.items) == [.pending(old), .committed(first), .pending(middle), .committed(second), .pending(newest)])
        let renderer = model.dataSource.id
        let changed = pending(id: middle.id, at: 150, status: "正在确认")
        #expect(model.apply([first, second], pending: [changed, newest, old]))
        #expect(model.dataSource.items.map(\.id) == [V2MessageTimelineRow.pending(old).id, first.id, V2MessageTimelineRow.pending(middle).id, second.id, V2MessageTimelineRow.pending(newest).id])
        #expect(model.dataSource.id == renderer)
    }

    @Test func equalTimestampsAreStableAndServerOrderSurvivesClockChanges() {
        let model = V2MessageTimelinePresentation()
        let a = pending(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, at: 100)
        let b = pending(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, at: 100)
        let first = activity("first", sequence: 1, createdAt: 200)
        let second = activity("second", sequence: 2, createdAt: 50)
        #expect(model.apply([first, second], pending: [b, a]))
        let original = Array(model.dataSource.items)
        #expect(original == [.pending(a), .pending(b), .committed(first), .committed(second)])
        #expect(model.apply([first, second], pending: [a, b]))
        #expect(Array(model.dataSource.items) == original)
    }

    @Test func acknowledgementReplacesPendingRowInOneRendererCommit() {
        let model = V2MessageTimelinePresentation()
        let history = activity("history", sequence: 1, createdAt: 10)
        let send = pending(at: 20, status: "等待发送")
        #expect(model.apply([history], pending: [send]))
        let renderer = model.dataSource.id
        let revision = model.dataSource.changeCounter
        let confirmed = activity("confirmed", sequence: 2, createdAt: 20)
        #expect(model.apply([history, confirmed]))
        #expect(model.dataSource.id == renderer)
        #expect(model.dataSource.changeCounter == revision + 1)
        #expect(Array(model.dataSource.items) == [.committed(history), .committed(confirmed)])
        // Reapplying the same observation must not issue another renderer write.
        #expect(model.apply([history, confirmed]))
        #expect(model.dataSource.changeCounter == revision + 1)
    }

    @Test func acknowledgementAndReadUpdateShareOneCommitWithoutMovingHistory() {
        let model = V2MessageTimelinePresentation()
        let history = activity("history", sequence: 1, createdAt: 10)
        let failed = pending(at: 15)
        let send = pending(at: 20, status: "等待发送")
        #expect(model.apply([history], pending: [failed, send]))
        let revision = model.dataSource.changeCounter
        let changedHistory = activity("history", sequence: 1, kind: .systemAccountReadOnly, createdAt: 10)
        let confirmed = activity("confirmed", sequence: 2, createdAt: 20)
        #expect(model.apply([changedHistory, confirmed], pending: [failed]))
        #expect(model.dataSource.changeCounter == revision + 1)
        #expect(Array(model.dataSource.items) == [.committed(changedHistory), .pending(failed), .committed(confirmed)])
    }

    @Test func invalidHandoffDoesNotRemoveVisiblePendingRow() {
        let model = V2MessageTimelinePresentation()
        let send = pending(at: 20)
        #expect(model.apply([], pending: [send]))
        let revision = model.dataSource.changeCounter
        let confirmed = activity("confirmed", sequence: 1, createdAt: 20)
        #expect(!model.apply([confirmed, confirmed]))
        #expect(model.dataSource.changeCounter == revision)
        #expect(Array(model.dataSource.items) == [.pending(send)])
        #expect(model.apply([confirmed]))
        #expect(model.dataSource.changeCounter == revision + 1)
    }

    private func pending(id: UUID = UUID(), at timestamp: TimeInterval, status: String = "发送失败") -> V2DurableConversationSendService.Pending {
        .init(id: id, createdAt: Date(timeIntervalSince1970: timestamp), text: "body", completed: 0,
            total: 0, status: status, canRetry: true, retryTitle: "重新发送", canCancel: true)
    }

    private func activity(_ id: String, sequence: UInt64,
                          kind: V2ConversationTimelineItem.Activity.Kind = .directMessageRestricted, createdAt: TimeInterval = 0) -> V2ConversationTimelineItem {
        .activity(.init(id: id, timelineSequence: sequence, kind: kind, createdAt: Date(timeIntervalSince1970: createdAt)))
    }
}
