import Foundation
import IMV2Core

public struct V2UserRoomDirectoryPage: Sendable {
    public let rooms: [V2UserRoomDirectoryEntry]
    public let nextCursor: String?
    public let topologyGeneration: String

    package init(rooms: [V2UserRoomDirectoryEntry], nextCursor: String?, topologyGeneration: String) {
        self.rooms = rooms
        self.nextCursor = nextCursor
        self.topologyGeneration = topologyGeneration
    }
}

/// One authoritative page, including its topology generation.
public struct V2RoomRecoveryDirectorySnapshot: Sendable {
    public let generation: String
    public let slice: V2UserRoomDirectorySlice
    public init(generation: String, slice: V2UserRoomDirectorySlice) throws {
        guard !generation.isEmpty, generation.utf8.count <= 128 else { throw V2RoomRecoveryReadError.invalidRequest }
        self.generation = generation; self.slice = slice
    }
}
public protocol V2RoomRecoveryDirectoryReading: Sendable {
    var storeCount: Int { get }
    func snapshot(actorUserID: UserID, after: RoomID?, limit: Int, storeIndex: Int) async throws -> V2RoomRecoveryDirectorySnapshot
}
