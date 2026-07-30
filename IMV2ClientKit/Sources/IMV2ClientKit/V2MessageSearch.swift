import Foundation
import IMV2Core

/// The searchable scope is deliberately expressed with domain identifiers so
/// a caller can not accidentally mix a room ID with a user ID at the storage
/// boundary.
public enum V2MessageSearchScope: Equatable, Sendable {
    case room(RoomID)
    case allMessages
    case sender(UserID)
}

public struct V2MessageSearchCursor: Equatable, Sendable {
    enum Storage: Equatable, Sendable {
        case room(roomID: RoomID, roomSequence: UInt64, messageID: MessageID)
        case global(createdAt: Date, messageID: MessageID)
    }

    let storage: Storage
}

public struct V2MessageSearchRequest: Equatable, Sendable {
    public let query: String
    public let scope: V2MessageSearchScope
    public let limit: Int
    public let cursor: V2MessageSearchCursor?

    public init(
        query: String,
        scope: V2MessageSearchScope = .allMessages,
        limit: Int = 50,
        cursor: V2MessageSearchCursor? = nil
    ) {
        self.query = query
        self.scope = scope
        self.limit = limit
        self.cursor = cursor
    }
}

public struct V2MessageSearchHit: Equatable, Sendable, Identifiable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let senderUserID: UserID
    public let text: String
    public let createdAt: Date

    public var id: MessageID { messageID }

    public init(
        messageID: MessageID,
        roomID: RoomID,
        roomSequence: UInt64,
        senderUserID: UserID,
        text: String,
        createdAt: Date
    ) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.senderUserID = senderUserID
        self.text = text
        self.createdAt = createdAt
    }
}

public struct V2MessageSearchPage: Equatable, Sendable {
    public let hits: [V2MessageSearchHit]
    public let nextCursor: V2MessageSearchCursor?

    public init(hits: [V2MessageSearchHit], nextCursor: V2MessageSearchCursor?) {
        self.hits = hits
        self.nextCursor = nextCursor
    }
}

public enum V2MessageSearchIndexState: Equatable, Sendable {
    case building
    case ready
    case failed

    init?(storageValue: String) {
        switch storageValue {
        case "building": self = .building
        case "ready": self = .ready
        case "failed": self = .failed
        default: return nil
        }
    }
}

public enum V2MessageSearchError: Error, Equatable, Sendable {
    case emptyQuery
    case invalidPageSize
    case indexUnavailable(V2MessageSearchIndexState)
    case cursorDoesNotMatchScope
}

/// Search semantics are defined here, instead of being an accidental property
/// of SQLite's tokenizer. The byte encoding makes every extended grapheme
/// cluster (including punctuation and emoji) one safe FTS token.
struct V2CharacterGramTokenizer: Sendable {
    static let version = 1

    struct Tokens: Equatable, Sendable {
        let normalized: String
        let unigrams: [String]
        let bigrams: [String]

        var characterCount: Int { unigrams.count }
    }

    func tokenize(_ input: String) -> Tokens {
        let normalized = Self.normalize(input)
        let characters = Array(normalized)
        let unigrams = characters.map { Self.token(prefix: "u1", text: String($0)) }
        let bigrams = zip(characters, characters.dropFirst()).map {
            Self.token(prefix: "u2", text: String($0.0) + String($0.1))
        }
        return .init(normalized: normalized, unigrams: unigrams, bigrams: bigrams)
    }

    static func normalize(_ input: String) -> String {
        input.precomposedStringWithCompatibilityMapping.lowercased()
    }

    static func scopeToken(prefix: String, identifier: String) -> String {
        token(prefix: prefix, text: identifier)
    }

    private static func token(prefix: String, text: String) -> String {
        prefix + hex(text.utf8)
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
