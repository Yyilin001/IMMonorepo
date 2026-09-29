import IMV2Core

public enum V2RoomLatestVisibleResult: Equatable, Sendable {
    case snapshot(V2RoomLatestVisible)
    case unavailable
    case retry
}

public protocol V2RoomLatestVisibleReading: Sendable {
    func latestVisible(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomLatestVisibleResult]
}
