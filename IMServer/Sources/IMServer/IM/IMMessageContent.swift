import Foundation
import Vapor

enum IMMessageContentType: String, Codable, Content, Sendable {
    case richText = "rich_text"
    case reply
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

enum IMMessageContent: Equatable, Sendable {
    case richText(IMRichTextContent)
    case reply(reference: IMReplyReference, body: IMRichTextContent)
    case image(IMMediaAsset)
    case audio(IMMediaAsset)
    case file(IMMediaAsset)

    var type: IMMessageContentType {
        switch self {
        case .richText:
            return .richText
        case .reply:
            return .reply
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
        case .image(let asset), .audio(let asset), .file(let asset):
            try container.encode(asset, forKey: .asset)
        }
    }
}
