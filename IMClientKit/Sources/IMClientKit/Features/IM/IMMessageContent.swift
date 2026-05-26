import Foundation

public enum IMMessageContentType: String, Codable, Equatable, Sendable {
    case richText = "rich_text"
    case reply
    case image
    case audio
    case file
}

public struct IMRichTextContent: Codable, Equatable, Sendable {
    public let text: String
    public let entities: [IMTextEntity]

    public init(text: String, entities: [IMTextEntity] = []) {
        self.text = text
        self.entities = entities
    }

    public static func plain(_ text: String) -> IMRichTextContent {
        IMRichTextContent(text: text)
    }
}

public struct IMTextRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public enum IMTextEntity: Equatable, Sendable {
    case link(range: IMTextRange, url: String)
    case mention(range: IMTextRange, userID: UUID)
    case hashtag(range: IMTextRange, value: String)
    case inlineCode(range: IMTextRange)

    public var range: IMTextRange {
        switch self {
        case .link(let range, _), .mention(let range, _), .hashtag(let range, _), .inlineCode(let range):
            return range
        }
    }
}

extension IMTextEntity: Codable {
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

    public init(from decoder: any Decoder) throws {
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

    public func encode(to encoder: any Encoder) throws {
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

public enum IMConversationAvatarPreset: String, Codable, Equatable, Sendable, CaseIterable {
    case sunrise
    case ocean
    case forest
    case graphite
}

public struct IMReplyReference: Codable, Equatable, Sendable {
    public let messageID: String
    public let senderUserID: UUID?
    public let previewText: String

    public init(messageID: String, senderUserID: UUID?, previewText: String) {
        self.messageID = messageID
        self.senderUserID = senderUserID
        self.previewText = previewText
    }
}

public enum IMMediaAssetKind: String, Codable, Equatable, Sendable {
    case image
    case audio
    case file
}

public struct IMMediaAsset: Codable, Equatable, Sendable, APIResponseBody {
    public let assetID: String
    public let kind: IMMediaAssetKind
    public let mimeType: String
    public let byteSize: Int64
    public let filename: String
    public let width: Int?
    public let height: Int?
    public let durationMillis: Int?
    public let previewAssetID: String?

    public init(
        assetID: String,
        kind: IMMediaAssetKind,
        mimeType: String,
        byteSize: Int64,
        filename: String,
        width: Int? = nil,
        height: Int? = nil,
        durationMillis: Int? = nil,
        previewAssetID: String? = nil
    ) {
        self.assetID = assetID
        self.kind = kind
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.filename = filename
        self.width = width
        self.height = height
        self.durationMillis = durationMillis
        self.previewAssetID = previewAssetID
    }
}

public enum IMMessageContent: Equatable, Sendable {
    case richText(IMRichTextContent)
    case reply(reference: IMReplyReference, body: IMRichTextContent)
    case image(IMMediaAsset)
    case audio(IMMediaAsset)
    case file(IMMediaAsset)

    public var type: IMMessageContentType {
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

    public var previewText: String {
        presentation.previewText
    }

    public var textValue: String? {
        presentation.textValue
    }

    public var replyReference: IMReplyReference? {
        presentation.replyReference
    }

    public var isUserComposable: Bool {
        presentation.isUserComposable
    }

    public var mediaAsset: IMMediaAsset? {
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

    public init(from decoder: any Decoder) throws {
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

    public func encode(to encoder: any Encoder) throws {
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
