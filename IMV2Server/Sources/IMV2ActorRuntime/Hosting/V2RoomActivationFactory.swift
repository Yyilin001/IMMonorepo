import Foundation
import IMV2ActorContracts

/// One executor belongs to one activation token. The factory creates an
/// un-restored executor so Hosting can close it if restore fails partway through.
public struct V2RoomActivationExecutor<Request: Decodable & Sendable, Response: Sendable>: Sendable {
    public let restore: @Sendable (ContinuousClock.Instant) async throws -> Void
    public let execute: V2RoomTurnLane<Request, Response>.Execute
    public let invalidateReservation: @Sendable (V2RoomReservation) async -> Void
    public let close: @Sendable () async -> Void

    public init(
        restore: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void,
        execute: @escaping V2RoomTurnLane<Request, Response>.Execute,
        invalidateReservation: @escaping @Sendable (V2RoomReservation) async -> Void,
        close: @escaping @Sendable () async -> Void
    ) {
        self.restore = restore
        self.execute = execute
        self.invalidateReservation = invalidateReservation
        self.close = close
    }
}

public struct V2RoomActivationFactory<Request: Decodable & Sendable, Response: Sendable>: Sendable {
    public let make: @Sendable (V2RoomActivationToken) -> V2RoomActivationExecutor<Request, Response>

    public init(make: @escaping @Sendable (V2RoomActivationToken) -> V2RoomActivationExecutor<Request, Response>) {
        self.make = make
    }
}
