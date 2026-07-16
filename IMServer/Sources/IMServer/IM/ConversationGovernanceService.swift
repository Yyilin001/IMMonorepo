import Foundation
import Vapor

struct ConversationMetadataChangeSet: Equatable, Sendable {
    let normalizedTitle: String?
    let normalizedNotice: String?
    let requestedTitleUpdate: Bool
    let requestedNoticeUpdate: Bool
    let avatarPreset: IMConversationAvatarPreset?
    let muteAll: Bool?
}

struct ConversationGovernanceService {
    func requireUserMutationAllowed(in conversation: Conversation) throws {
        guard conversation.conversationKind == .group else {
            return
        }
        switch conversation.groupLifecycleStateEnum {
        case .active:
            return
        case .frozen:
            throw Abort(.forbidden, reason: "群聊已被冻结，成员只能查看历史消息。")
        case .dissolved:
            throw Abort(.forbidden, reason: "群聊已解散，消息记录仅供查看。")
        }
    }

    func requireMembershipArchivalMutationAllowed(in conversation: Conversation) throws {
        guard conversation.conversationKind != .group || conversation.groupLifecycleStateEnum != .dissolved else {
            throw Abort(.forbidden, reason: "群聊已解散，成员关系已归档。")
        }
    }

    func makeMetadataChangeSet(
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        muteAll: Bool?
    ) throws -> ConversationMetadataChangeSet {
        let normalizedTitle = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let normalizedTitle, title != nil, normalizedTitle.isEmpty {
            throw Abort(.badRequest, reason: "群聊名称不能为空。")
        }

        let normalizedNotice = notice.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let normalizedNotice, notice != nil, normalizedNotice.isEmpty {
            throw Abort(.badRequest, reason: "群公告不能为空。")
        }

        guard title != nil || notice != nil || avatarPreset != nil || muteAll != nil else {
            throw Abort(.badRequest, reason: "至少需要更新一项群资料。")
        }

        return ConversationMetadataChangeSet(
            normalizedTitle: normalizedTitle,
            normalizedNotice: normalizedNotice,
            requestedTitleUpdate: title != nil,
            requestedNoticeUpdate: notice != nil,
            avatarPreset: avatarPreset,
            muteAll: muteAll
        )
    }

    func apply(
        _ changeSet: ConversationMetadataChangeSet,
        to conversation: Conversation
    ) -> Bool {
        var didUpdate = false
        if changeSet.requestedTitleUpdate, conversation.title != changeSet.normalizedTitle {
            conversation.title = changeSet.normalizedTitle
            didUpdate = true
        }
        if changeSet.requestedNoticeUpdate, conversation.notice != changeSet.normalizedNotice {
            conversation.notice = changeSet.normalizedNotice
            didUpdate = true
        }
        if let avatarPreset = changeSet.avatarPreset, conversation.avatarPresetEnum != avatarPreset {
            conversation.avatarPresetEnum = avatarPreset
            didUpdate = true
        }
        if let muteAll = changeSet.muteAll, conversation.muteAll != muteAll {
            conversation.muteAll = muteAll
            didUpdate = true
        }
        return didUpdate
    }

    func validateMemberRemovalPrivilege(
        requesterRole: IMConversationMemberRole,
        targetRole: IMConversationMemberRole
    ) throws {
        switch requesterRole {
        case .owner:
            if targetRole == .owner {
                throw Abort(.badRequest, reason: "不能移除群主。")
            }
        case .admin:
            switch targetRole {
            case .owner:
                throw Abort(.forbidden, reason: "不能移除群主。")
            case .admin:
                throw Abort(.forbidden, reason: "管理员不能移除其他管理员。")
            case .member:
                return
            }
        case .member:
            throw Abort(.forbidden, reason: "当前角色没有移除该成员的权限。")
        }
    }
}
