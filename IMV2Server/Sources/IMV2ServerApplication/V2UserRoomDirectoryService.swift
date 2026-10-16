import IMV2ServerContracts
import Foundation
import IMV2Core

public struct V2UserRoomDirectoryService: Sendable {
    private let snapshotSource: any V2RoomRecoveryDirectoryReading
    private let cursorCodec: V2UserRoomDirectoryCursorCodec

    public init(snapshotSource: any V2RoomRecoveryDirectoryReading, cursorCodec: V2UserRoomDirectoryCursorCodec) {
        self.snapshotSource = snapshotSource
        self.cursorCodec = cursorCodec
    }

    public func list(actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2UserRoomDirectoryPage {
        guard actorUserID.uuidValue != nil, pageSize > 0, pageSize <= 100 else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        let position = try cursor.map { try cursorCodec.decode($0, userID: actorUserID,
            storeCount: snapshotSource.storeCount) }
        let index = position?.storeIndex ?? 0
        let after = position?.after
        let snapshot = try await snapshotSource.snapshot(actorUserID: actorUserID, after: after,
            limit: pageSize, storeIndex: index)
        if let position, position.topologyGeneration != snapshot.generation { throw V2RoomRecoveryReadError.topologyChanged }
        let slice = snapshot.slice
        guard slice.entries.count <= pageSize,
              Set(slice.entries.map(\.roomID)).count == slice.entries.count,
              !slice.hasMore || slice.scannedThrough != nil,
              slice.scannedThrough == nil || slice.scannedThrough != after else {
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        let next: String?
        if slice.hasMore {
            next = try cursorCodec.encode(userID: actorUserID, topologyGeneration: snapshot.generation,
                storeIndex: index, after: slice.scannedThrough)
        } else if index + 1 < snapshotSource.storeCount {
            next = try cursorCodec.encode(userID: actorUserID, topologyGeneration: snapshot.generation,
                storeIndex: index + 1, after: nil)
        } else { next = nil }
        return .init(rooms: slice.entries, nextCursor: next, topologyGeneration: snapshot.generation)
    }
}
