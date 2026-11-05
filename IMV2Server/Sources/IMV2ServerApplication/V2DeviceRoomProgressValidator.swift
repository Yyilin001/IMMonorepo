import IMV2Core
import IMV2ServerContracts

/// One-shot current-room authorization for durable progress reporting. A
/// background catch-up needs no live subscription; this grants no content access
/// and the resulting diagnostic cursor is never a room-log retention authority.
public enum V2DeviceRoomProgressValidationError: Error, Sendable { case temporarilyUnavailable }

public struct V2DeviceRoomProgressValidator: Sendable {
    private let states: any V2RoomStateReading
    public init(states: any V2RoomStateReading) { self.states = states }

    public func validate(userID: UserID, reports: [(RoomID, UInt64)]) async throws -> [V2DeviceRoomProgress] {
        guard !reports.isEmpty, reports.count <= 64, Set(reports.map { $0.0 }).count == reports.count,
              reports.allSatisfy({ $0.0.uuidValue != nil && $0.1 <= UInt64(Int64.max) }) else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        let authorized = try await states.states(roomIDs: reports.map { $0.0 }, actorUserID: userID)
        return try reports.map { room, sequence in
            switch authorized[room] {
            case .state(let state):
                guard state.roomID == room else { throw V2RoomRecoveryReadError.corruptPersistence }
                return try .init(roomID: room, appliedThrough: sequence, authorizedHighWatermark: state.head)
            case .unavailable: throw V2RoomRecoveryReadError.invalidCursor
            case .retry: throw V2DeviceRoomProgressValidationError.temporarilyUnavailable
            case nil: throw V2RoomRecoveryReadError.corruptPersistence
            }
        }
    }
}
