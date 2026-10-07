import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2ServerApplication

/// Startup binds the host's actual reservation coordinator once. Inbound RPCs
/// cannot execute before that boundary exists or after it has been closed.
package actor V2RoomForwardPairService: V2RoomForwardPairServing {
    private let executors: [String: V2ActorForwardPairDomainExecutor]
    private var coordinator: V2RoomReservationCoordinator?
    private var closed = false

    package init(executors: [String: V2ActorForwardPairDomainExecutor]) {
        precondition(!executors.isEmpty)
        self.executors = executors
    }

    package func bind(_ coordinator: V2RoomReservationCoordinator) throws {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard self.coordinator == nil else { throw V2PolicyAuthorizationLifecycleError.identityConflict }
        self.coordinator = coordinator
    }

    package func close() {
        closed = true
        // The coordinator's directory retains a local client capability back
        // to this inbound service. Break that cycle after ingress drains.
        // An already executing call retains its own coordinator until SQL ends.
        coordinator = nil
    }

    package func forwardPair(_ pair: V2ActorForwardPairWire, token: V2RoomActivationToken,
        deadline: ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire {
        guard !closed else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard let coordinator else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        guard token.roomID == pair.targetRoomID, executors[token.owner.shardID] != nil else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        return try await V2ActorForwardPairPort(coordinator: coordinator,
            executorsByShard: executors, expectedTarget: token).execute(pair, deadline)
    }
}
