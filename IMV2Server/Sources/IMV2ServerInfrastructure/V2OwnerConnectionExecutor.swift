import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ActorContracts
import IMV2Core
import Synchronization
import _Concurrency

/// Scoped to one exclusively owned physical connection. Each turn gets its own
/// execution copy and post-commit collector; none of these captures may escape
/// the connection callback except the connection-free finalization action.
package struct V2OwnerConnectionExecutor: Sendable {
    package let isUsable: @Sendable () -> Bool
    package let observeClose: @Sendable (@escaping @Sendable () -> Void) -> @Sendable () -> Void
    package let confirmIdle: @Sendable () async -> Bool
    package let makeTurn: @Sendable () -> V2OwnerConnectionTurn
    package var independentlySettledTurns = false
    package var taskExecutor: (any TaskExecutor)? = nil
}

package struct V2OwnerConnectionTurn: Sendable {
    package let finalize: @Sendable () async -> Void
    package let execute: @Sendable (V2PreparedMessageSendBatch, V2CapacityProfile,
        V2AcceptanceIDFactory, @escaping @Sendable () -> Date) async throws -> [V2RoomMessagingResult]
}

public typealias V2RoomSendPreparation = @Sendable ([V2MessageSendOperationCommand],
    V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2PreparedMessageSendBatch

/// One lease for an entire worker session, not one message or room transaction.
package typealias V2ScheduledSendConnection = @Sendable (ContinuousClock.Instant,
    @escaping @Sendable (V2OwnerConnectionExecutor) async throws -> Void) async throws -> Void
package typealias V2ScheduledSendExecution = @Sendable (V2OwnerConnectionTurn,
    V2PreparedMessageSendBatch) async throws -> [V2RoomMessagingResult]

/// Delivered to the already waiting room task after the database cycle settles.
/// Finalization carries no borrowed database and never releases room ordering early.
package struct V2ScheduledSendOutcome: Sendable {
    let result: Result<[V2RoomMessagingResult], any Error>
    let finalize: @Sendable () async -> Void
}

package final class V2OwnerPostCommitWork: Sendable {
    private let actions = Mutex<[@Sendable () async -> Void]>([])
    package func append(_ action: @escaping @Sendable () async -> Void) { actions.withLock { $0.append(action) } }
    package func finish() async {
        let pending = actions.withLock { value in
            let pending = value
            value.removeAll()
            return pending
        }
        // These nonthrowing memory/notification actions must finish even when the
        // room task's caller has cancelled after a confirmed durable commit.
        for action in pending { await action() }
    }
}

/// The physical close future retains only this disarmable callback, never the
/// dispatcher after its worker has released the connection scope.
package final class V2MessageWriteConnectionCloseObservation: Sendable {
    private let callback: Mutex<(@Sendable () -> Void)?>
    package init(_ callback: @escaping @Sendable () -> Void) { self.callback = Mutex(callback) }
    package func notify() { callback.withLock { value in let result = value; value = nil; return result }?() }
    package func disarm() { callback.withLock { $0 = nil } }
}
