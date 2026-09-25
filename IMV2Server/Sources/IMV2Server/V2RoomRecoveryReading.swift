import Foundation
import IMV2Core

public enum V2RoomRecoveryReadError: Error, Equatable, Sendable {
    case invalidRequest
    case corruptPersistence
    case invalidCursor
    case topologyChanged
}

public enum V2RoomStateReadResult: Equatable, Sendable {
    case state(V2RoomSynchronizationState)
    case unavailable
    case retry
}

public protocol V2RoomStateReading: Sendable {
    /// 每个不同的请求房间都有明确结果；不可用结果不透露房间是否存在。
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult]
}

public struct V2UserRoomDirectoryEntry: Equatable, Sendable {
    public let roomID: RoomID
    public let roomKind: V2RoomKind
    public let viewerMembershipRevision: UInt64
    public let ownerEpoch: UInt64

    public init(roomID: RoomID, roomKind: V2RoomKind, viewerMembershipRevision: UInt64, ownerEpoch: UInt64) throws {
        guard viewerMembershipRevision > 0, viewerMembershipRevision <= UInt64(Int64.max),
              ownerEpoch <= UInt64(Int64.max) else { throw V2RoomRecoveryReadError.corruptPersistence }
        self.roomID = roomID
        self.roomKind = roomKind
        self.viewerMembershipRevision = viewerMembershipRevision
        self.ownerEpoch = ownerEpoch
    }
}

/// 存储内部的扫描进度与可见条目分开。
public struct V2UserRoomDirectorySlice: Sendable {
    public let entries: [V2UserRoomDirectoryEntry]
    public let scannedThrough: RoomID?
    public let hasMore: Bool
}

public protocol V2UserRoomDirectoryReading: Sendable {
    func rooms(actorUserID: UserID, after: RoomID?, limit: Int) async throws -> V2UserRoomDirectorySlice
}
