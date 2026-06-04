import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

struct IMConversationListSnapshotTests {
    @Test func builderProjectsFilteredRowsWithoutExposingConversationObjects() throws {
        let directID = "11111111-1111-1111-1111-111111111111"
        let groupID = "22222222-2222-2222-2222-222222222222"
        let builder = IMConversationListSnapshotBuilder()
        let conversations = [
            makeConversation(
                id: directID,
                title: "Direct Raw",
                kind: .direct,
                memberCount: 2,
                unreadCount: 2,
                draftText: " later ",
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            makeConversation(
                id: groupID,
                title: "Group Raw",
                kind: .group,
                memberCount: 4,
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 90)
            )
        ]

        let snapshot = builder.build(
            conversations: conversations,
            selectedConversationID: directID,
            filter: .unread,
            generation: 7,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: "Presented \(conversation.title)",
                    detailSummary: "",
                    rowSecondaryLabel: conversation.kind == .direct ? "friend" : nil
                )
            },
            queueSummaryForConversationID: { conversationID in
                IMConversationQueueSummary(
                    queuedCount: 0,
                    sendingCount: 0,
                    retryableIssueCount: conversationID == groupID ? 1 : 0
                )
            }
        )

        #expect(snapshot.generation == 7)
        #expect(snapshot.filter == .unread)
        #expect(snapshot.rows.map(\.id) == [directID])

        let row = try #require(snapshot.rows.first)
        #expect(row.title == "Presented Direct Raw")
        #expect(row.rowSecondaryLabel == "friend")
        #expect(row.primaryPreviewText == "草稿: later")
        #expect(row.primaryPreviewTone == .draft)
        #expect(row.unreadCount == 2)
        #expect(row.isActive)
    }

    @Test func builderUsesRetryableIssueBeforeEmptyConversationFallback() throws {
        let groupID = "33333333-3333-3333-3333-333333333333"
        let snapshot = IMConversationListSnapshotBuilder().build(
            conversations: [
                makeConversation(
                    id: groupID,
                    title: "Group",
                    kind: .group,
                    memberCount: 5,
                    unreadCount: 0,
                    lastMessagePreviewText: "",
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ],
            selectedConversationID: nil,
            filter: .all,
            generation: 1,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: conversation.title,
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            },
            queueSummaryForConversationID: { _ in
                IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 1)
            }
        )

        let row = try #require(snapshot.rows.first)
        #expect(row.primaryPreviewText == "发送失败，点进会话重试")
        #expect(row.primaryPreviewTone == .failure)
    }

    @Test func builderAppliesGroupFilterInsideSnapshotProjection() {
        let directID = "44444444-4444-4444-4444-444444444444"
        let groupID = "55555555-5555-5555-5555-555555555555"
        let snapshot = IMConversationListSnapshotBuilder().build(
            conversations: [
                makeConversation(
                    id: directID,
                    title: "Direct",
                    kind: .direct,
                    memberCount: 2,
                    unreadCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 10)
                ),
                makeConversation(
                    id: groupID,
                    title: "Group",
                    kind: .group,
                    memberCount: 3,
                    unreadCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 20)
                )
            ],
            selectedConversationID: nil,
            filter: .groups,
            generation: 2,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: conversation.title,
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            },
            queueSummaryForConversationID: { _ in
                IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0)
            }
        )

        #expect(snapshot.rows.map(\.id) == [groupID])
        #expect(snapshot.rows.first?.kind == .group)
    }

    @MainActor
    @Test func storeProjectsListSnapshotFromCurrentState() throws {
        let directID = "66666666-6666-6666-6666-666666666666"
        let groupID = "77777777-7777-7777-7777-777777777777"
        let store = IMConversationStore()
        store.replaceConversationSummaries([
            IMConversationSummaryResponseBody(
                id: UUID(uuidString: directID)!,
                title: "Direct",
                kind: IMConversationKind.direct.rawValue,
                memberCount: 2,
                memberUserIDs: [],
                lastMessage: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            IMConversationSummaryResponseBody(
                id: UUID(uuidString: groupID)!,
                title: "Group",
                kind: IMConversationKind.group.rawValue,
                memberCount: 4,
                memberUserIDs: [],
                lastMessage: nil,
                lastReadSequence: 0,
                unreadCount: 1,
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        ])
        store.openConversation(id: groupID)

        let snapshot = store.conversationListSnapshot(
            filter: .groups,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: "Projected \(conversation.title)",
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )

        let row = try #require(snapshot.rows.first)
        #expect(snapshot.generation > 0)
        #expect(snapshot.rows.map(\.id) == [groupID])
        #expect(row.title == "Projected Group")
        #expect(row.isActive)
        #expect(row.unreadCount == 1)
    }

    private func makeConversation(
        id: String,
        title: String,
        kind: IMConversationKind,
        memberCount: Int,
        unreadCount: Int,
        lastMessagePreviewText: String = "hello",
        draftText: String = "",
        updatedAt: Date
    ) -> IMConversation {
        IMConversation(
            id: id,
            title: title,
            kind: kind,
            directPeer: kind == .direct ? IMDirectPeer(
                id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                email: "peer@example.com",
                displayName: "Peer",
                avatarPreset: .rose
            ) : nil,
            memberCount: memberCount,
            memberUserIDs: [],
            members: [],
            messages: [],
            lastMessagePreviewText: lastMessagePreviewText,
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: unreadCount,
            localUnreadDelta: 0,
            draftText: draftText,
            updatedAt: updatedAt
        )
    }
}
