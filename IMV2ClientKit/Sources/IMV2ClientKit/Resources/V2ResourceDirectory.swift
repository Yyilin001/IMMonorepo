import Foundation
import IMV2Core

public enum V2ResourceReferenceContext: Hashable, Sendable {
    case message(V2MediaMessageLocation, ordinal: Int)
    case userAvatar(UserID)
    case groupAvatar(RoomID)
}

public struct V2ResourceDirectoryEntry: Equatable, Sendable {
    public enum LocalState: String, Sendable { case available, needsDownload, invalid }
    public let descriptor: V2ResourceDescriptor
    public let indexedAt: Date
    public let referenceCount: Int
    public let isRetained: Bool
    public let localState: LocalState
}

public struct V2ResourceDirectoryCursor: Equatable, Sendable {
    public let indexedAt: Date
    public let key: V2ResourceKey
}

public struct V2ResourceDirectoryPage: Equatable, Sendable {
    public let entries: [V2ResourceDirectoryEntry]
    public let nextCursor: V2ResourceDirectoryCursor?
    public let isIndexing: Bool
    public init(entries: [V2ResourceDirectoryEntry], nextCursor: V2ResourceDirectoryCursor?, isIndexing: Bool = false) {
        self.entries = entries; self.nextCursor = nextCursor; self.isIndexing = isIndexing
    }
}
