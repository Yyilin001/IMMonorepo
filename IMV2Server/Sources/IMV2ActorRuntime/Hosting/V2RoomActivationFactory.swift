import Foundation
import IMV2ActorContracts

/// 一个执行器只对应一个激活令牌。工厂创建尚未恢复的执行器，
/// 使宿主在恢复中途失败时能够关闭它。
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
