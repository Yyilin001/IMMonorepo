import IMV2Core

/// A device's reported durable cursor. It never grants room access or permits
/// deletion of the room log. The Gateway must check its live room grant first.
public struct V2DeviceRoomProgress: Equatable, Sendable {
    public let roomID: RoomID
    public let appliedThrough: UInt64
    public init(roomID: RoomID, appliedThrough: UInt64, authorizedHighWatermark: UInt64) throws {
        guard appliedThrough <= authorizedHighWatermark,
              authorizedHighWatermark <= UInt64(Int64.max) else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        self.roomID = roomID
        self.appliedThrough = appliedThrough
    }
}

/// Each device advances independently. Repeated and out-of-order reports must
/// be monotone; successful completion means the batch is durably recorded.
public protocol V2DeviceRoomProgressStoring: Sendable {
    func record(userID: UserID, deviceID: DeviceID, progress: [V2DeviceRoomProgress]) async throws
    func load(userID: UserID, deviceID: DeviceID, roomIDs: [RoomID]) async throws -> [RoomID: UInt64]
}
