import Foundation
import Vapor

struct ConversationMetadataChangeSet: Equatable, Sendable {
    let normalizedTitle: String?
    let normalizedNotice: String?
    let requestedTitleUpdate: Bool
    let requestedNoticeUpdate: Bool
    let avatarPreset: IMConversationAvatarPreset?
}

struct ConversationGovernanceService {
    func makeMetadataChangeSet(
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?
    ) throws -> ConversationMetadataChangeSet {
        let normalizedTitle = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let normalizedTitle, title != nil, normalizedTitle.isEmpty {
            throw Abort(.badRequest, reason: "群聊名称不能为空。")
        }

        let normalizedNotice = notice.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let normalizedNotice, notice != nil, normalizedNotice.isEmpty {
            throw Abort(.badRequest, reason: "群公告不能为空。")
        }

        guard title != nil || notice != nil || avatarPreset != nil else {
            throw Abort(.badRequest, reason: "至少需要更新一项群资料。")
        }

        return ConversationMetadataChangeSet(
            normalizedTitle: normalizedTitle,
            normalizedNotice: normalizedNotice,
            requestedTitleUpdate: title != nil,
            requestedNoticeUpdate: notice != nil,
            avatarPreset: avatarPreset
        )
    }

    func apply(
        _ changeSet: ConversationMetadataChangeSet,
        to conversation: Conversation
    ) -> [IMConversationMetadataField] {
        var updatedFields: [IMConversationMetadataField] = []
        if changeSet.requestedTitleUpdate, conversation.title != changeSet.normalizedTitle {
            conversation.title = changeSet.normalizedTitle
            updatedFields.append(.title)
        }
        if changeSet.requestedNoticeUpdate, conversation.notice != changeSet.normalizedNotice {
            conversation.notice = changeSet.normalizedNotice
            updatedFields.append(.notice)
        }
        if let avatarPreset = changeSet.avatarPreset, conversation.avatarPresetEnum != avatarPreset {
            conversation.avatarPresetEnum = avatarPreset
            updatedFields.append(.avatarPreset)
        }
        return updatedFields
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
