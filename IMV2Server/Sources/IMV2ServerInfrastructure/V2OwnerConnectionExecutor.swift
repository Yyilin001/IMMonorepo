import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ActorContracts
import IMV2Core
import Synchronization

/// `execute` is bound to a borrowed connection and must remain inside the pool body.
/// Retain only `finalize`, and await it after the physical loan returns, before ACK.
package struct V2OwnerConnectionExecutor: Sendable {
    package var finalize: @Sendable () async -> Void = {}
    package let execute: @Sendable (V2PreparedMessageSendBatch, V2CapacityProfile,
        V2AcceptanceIDFactory, @escaping @Sendable () -> Date) async throws -> [V2RoomMessagingResult]
}

public typealias V2RoomSendPreparation = @Sendable ([V2MessageSendOperationCommand],
    V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2PreparedMessageSendBatch

package typealias V2ScheduledSendConnection = @Sendable (ContinuousClock.Instant,
    @escaping @Sendable (V2OwnerConnectionExecutor) async throws -> V2ScheduledSendOutcome?) async throws -> V2ScheduledSendOutcome?
package typealias V2ScheduledSendConnectionStart = @Sendable (ContinuousClock.Instant,
    @escaping @Sendable (V2OwnerConnectionExecutor) async throws -> V2ScheduledSendOutcome?) throws -> V2StartedRoomConnection<V2ScheduledSendOutcome?>
package typealias V2ScheduledSendExecution = @Sendable (V2OwnerConnectionExecutor,
    V2PreparedMessageSendBatch) async throws -> [V2RoomMessagingResult]

/// Carries a settled turn through physical loan return without an actor handoff.
package struct V2ScheduledSendOutcome: Sendable {
    let result: Result<[V2RoomMessagingResult], any Error>
    let finalize: @Sendable () async -> Void
    let settle: @Sendable (Result<[V2RoomMessagingResult], any Error>) async -> Void
}

/// Stores only post-commit memory/notification work, never a borrowed database.
package final class V2OwnerPostCommitWork: Sendable {
    private let actions = Mutex<[@Sendable () async -> Void]>([])
    package func append(_ action: @escaping @Sendable () async -> Void) { actions.withLock { $0.append(action) } }
    package func finish() async {
        let pending = actions.withLock { value in
            let pending = value
            value.removeAll()
            return pending
        }
        for action in pending { await action() }
    }
}

/// Invoked on actual pool settlement, before resuming the suspended borrower.
/// Production pools notify synchronously; custom/legacy borrowers use the
/// dispatcher's idempotent fallback after their async borrowing call returns.
package final class V2ScheduledSendLoanReturn: Sendable {
    @TaskLocal package static var current: V2ScheduledSendLoanReturn?
    private let callback: Mutex<(@Sendable () -> Void)?>
    package init(_ callback: @escaping @Sendable () -> Void) { self.callback = Mutex(callback) }
    /// Only the outer borrowing call claims the callback. Nested work cannot
    /// release its owner's scheduling position by returning a different loan.
    package func takeCallback() -> (@Sendable () -> Void)? {
        callback.withLock { value in let action = value; value = nil; return action }
    }
    package func notify() { takeCallback()?() }
}
