import Foundation
import IMV2ActorContracts
import IMV2Core

/// Maps a complete admitted room turn to one bounded batcher admission and
/// back to ordered typed results. A SQL partition can commit before another
/// partition fails, so only truly unknown completion stops the whole turn.
public struct V2ActorGrantedSendBatchAdapter: Sendable {
    private let batcher: V2SendMessageAdmissionBatcher

    public init(batcher: V2SendMessageAdmissionBatcher) {
        self.batcher = batcher
    }

    public func execute(
        _ sends: [V2PreparedActorSend],
        batchDeadline: ContinuousClock.Instant
    ) async throws -> [V2RoomMessagingResult] {
        let results: [Result<V2SendMessageOutcome, any Error>]
        do {
            results = try await batcher.acceptGrantedTurn(sends, batchDeadline: batchDeadline)
        } catch V2SendMessageAdmissionBatcherError.serverBusy {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        } catch is CancellationError {
            throw V2RoomCallFailure.notAccepted(.cancelled)
        }
        // A driver failure or unknown SQL commit is not a typed business
        // rejection. Do not return partial successes as a committed turn when
        // any participant may have an unresolved durable result.
        for result in results {
            if case .failure(let error) = result,
               error is V2RoomTransactionOutcomeUnknown ||
               error is V2RoomActivationLeaseError ||
               (error as? V2RoomWriteStoreError) == .corruptPersistenceState ||
               V2ActorMessagingErrorWire(domainError: error) == nil {
                throw V2RoomCallFailure.outcomeUnknown
            }
        }
        return try results.map { result -> V2RoomMessagingResult in
            switch result {
            case .success(let outcome): return .send(.init(outcome))
            case .failure(let error):
                guard let failure = V2ActorMessagingErrorWire(domainError: error) else {
                    throw V2RoomCallFailure.outcomeUnknown
                }
                return .failure(failure)
            }
        }
    }
}
