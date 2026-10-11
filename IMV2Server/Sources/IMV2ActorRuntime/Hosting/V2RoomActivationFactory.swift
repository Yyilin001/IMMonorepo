import Foundation
import IMV2ActorContracts

/// 一个执行器只对应一个激活令牌。工厂创建尚未恢复的执行器，
/// 使宿主在恢复中途失败时能够关闭它。
public struct V2RoomActivationExecutor<Request: Sendable, Response: Sendable>: Sendable {
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

public struct V2RoomActivationFactory<Request: Sendable, Response: Sendable>: Sendable {
    public let make: @Sendable (V2RoomActivationToken) -> V2RoomActivationExecutor<Request, Response>
    public let recoveryBatch: (@Sendable ([V2RoomRecoveryBatchCallItem]) async -> V2RoomTransactionCompletion<[V2RoomRecoveryBatchCallOutcome]>)?
    /// A pure room-log pull uses a lifecycle pin and the original command byte
    /// budget, without entering the write lane. The Host restricts this callback
    /// to the concrete `.roomLog(.pull)` request; all mutations retain the lane.
    public let pureRoomLogPull: (@Sendable (V2RoomActivationToken, Request, ContinuousClock.Instant) async -> V2RoomTransactionCompletion<Response>)?
    /// Renewal observes the existing authorization cut. It pins the activation
    /// and uses its trusted deadline without queueing behind message writes.
    /// Subscribe, reset, activation and revocation still enter the room lane.
    public let pureSubscriptionRenew: (@Sendable (V2RoomActivationToken, Request, ContinuousClock.Instant, ContinuousClock.Instant) async -> V2RoomTransactionCompletion<Response>)?

    public init(recoveryBatch: (@Sendable ([V2RoomRecoveryBatchCallItem]) async -> V2RoomTransactionCompletion<[V2RoomRecoveryBatchCallOutcome]>)? = nil,
                pureRoomLogPull: (@Sendable (V2RoomActivationToken, Request, ContinuousClock.Instant) async -> V2RoomTransactionCompletion<Response>)? = nil,
                pureSubscriptionRenew: (@Sendable (V2RoomActivationToken, Request, ContinuousClock.Instant, ContinuousClock.Instant) async -> V2RoomTransactionCompletion<Response>)? = nil,
                make: @escaping @Sendable (V2RoomActivationToken) -> V2RoomActivationExecutor<Request, Response>) {
        self.make = make
        self.recoveryBatch = recoveryBatch
        self.pureRoomLogPull = pureRoomLogPull
        self.pureSubscriptionRenew = pureSubscriptionRenew
    }
}
