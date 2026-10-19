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
        let pending = V2DurableConversationSendService.Pending(id: UUID(), text: "hello", completed: 0,
            total: 0, status: "正在发送", canRetry: false, retryTitle: "重试", canCancel: false)
        #expect(model.apply([], pending: [pending]))
        #expect(Array(model.dataSource.items) == [.pending(pending)])
        let identity = model.dataSource.id
        #expect(model.apply([activity("confirmed", sequence: 1)]))
        #expect(model.dataSource.items.count == 1)
        #expect(model.dataSource.items.first?.id == "activity-confirmed")
        #expect(model.dataSource.id == identity)
    }

    private func activity(_ id: String, sequence: UInt64,
                          kind: V2ConversationTimelineItem.Activity.Kind = .directMessageRestricted) -> V2ConversationTimelineItem {
        .activity(.init(id: id, timelineSequence: sequence, kind: kind, createdAt: Date(timeIntervalSince1970: 0)))
    }
}
