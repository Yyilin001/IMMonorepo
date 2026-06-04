import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

@MainActor
struct IMConversationSnapshotStoreTests {
    private let currentUserID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let peerUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func listSnapshotRefreshCommitsCurrentStoreState() throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Project Room",
                kind: .group,
                unreadCount: 2
            )
        ])

        let initialCommit = snapshotStore.commitListSnapshot(
            from: conversationStore,
            filter: .all,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: "Projected \(conversation.title)",
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )
        #expect(initialCommit.didCommit)
        #expect(initialCommit.revision == 1)
        #expect(snapshotStore.listCommitRevision == 1)

        let committed = snapshotStore.listSnapshot
        let row = try #require(committed.rows.first)
        #expect(row.id == conversationID.uuidString)
        #expect(row.title == "Projected Project Room")
        #expect(row.unreadCount == 2)

        let repeatedCommit = snapshotStore.commitListSnapshot(
            from: conversationStore,
            filter: .all,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: "Projected \(conversation.title)",
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )
        #expect(!repeatedCommit.didCommit)
        #expect(repeatedCommit.revision == 1)
        #expect(snapshotStore.listCommitRevision == 1)

        conversationStore.setConversationSearchText("missing")

        #expect(snapshotStore.listSnapshot.rows.map(\.id) == [conversationID.uuidString])

        let filteredCommit = snapshotStore.commitListSnapshot(
            from: conversationStore,
            filter: .all,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: conversation.title,
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )
        #expect(filteredCommit.didCommit)
        #expect(filteredCommit.revision == 2)
        #expect(snapshotStore.listCommitRevision == 2)

        #expect(snapshotStore.listSnapshot.rows.isEmpty)
    }

    @Test func chatSnapshotRefreshCommitsLoadingAndQueueState() {
        let conversationID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Direct",
                kind: .direct,
                unreadCount: 0
            )
        ])
        conversationStore.setLoadingMessages(true)

        let initialCommit = snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        #expect(initialCommit.didCommit)
        #expect(initialCommit.revision == 1)
        #expect(snapshotStore.chatPageCommitRevision(for: conversationID.uuidString) == 1)

        #expect(snapshotStore.chatPageSnapshot(for: conversationID.uuidString).shouldShowLoadingState)

        let repeatedCommit = snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        #expect(!repeatedCommit.didCommit)
        #expect(repeatedCommit.revision == 1)
        #expect(snapshotStore.chatPageCommitRevision(for: conversationID.uuidString) == 1)

        conversationStore.setLoadingMessages(false)
        conversationStore.queueOutgoingText(
            "queued",
            conversationID: conversationID.uuidString,
            senderUserID: currentUserID
        )

        let staleSnapshot = snapshotStore.chatPageSnapshot(for: conversationID.uuidString)
        #expect(staleSnapshot.shouldShowLoadingState)
        #expect(staleSnapshot.queueSummary.queuedCount == 0)

        let refreshedCommit = snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        #expect(refreshedCommit.didCommit)
        #expect(refreshedCommit.revision == 2)
        #expect(snapshotStore.chatPageCommitRevision(for: conversationID.uuidString) == 2)

        let refreshedSnapshot = snapshotStore.chatPageSnapshot(for: conversationID.uuidString)
        #expect(!refreshedSnapshot.shouldShowLoadingState)
        #expect(refreshedSnapshot.queueSummary.queuedCount == 1)
        #expect(refreshedSnapshot.latestTimelineItemIsCurrentUserOutgoing)
    }

    private func makeSummary(
        id: UUID,
        title: String,
        kind: IMConversationKind,
        unreadCount: Int
    ) -> IMConversationSummaryResponseBody {
        IMConversationSummaryResponseBody(
            id: id,
            title: title,
            kind: kind.rawValue,
            memberCount: 2,
            memberUserIDs: [currentUserID, peerUserID],
            lastMessage: nil,
            lastReadSequence: 0,
            unreadCount: unreadCount,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
