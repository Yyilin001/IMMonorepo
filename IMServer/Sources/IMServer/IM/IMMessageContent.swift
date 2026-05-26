import Foundation
import Vapor

enum IMMessageContentType: String, Codable, Content, Sendable {
    case richText = "rich_text"
    case reply
    case recalled
    case system
    case image
    case audio
    case file
}

struct IMRichTextContent: Codable, Equatable, Content, Sendable {
    let text: String
    let entities: [IMTextEntity]

    init(text: String, entities: [IMTextEntity] = []) {
        self.text = text
        self.entities = entities
    }

    static func plain(_ text: String) -> IMRichTextContent {
        IMRichTextContent(text: text)
    }
}

struct IMTextRange: Codable, Equatable, Content, Sendable {
    let location: Int
    let length: Int
}

enum IMTextEntity: Equatable, Sendable {
    case link(range: IMTextRange, url: String)
    case mention(range: IMTextRange, userID: UUID)
    case hashtag(range: IMTextRange, value: String)
    case inlineCode(range: IMTextRange)

    var range: IMTextRange {
        switch self {
        case .link(let range, _), .mention(let range, _), .hashtag(let range, _), .inlineCode(let range):
            return range
        }
    }
}

extension IMTextEntity: Codable, Content {
    private enum CodingKeys: String, CodingKey {
        case kind
        case range
        case url
        case userID
        case value
    }

    private enum Kind: String, Codable {
        case link
        case mention
        case hashtag
        case inlineCode = "inline_code"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let range = try container.decode(IMTextRange.self, forKey: .range)

        switch kind {
        case .link:
            self = .link(range: range, url: try container.decode(String.self, forKey: .url))
        case .mention:
            self = .mention(range: range, userID: try container.decode(UUID.self, forKey: .userID))
        case .hashtag:
            self = .hashtag(range: range, value: try container.decode(String.self, forKey: .value))
        case .inlineCode:
            self = .inlineCode(range: range)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range, forKey: .range)

        switch self {
        case .link(_, let url):
            try container.encode(Kind.link, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .mention(_, let userID):
            try container.encode(Kind.mention, forKey: .kind)
            try container.encode(userID, forKey: .userID)
        case .hashtag(_, let value):
            try container.encode(Kind.hashtag, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .inlineCode:
            try container.encode(Kind.inlineCode, forKey: .kind)
        }
    }
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

enum IMMediaAssetKind: String, Codable, Content, Sendable {
    case image
    case audio
    case file
}

struct IMMediaAsset: Codable, Equatable, Content, Sendable {
    let assetID: String
    let kind: IMMediaAssetKind
    let mimeType: String
    let byteSize: Int64
    let filename: String
    let width: Int?
    let height: Int?
    let durationMillis: Int?
    let previewAssetID: String?
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
    case muteAll = "mute_all"
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
        case .muteAll:
            return "全员禁言"
        }
    }
}

enum IMMessageContent: Equatable, Sendable {
    case richText(IMRichTextContent)
    case reply(reference: IMReplyReference, body: IMRichTextContent)
    case recalled
    case system(IMSystemEvent)
    case image(IMMediaAsset)
    case audio(IMMediaAsset)
    case file(IMMediaAsset)

    var type: IMMessageContentType {
        switch self {
        case .richText:
            return .richText
        case .reply:
            return .reply
        case .recalled:
            return .recalled
        case .system:
            return .system
        case .image:
            return .image
        case .audio:
            return .audio
        case .file:
            return .file
        }
    }

    var previewText: String {
        presentation.previewText
    }

    var mediaAsset: IMMediaAsset? {
        presentation.mediaAsset
    }
}

extension IMMessageContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case body
        case reference
        case event
        case asset
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(IMMessageContentType.self, forKey: .type)

        switch type {
        case .richText:
            self = .richText(try container.decode(IMRichTextContent.self, forKey: .body))
        case .reply:
            let reference = try container.decode(IMReplyReference.self, forKey: .reference)
            let body = try container.decode(IMRichTextContent.self, forKey: .body)
            self = .reply(reference: reference, body: body)
        case .recalled:
            self = .recalled
        case .system:
            if let event = try container.decodeIfPresent(IMSystemEvent.self, forKey: .event) {
                self = .system(event)
            } else {
                throw DecodingError.keyNotFound(
                    CodingKeys.event,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing system event.")
                )
            }
        case .image:
            self = .image(try container.decode(IMMediaAsset.self, forKey: .asset))
        case .audio:
            self = .audio(try container.decode(IMMediaAsset.self, forKey: .asset))
        case .file:
            self = .file(try container.decode(IMMediaAsset.self, forKey: .asset))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)

        switch self {
        case .richText(let body):
            try container.encode(body, forKey: .body)
        case .reply(let reference, let body):
            try container.encode(reference, forKey: .reference)
            try container.encode(body, forKey: .body)
        case .recalled:
            return
        case .system(let event):
            try container.encode(event, forKey: .event)
        case .image(let asset), .audio(let asset), .file(let asset):
            try container.encode(asset, forKey: .asset)
        }
    }
}
