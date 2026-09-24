import Foundation

/// A grant is scoped to one activation and one coordinator attempt. It conveys
/// no database write authority without the transaction's activation fence.
public struct V2RoomReservation: Hashable, Codable, Sendable {
    public let token: V2RoomActivationToken
    public let requestID: UUID
    public let reservationID: UUID

    public init(token: V2RoomActivationToken, requestID: UUID, reservationID: UUID) {
        self.token = token
        self.requestID = requestID
        self.reservationID = reservationID
    }
}

/// Only a coordinator that received dispatch acknowledgements from every room
/// may start SQL. Unknown completion retires every participating activation.
public enum V2RoomReservationCompletion: String, Codable, Sendable {
    case committed
    case rolledBack
    case outcomeUnknown
}
