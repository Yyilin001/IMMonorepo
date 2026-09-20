import Foundation
import IMV2Core

public struct V2UserRoomDirectoryPage: Sendable {
    public let rooms: [V2UserRoomDirectoryEntry]
    public let nextCursor: String?
    public let topologyGeneration: String
}

/// Physical stores must be deduplicated and ordered consistently within a generation.
public struct V2RoomRecoveryTopology: Sendable {
    public let generation: String
    public let stores: [any V2UserRoomDirectoryReading]

    public init(generation: String, stores: [any V2UserRoomDirectoryReading]) throws {
        guard !generation.isEmpty, generation.utf8.count <= 128, !stores.isEmpty,
              stores.count <= Int(Int32.max) else { throw V2RoomRecoveryReadError.invalidRequest }
        self.generation = generation
        self.stores = stores
    }
}

public protocol V2RoomRecoveryTopologyReading: Sendable {
    /// Generation changes whenever a scan could miss a room moved across physical stores.
    func topology() async throws -> V2RoomRecoveryTopology
}

public struct V2UserRoomDirectoryService: Sendable {
    private let topologySource: any V2RoomRecoveryTopologyReading
    private let cursorCodec: V2UserRoomDirectoryCursorCodec

    public init(topologySource: any V2RoomRecoveryTopologyReading, cursorCodec: V2UserRoomDirectoryCursorCodec) {
        self.topologySource = topologySource
        self.cursorCodec = cursorCodec
    }

    public func list(actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2UserRoomDirectoryPage {
        guard actorUserID.uuidValue != nil, pageSize > 0, pageSize <= 100 else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        let topology = try await topologySource.topology()
        let index: Int
        let after: RoomID?
        if let cursor {
            let position = try cursorCodec.decode(cursor, userID: actorUserID,
                topologyGeneration: topology.generation, storeCount: topology.stores.count)
            index = position.storeIndex
            after = position.after
        } else {
            index = 0
            after = nil
        }
        // One physical-store request per page, including empty filtered pages.
        let slice = try await topology.stores[index].rooms(actorUserID: actorUserID, after: after, limit: pageSize)
        guard slice.entries.count <= pageSize,
              Set(slice.entries.map(\.roomID)).count == slice.entries.count,
              !slice.hasMore || slice.scannedThrough != nil,
              slice.scannedThrough == nil || slice.scannedThrough != after else {
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        guard try await topologySource.topology().generation == topology.generation else {
            throw V2RoomRecoveryReadError.topologyChanged
        }
        let next: String?
        if slice.hasMore {
            next = try cursorCodec.encode(userID: actorUserID, topologyGeneration: topology.generation,
                storeIndex: index, after: slice.scannedThrough)
        } else if index + 1 < topology.stores.count {
            next = try cursorCodec.encode(userID: actorUserID, topologyGeneration: topology.generation,
                storeIndex: index + 1, after: nil)
        } else { next = nil }
        return .init(rooms: slice.entries, nextCursor: next, topologyGeneration: topology.generation)
    }
}
