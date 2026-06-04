import Foundation
import IMClientKit
import Observation

struct IMConversationSnapshotCommitResult: Equatable {
    let didCommit: Bool
    let revision: UInt64
}

@MainActor
@Observable
final class IMConversationSnapshotStore {
    private(set) var listSnapshot = IMConversationListSnapshot(
        generation: 0,
        filter: .all,
        rows: []
    )
    private(set) var listCommitRevision: UInt64 = 0

    private var chatPageSnapshots: [String: IMChatPageSnapshot] = [:]
    private var chatPageCommitRevisions: [String: UInt64] = [:]

    func commitListSnapshot(
        from conversationStore: IMConversationStore,
        filter: IMConversationListFilter,
        identityForConversation: (IMConversation) -> IMConversationIdentityPresentation
    ) -> IMConversationSnapshotCommitResult {
        let snapshot = conversationStore.conversationListSnapshot(
            filter: filter,
            identityForConversation: identityForConversation
        )
        guard snapshot != listSnapshot else {
            return IMConversationSnapshotCommitResult(
                didCommit: false,
                revision: listCommitRevision
            )
        }

        listSnapshot = snapshot
        listCommitRevision += 1
        return IMConversationSnapshotCommitResult(
            didCommit: true,
            revision: listCommitRevision
        )
    }

    func commitChatPageSnapshot(
        from conversationStore: IMConversationStore,
        conversationID: String,
        currentUserID: UUID?,
        blockedUserIDs: Set<UUID>
    ) -> IMConversationSnapshotCommitResult {
        let snapshot = conversationStore.chatPageSnapshot(
            for: conversationID,
            currentUserID: currentUserID,
            blockedUserIDs: blockedUserIDs
        )
        let revision = chatPageCommitRevisions[conversationID] ?? 0
        guard snapshot != chatPageSnapshots[conversationID] else {
            return IMConversationSnapshotCommitResult(
                didCommit: false,
                revision: revision
            )
        }

        chatPageSnapshots[conversationID] = snapshot
        let nextRevision = revision + 1
        chatPageCommitRevisions[conversationID] = nextRevision
        return IMConversationSnapshotCommitResult(
            didCommit: true,
            revision: nextRevision
        )
    }

    func chatPageSnapshot(for conversationID: String) -> IMChatPageSnapshot {
        chatPageSnapshots[conversationID] ?? Self.emptyChatPageSnapshot(
            conversationID: conversationID,
            generation: 0
        )
    }

    func chatPageCommitRevision(for conversationID: String) -> UInt64 {
        chatPageCommitRevisions[conversationID] ?? 0
    }

    private static func emptyChatPageSnapshot(
        conversationID: String,
        generation: UInt64
    ) -> IMChatPageSnapshot {
        IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: generation,
            conversations: [],
            queueSummary: IMConversationQueueSummary(
                queuedCount: 0,
                sendingCount: 0,
                retryableIssueCount: 0
            ),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: nil,
            blockedUserIDs: []
        )
    }
}
