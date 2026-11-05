import Foundation
import IMV2ClientKit
import IMV2Core

/// One in-memory timeline per visited room. The benchmark has no account services.
@MainActor
final class V2ConversationPerformanceChat: V2ConversationDataSource, V2ConversationSending {
    private var summary: V2ConversationListItem
    private var lastEvent: Int?
    private(set) var lastSent: (text: String, date: Date)?
    private var timeline: [V2ConversationTimelineItem] = []
    private let onSend: () async -> Void
    private static let user = "local-perf-user"

    init(summary: V2ConversationListItem, onSend: @escaping () async -> Void) {
        self.summary = summary
        self.onSend = onSend
    }

    func visit(_ item: V2ConversationListItem, event: Int) {
        summary = item
        guard lastEvent != event else { return }
        lastEvent = event
        append(item.preview, at: item.lastActivity, outgoing: item.isOutgoing)
    }

    func makeDetailStore() -> V2ConversationDetailStore {
        .init(environment: .init(userID: Self.user, projections: .init(dataSource: self), messages: .init(sender: self)),
              context: .init(roomID: summary.id, title: summary.title, kind: summary.kind))
    }

    @MainActor func conversationSummaryPage(for userID: String, isArchived: Bool, before cursor: V2ClientConversationListCursor?,
                                 limit: Int) async throws -> V2ConversationListPage {
        .init(items: !isArchived && cursor == nil && limit > 0 ? [summary] : [], nextCursor: nil)
    }

    @MainActor func timelinePage(in roomID: String, for userID: String, before cursor: V2ConversationTimelineCursor?,
                      limit: Int) async throws -> V2ConversationTimelinePage {
        guard roomID == summary.id else { return .init(items: [], olderCursor: nil) }
        let end = cursor.map { cursor in timeline.firstIndex { $0.cursor == cursor } ?? 0 } ?? timeline.count
        return page(max(0, end - max(0, limit))..<end)
    }

    @MainActor func timelineWindow(in roomID: String, for userID: String, around messageID: String,
                        before: Int, after: Int) async throws -> V2ConversationTimelineLocation {
        guard roomID == summary.id, let index = timeline.firstIndex(where: { $0.storageItemID == messageID }) else { return .unavailable }
        let end = index + 1 + min(timeline.count - index - 1, max(0, after))
        return .found(page: page(max(0, index - max(0, before))..<end),
                      newerBoundary: end < timeline.count ? timeline[end].cursor : nil)
    }

    private func page(_ range: Range<Int>) -> V2ConversationTimelinePage {
        let items = timeline[range]
        return .init(items: Array(items), olderCursor: range.lowerBound > 0 ? items.first?.cursor : nil)
    }

    @MainActor func send(text: String, media: [V2MediaReference], in roomID: String) async throws -> V2ConversationSendOutcome {
        try await send(text: text, media: media, mentions: [], in: roomID)
    }

    @MainActor func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], in roomID: String) async throws -> V2ConversationSendOutcome {
        try await send(text: text, media: media, mentions: mentions, entities: [], replyTo: nil, in: roomID)
    }

    @MainActor func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity],
              replyTo: V2MessageReplyReference?, in roomID: String) async throws -> V2ConversationSendOutcome {
        guard roomID == summary.id, media.isEmpty else { return .rejected(code: "local-perf-text-only") }
        let date = Date()
        append(text, at: date, outgoing: true, mentions: mentions, entities: entities, replyTo: replyTo)
        lastSent = (text, date)
        await onSend()
        return .accepted
    }

    private func append(_ text: String, at date: Date, outgoing: Bool, mentions: [V2MentionTarget] = [],
                        entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) {
        let seq = UInt64(timeline.count + 1)
        timeline.append(.message(.init(id: "\(summary.id)-\(seq)", roomSequence: seq, revision: 1, text: text,
                                       mentions: mentions, entities: entities, replyTo: replyTo, createdAt: date,
                                       isOutgoing: outgoing, isWithdrawn: false), timelineSequence: seq))
    }
}
