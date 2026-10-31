import Foundation

/// A complete replacement of the connection's visible profile keys. Empty
/// removes all interests. Neither interest nor receipt grants profile access.
public struct V2AuthorPresentationInterests: Equatable, Sendable {
    public static let maximumAuthors = 128
    public let streamID: UUID
    public let viewID: UUID
    public let sequence: UInt64
    public let keys: [V2ProfileViewLookupKey]

    public init(streamID: UUID, viewID: UUID, sequence: UInt64, keys: [V2ProfileViewLookupKey]) throws {
        guard sequence > 0, sequence <= UInt64(Int64.max), keys.count <= Self.maximumAuthors,
              Set(keys).count == keys.count, keys.allSatisfy(\.isValidAuthorPresentationKey) else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        self.streamID = streamID; self.viewID = viewID; self.sequence = sequence; self.keys = keys
    }
}

extension V2ProfileViewLookupKey {
    var isValidAuthorPresentationKey: Bool {
        guard userID.uuidValue != nil else { return false }
        switch context {
        case .room(let room), .groupJoinReview(let room): return room.uuidValue != nil
        case .relationship, .directConversation: return true
        }
    }
}
