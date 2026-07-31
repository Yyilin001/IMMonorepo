import Foundation

/// A portable formatting span. Ranges use UTF-16 offsets so they round-trip
/// across Apple, web and protobuf clients without depending on grapheme
/// segmentation rules.
public struct V2MessageEntity: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bold
        case italic
        case underline
        case strikethrough
        case spoiler
        case code
        case preformatted
        case link
    }

    public let offsetUTF16: Int
    public let lengthUTF16: Int
    public let kind: Kind
    /// Only `.link` carries a destination. It is limited to HTTP(S) so message
    /// rendering never turns untrusted text into an executable deep link.
    public let linkURL: URL?

    public init(offsetUTF16: Int, lengthUTF16: Int, kind: Kind, linkURL: URL? = nil) throws {
        guard offsetUTF16 >= 0, lengthUTF16 > 0 else { throw V2RichMessageContentError.invalidEntity }
        switch kind {
        case .link:
            guard let linkURL,
                  let scheme = linkURL.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  linkURL.host != nil
            else { throw V2RichMessageContentError.invalidEntity }
        default:
            guard linkURL == nil else { throw V2RichMessageContentError.invalidEntity }
        }
        self.offsetUTF16 = offsetUTF16
        self.lengthUTF16 = lengthUTF16
        self.kind = kind
        self.linkURL = linkURL
    }
}

public struct V2MessageReplyReference: Hashable, Codable, Sendable {
    public let messageID: MessageID

    public init(messageID: MessageID) {
        self.messageID = messageID
    }
}

public enum V2RichMessageContent {
    public static let maxEntities = 100

    public static func validate(text: String, entities: [V2MessageEntity]) throws {
        guard entities.count <= maxEntities, Set(entities).count == entities.count else {
            throw V2RichMessageContentError.invalidEntity
        }
        let length = text.utf16.count
        for entity in entities {
            let end = entity.offsetUTF16 + entity.lengthUTF16
            guard end <= length else { throw V2RichMessageContentError.invalidEntity }
            guard let range = Range(NSRange(location: entity.offsetUTF16, length: entity.lengthUTF16), in: text),
                  text[..<range.lowerBound].utf16.count == entity.offsetUTF16,
                  text[range].utf16.count == entity.lengthUTF16
            else { throw V2RichMessageContentError.invalidEntity }
        }
    }
}

public enum V2RichMessageContentError: Error, Equatable, Sendable {
    case invalidEntity
}
