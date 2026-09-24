import Foundation
import IMV2ActorContracts
import IMV2Core

/// Runtime/transport adapter for the coordinator. Each operation must honor its
/// monotonic deadline; the remote implementation sends only a remaining budget.
public struct V2RoomReservationOperations: Sendable {
    let reserve: @Sendable (RoomID, UUID, ContinuousClock.Instant) async throws -> V2RoomReservation
    let markDispatched: @Sendable (V2RoomReservation, ContinuousClock.Instant) async throws -> Void
    let abort: @Sendable (V2RoomReservation, ContinuousClock.Instant) async -> Bool
    let finish: @Sendable (V2RoomReservation, V2RoomReservationCompletion, ContinuousClock.Instant) async -> Bool

    public init(
        reserve: @escaping @Sendable (RoomID, UUID, ContinuousClock.Instant) async throws -> V2RoomReservation,
        markDispatched: @escaping @Sendable (V2RoomReservation, ContinuousClock.Instant) async throws -> Void,
        abort: @escaping @Sendable (V2RoomReservation, ContinuousClock.Instant) async -> Bool,
        finish: @escaping @Sendable (V2RoomReservation, V2RoomReservationCompletion, ContinuousClock.Instant) async -> Bool
    ) {
        self.reserve = reserve
        self.markDispatched = markDispatched
        self.abort = abort
        self.finish = finish
    }
}

/// At most one source-target pair is held by each call. Canonical acquisition
/// prevents A->B / B->A cycles without expanding the business atomicity scope.
public actor V2RoomReservationCoordinator {
    private let operations: V2RoomReservationOperations
    private let configuration: V2RoomRuntimeConfiguration
    private var inFlight = 0

    public init(operations: V2RoomReservationOperations, configuration: V2RoomRuntimeConfiguration) {
        self.operations = operations
        self.configuration = configuration
    }

    public func withReservations<Value: Sendable>(
        source: RoomID,
        target: RoomID,
        deadline: ContinuousClock.Instant,
        execute: @Sendable ([V2RoomReservation]) async -> V2RoomTransactionCompletion<Value>
    ) async throws -> Value {
        guard V2RoomTurnScope.roomID == nil else {
            // An ordinary turn may never wait for another room's turn.
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        guard inFlight < configuration.maximumConcurrentReservations else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        try checkBeforeDispatch(deadline)
        inFlight += 1
        defer { inFlight -= 1 }

        let requestID = UUID()
        let rooms = Array(Set([source, target])).sorted()
        var grants: [V2RoomReservation] = []
        var markingStarted = false
        do {
            for roomID in rooms {
                try checkBeforeDispatch(deadline)
                let grant = try await operations.reserve(roomID, requestID, deadline)
                // A mismatched response never becomes write authority.
                guard grant.token.roomID == roomID, grant.requestID == requestID else {
                    // It might belong to someone else's attempt. Never release
                    // it; our possibly granted request expires at its holder.
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                grants.append(grant)
            }
            // Different owner epochs are valid for two rooms on the same DB;
            // different physical owners use the existing durable forward flow.
            guard Set(grants.map { $0.token.owner.shardID }).count == 1 else {
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            for grant in grants {
                try checkBeforeDispatch(deadline)
                markingStarted = true
                try await operations.markDispatched(grant, deadline)
            }
            try checkBeforeDispatch(deadline)
        } catch {
            // SQL has not run. Even a lost dispatch acknowledgement can be
            // completed as rolled back; unmarked grants are safely aborted.
            await abandon(grants, markingStarted: markingStarted)
            if let failure = error as? V2RoomCallFailure,
               case .notAccepted = failure { throw failure }
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }

        // From here, cancellation/timeout must be classified by the actual
        // transaction owner. This closure cannot throw an ambiguous DB error.
        let completion = await execute(grants)
        switch completion {
        case .committed(let value):
            await settle(grants, completion: .committed)
            return value
        case .rolledBack(let reason):
            await settle(grants, completion: .rolledBack)
            throw V2RoomCallFailure.rolledBack(reason)
        case .outcomeUnknown:
            await settle(grants, completion: .outcomeUnknown)
            throw V2RoomCallFailure.outcomeUnknown
        }
    }

    public func activePairCount() -> Int { inFlight }

    private func checkBeforeDispatch(_ deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
    }

    private func cleanupDeadline() -> ContinuousClock.Instant {
        .now + configuration.transactionTimeout.duration
    }

    private func abandon(_ grants: [V2RoomReservation], markingStarted: Bool) async {
        let operations = operations
        let deadline = cleanupDeadline()
        await withTaskGroup(of: Void.self) { group in
            for grant in grants {
                group.addTask {
                    if markingStarted,
                       await operations.finish(grant, .rolledBack, deadline) { return }
                    _ = await operations.abort(grant, deadline)
                    // Unreachable holders retain the barrier until safe epoch
                    // retirement. Failure never authorizes a local TTL unlock.
                }
            }
        }
    }

    private func settle(_ grants: [V2RoomReservation], completion: V2RoomReservationCompletion) async {
        let operations = operations
        let deadline = cleanupDeadline()
        await withTaskGroup(of: Void.self) { group in
            for grant in grants {
                group.addTask { _ = await operations.finish(grant, completion, deadline) }
            }
        }
        // A lost notification does not change a known committed SQL result.
        // Its holder stays closed and retires when its bounded grant expires.
    }
}

enum V2RoomTurnScope {
    @TaskLocal static var roomID: RoomID?
}
