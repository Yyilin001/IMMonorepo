import Foundation
import Vapor

enum IMMessageContentType: String, Codable, Content, Sendable {
    case text
    case reply
    case recalled
    case system
}

enum IMConversationAvatarPreset: String, Codable, Content, Sendable, CaseIterable {
    case sunrise
    case ocean
    case forest
    case graphite
}

struct IMReplyReference: Codable, Equatable, Content, Sendable {
    let messageID: String
    let senderUserID: UUID?
    let previewText: String
}

enum IMSystemEventType: String, Codable, Content, Sendable {
    case legacyText = "legacy_text"
    case groupCreated = "group_created"
    case membersAdded = "members_added"
    case memberRemoved = "member_removed"
    case memberLeft = "member_left"
    case roleUpdated = "role_updated"
    case ownershipTransferred = "ownership_transferred"
    case metadataUpdated = "metadata_updated"
}

enum IMConversationMetadataField: String, Codable, Content, Sendable {
    case title
    case notice
    case avatarPreset = "avatar_preset"
}

struct IMSystemEvent: Codable, Equatable, Content, Sendable {
    let type: IMSystemEventType
    let actorUserID: UUID?
    let actorEmail: String?
    let targetUserID: UUID?
    let targetEmail: String?
    let memberEmails: [String]
    let previousRole: IMConversationMemberRole?
    let newRole: IMConversationMemberRole?
    let updatedFields: [IMConversationMetadataField]
    let title: String?
    let notice: String?
    let avatarPreset: IMConversationAvatarPreset?
    let legacyText: String?

    init(
        type: IMSystemEventType,
        actorUserID: UUID? = nil,
        actorEmail: String? = nil,
        targetUserID: UUID? = nil,
        targetEmail: String? = nil,
        memberEmails: [String] = [],
        previousRole: IMConversationMemberRole? = nil,
        newRole: IMConversationMemberRole? = nil,
        updatedFields: [IMConversationMetadataField] = [],
        title: String? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil,
        legacyText: String? = nil
    ) {
        self.type = type
        self.actorUserID = actorUserID
        self.actorEmail = actorEmail
        self.targetUserID = targetUserID
        self.targetEmail = targetEmail
        self.memberEmails = memberEmails
        self.previousRole = previousRole
        self.newRole = newRole
        self.updatedFields = updatedFields
        self.title = title
        self.notice = notice
        self.avatarPreset = avatarPreset
        self.legacyText = legacyText
    }

    static func legacyText(_ text: String) -> IMSystemEvent {
        IMSystemEvent(type: .legacyText, legacyText: text)
    }

    var displayText: String {
        let actor = actorEmail ?? "系统"
        let target = targetEmail ?? "成员"

        switch type {
        case .legacyText:
            return legacyText ?? "系统消息"
        case .groupCreated:
            return "\(actor) 创建了群聊"
        case .membersAdded:
            let names = memberEmails.joined(separator: "、")
            return names.isEmpty ? "\(actor) 添加了新成员" : "\(actor) 添加了 \(names)"
        case .memberRemoved:
            return "\(actor) 移除了 \(target)"
        case .memberLeft:
            return "\(actor) 退出了群聊"
        case .roleUpdated:
            switch newRole {
            case .owner:
                return "\(actor) 已将群主转让给 \(target)"
            case .admin:
                return "\(actor) 将 \(target) 设为管理员"
            case .member:
                if previousRole == .admin {
                    return "\(actor) 取消了 \(target) 的管理员身份"
                }
                return "\(actor) 更新了 \(target) 的群角色"
            case nil:
                return "\(actor) 更新了 \(target) 的群角色"
            }
        case .ownershipTransferred:
            return "\(actor) 已将群主转让给 \(target)"
        case .metadataUpdated:
            let labels = updatedFields.map(\.displayLabel)
            if labels.isEmpty {
                return "\(actor) 更新了群资料"
            }
            return "\(actor) 更新了\(labels.joined(separator: "、"))"
        }
    }
}

private extension IMConversationMetadataField {
    var displayLabel: String {
        switch self {
        case .title:
            return "群名称"
        case .notice:
            return "群公告"
        case .avatarPreset:
            return "群头像"
        }
    }
}

enum IMMessageContent: Equatable, Sendable {
    case text(String)
    case reply(reference: IMReplyReference, text: String)
    case recalled
    case system(IMSystemEvent)

    var type: IMMessageContentType {
        switch self {
        case .text:
            return .text
        case .reply:
            return .reply
        case .recalled:
            return .recalled
        case .system:
            return .system
        }
    }

    var previewText: String {
        switch self {
        case .text(let text):
            return text
        case .reply(_, let text):
            return text
        case .recalled:
            return "撤回了一条消息"
        case .system(let event):
            return event.displayText
        }
    }
}

extension IMMessageContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case reference
        case event
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(IMMessageContentType.self, forKey: .type)

        switch type {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case .reply:
            let reference = try container.decode(IMReplyReference.self, forKey: .reference)
            let text = try container.decode(String.self, forKey: .text)
            self = .reply(reference: reference, text: text)
        case .recalled:
            self = .recalled
        case .system:
            if let event = try container.decodeIfPresent(IMSystemEvent.self, forKey: .event) {
                self = .system(event)
            } else {
                let text = try container.decode(String.self, forKey: .text)
                self = .system(.legacyText(text))
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)

        switch self {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .reply(let reference, let text):
            try container.encode(reference, forKey: .reference)
            try container.encode(text, forKey: .text)
        case .recalled:
            return
        case .system(let event):
            try container.encode(event, forKey: .event)
        }
    }
}
