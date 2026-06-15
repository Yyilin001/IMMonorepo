import Fluent
import Foundation
import Vapor

struct ConversationTimelineNoticeProjectionConsumer: ConversationEventConsumer {
    let db: any Database
    let app: Application?

    var supportedEventTypes: Set<ConversationDomainEventType> {
        [
            .metadataUpdated,
            .membershipAdded,
            .membershipRemoved,
            .membershipRoleUpdated,
            .directPeerUpdated,
            .conversationVisibilityChanged,
            .conversationSettingsChanged,
            .inviteChanged
        ]
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard let eventID = envelope.eventID,
              let notice = try makeNotice(envelope: envelope, eventID: eventID)
        else {
            return
        }

        if let existing = try await ConversationTimelineNotice.find(eventID, on: db) {
            existing.timelineSequence = notice.timelineSequence
            existing.eventType = notice.eventType
            existing.actorUserID = notice.actorUserID
            try existing.replaceTargetUserIDs(try notice.targetUserIDs)
            existing.noticeKind = notice.noticeKind
            try existing.replaceParams(try notice.params)
            existing.fallbackText = notice.fallbackText
            existing.createdAt = notice.createdAt
            try await existing.update(on: db)
        } else {
            try await notice.create(on: db)
        }
        app?.invalidateTimelineSinceHotCache(conversationID: envelope.conversationID)
    }

    private func makeNotice(
        envelope: ConversationEventEnvelope,
        eventID: UUID
    ) throws -> ConversationTimelineNotice? {
        guard envelope.event.aggregateSequence > 0 else {
            throw Abort(.internalServerError, reason: "Timeline notice 缺少 timeline sequence。")
        }

        let targetUserIDs = envelope.payload.recipientUserIDs
        guard !targetUserIDs.isEmpty else {
            return nil
        }

        let kind: String
        let fallbackText: String
        switch envelope.eventType {
        case .membershipAdded:
            kind = "member_added"
            fallbackText = "成员已加入会话"
        case .membershipRemoved:
            kind = "member_removed"
            fallbackText = "成员已离开会话"
        case .membershipRoleUpdated:
            kind = "member_role_updated"
            fallbackText = "成员角色已更新"
        case .metadataUpdated:
            kind = "metadata_updated"
            fallbackText = "会话信息已更新"
        case .directPeerUpdated:
            kind = "direct_peer_updated"
            fallbackText = "联系人状态已更新"
        case .conversationVisibilityChanged:
            kind = "conversation_visibility_changed"
            fallbackText = "会话可见性已更新"
        case .conversationSettingsChanged:
            kind = "conversation_settings_changed"
            fallbackText = "会话设置已更新"
        case .inviteChanged:
            kind = "invite_changed"
            fallbackText = "邀请链接已更新"
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
             .readAdvanced,
             .messageVisibilityChanged,
             .messageFavoriteChanged,
             .conversationRemovedForUser:
            return nil
        }

        return try ConversationTimelineNotice(
            eventID: eventID,
            conversationID: envelope.conversationID,
            timelineSequence: envelope.event.aggregateSequence,
            eventType: envelope.event.eventType,
            actorUserID: envelope.event.actorUserID,
            targetUserIDs: targetUserIDs,
            noticeKind: kind,
            params: noticeParams(envelope: envelope, targetUserIDs: targetUserIDs),
            fallbackText: fallbackText,
            createdAt: envelope.event.createdAt
        )
    }

    private func noticeParams(
        envelope: ConversationEventEnvelope,
        targetUserIDs: [UUID]
    ) -> [String: String] {
        var params: [String: String] = [
            "conversationID": envelope.conversationID.uuidString,
            "targetUserIDs": targetUserIDs.map(\.uuidString).joined(separator: ",")
        ]
        if let actorUserID = envelope.event.actorUserID {
            params["actorUserID"] = actorUserID.uuidString
        }
        return params
    }
}
