import Fluent
import Foundation
import Vapor

enum ConversationSummaryResponseOverlay {
    static func response(
        from summary: ConversationUserSummary,
        activity: ConversationActivitySummary? = nil,
        memberUserIDsLimit: Int = 0
    ) -> IMConversationResponse {
        let summaryLastMessage = summary.lastMessage
        let activityLastMessage = activity?.lastMessage
        let summaryLastSequence = summaryLastMessage?.serverSequence ?? 0
        let activityLastSequence = UInt64(max(0, activity?.lastMessageServerSequence ?? 0))
        let useActivityMessage = activityLastMessage != nil && activityLastSequence >= summaryLastSequence
        let lastMessage = useActivityMessage ? activityLastMessage : summaryLastMessage
        let lastActivityAt = useActivityMessage
            ? (activity?.lastActivityAt ?? summary.lastActivityAt)
            : max(summary.lastActivityAt, activity?.lastActivityAt ?? summary.lastActivityAt)
        let activityUnreadCount: UInt64
        if activityLastSequence > UInt64(summary.lastReadSequence) {
            activityUnreadCount = activityLastSequence - UInt64(summary.lastReadSequence)
        } else {
            activityUnreadCount = 0
        }
        let unreadCount = max(summary.unreadCount, Int(clamping: activityUnreadCount))

        let memberUserIDs = memberUserIDsForResponse(
            summary: summary,
            limit: memberUserIDsLimit
        )

        return IMConversationResponse(
            id: summary.conversationID,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeerUserID.map { directPeerUserID in
                IMDirectPeerResponse(
                    id: directPeerUserID,
                    email: summary.directPeerEmail ?? "",
                    displayName: summary.directPeerDisplayName,
                    avatarPreset: summary.directPeerAvatarPresetEnum
                )
            },
            notice: summary.notice,
            avatarPreset: summary.avatarPresetEnum,
            muteAll: summary.muteAll,
            memberCount: summary.memberCount,
            memberUserIDs: memberUserIDs,
            lastMessage: lastMessage,
            lastReadSequence: UInt64(summary.lastReadSequence),
            unreadCount: unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: nil,
            updatedAt: lastActivityAt
        )
    }

    static func responseLoadingActivity(
        from summary: ConversationUserSummary,
        on database: any Database,
        memberUserIDsLimit: Int = 0
    ) async throws -> IMConversationResponse {
        let activity = try await ConversationActivitySummary.find(summary.conversationID, on: database)
        return response(
            from: summary,
            activity: activity,
            memberUserIDsLimit: memberUserIDsLimit
        )
    }

    static func memberUserIDsForResponse(
        summary: ConversationUserSummary,
        limit: Int
    ) -> [UUID] {
        guard limit > 0, summary.memberCount > limit else {
            return summary.memberUserIDs.sorted { $0.uuidString < $1.uuidString }
        }
        return []
    }
}
