import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import IMV2ServerContracts
import Synchronization

/// Local business closures cross only the native Host boundary, never TCP.
private struct DatabaseRoomTestCall: Sendable {
    let execute: @Sendable (V2RoomActivationToken, V2RoomActivationLifetime) async throws -> any Sendable
    let recordUnknown: @Sendable (any Error) -> Void
}
private struct DatabaseRoomTestResult: Sendable {
    let result: Result<any Sendable, any Error>
}

/// Concurrent business tests share one Host per shard. Initialization and
/// final physical stop are owned tasks; a cancelled caller cannot abandon them.
actor V2DatabaseRoomActorTestRuntime {
    static let shared = V2DatabaseRoomActorTestRuntime()
    private let retainedPlacement: (control: V2NativePlacementTestControl, hostID: V2ActorHostID)?

    private init(retainedPlacement: (V2NativePlacementTestControl, V2ActorHostID)? = nil) {
        self.retainedPlacement = retainedPlacement
    }

    /// Each completed call drains its physical Host. Successive calls register
    /// a new incarnation against the same durable placement quorum.
    static func withReplacementHosts<Value: Sendable>(shardID: String,
        _ body: (V2DatabaseRoomActorTestRuntime) async throws -> Value) async throws -> Value {
        let identity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        return try await withNativePlacementTestControl(host: identity, shardID: shardID) { control in
            try await body(V2DatabaseRoomActorTestRuntime(retainedPlacement: (control, identity.hostID)))
        }
    }
    private struct Session: Sendable {
        let id: UUID
        let shardID: String
        let host: V2RoomActivationHost<DatabaseRoomTestCall, DatabaseRoomTestResult>
        let budget: V2RoomCommandBudget
        let placement: V2RoomActorPlacementRuntime
        let control: V2NativePlacementTestControl
        let ownsControl: Bool

        static func open(shardID: String,
            retainedPlacement: (control: V2NativePlacementTestControl, hostID: V2ActorHostID)?) async throws -> Self {
            let identity = V2ActorHostIdentity(hostID: retainedPlacement?.hostID ?? .init(uuid: UUID()), incarnationID: UUID())
            let control: V2NativePlacementTestControl
            if let retainedPlacement { control = retainedPlacement.control }
            else { control = try await V2NativePlacementTestControl.open(host: identity, shardID: shardID) }
            do {
                let placement = try await control.register(identity, shard: shardID)
                let configuration = try V2RoomRuntimeConfiguration()
                let budget = V2RoomCommandBudget(configuration: configuration)
                let host = V2RoomActivationHost<DatabaseRoomTestCall, DatabaseRoomTestResult>(identity: identity,
                    placement: placement, configuration: configuration, budget: budget,
                    classify: { _ in .barrier }, factory: .init { token in
                        let lifetime = Mutex<V2RoomActivationLifetime?>(nil)
                        return .init(restore: { context in
                            try await context.validate()
                            lifetime.withLock { $0 = context.lifetime }
                        }, execute: { turn in
                            guard let lifetime = lifetime.withLock({ $0 }) else {
                                return .rolledBack(.notReady)
                            }
                            var results: [DatabaseRoomTestResult] = []
                            for item in turn.items {
                                do { results.append(.init(result: .success(try await item.request.execute(token, lifetime)))) }
                                catch {
                                    if error is V2RoomTransactionOutcomeUnknown ||
                                        (error as? V2RoomCallFailure) == .outcomeUnknown ||
                                        (error as? V2RoomActorStateError) == .outcomeUnknown {
                                        item.request.recordUnknown(error)
                                        return .outcomeUnknown
                                    }
                                    results.append(.init(result: .failure(error)))
                                }
                            }
                            // The closure's actual SQL has settled before its
                            // result (including business errors) leaves the lane.
                            return .committed(results)
                        }, invalidateReservation: { _ in }, close: {})
                    })
                await host.start()
                return .init(id: UUID(), shardID: shardID, host: host, budget: budget,
                    placement: placement, control: control, ownsControl: retainedPlacement == nil)
            } catch {
                if retainedPlacement == nil { try? await control.close() }
                throw error
            }
        }

        func close() async throws {
            let drained = await host.stop(deadline: .now + .seconds(30))
            guard drained.completed, let proof = drained.proof else {
                // Keep the session unavailable; never start a replacement
                // while physical SQL or executor shutdown is still unsettled.
                throw V2RoomCallFailure.notAccepted(.unavailable)
            }
            try await placement.retireAfterDrain(proof, shards: [shardID])
            if ownsControl { try await control.close() }
        }
    }
    private enum Entry {
        case starting(UUID, Task<Session, any Error>)
        case ready(Session, users: Int)
        case stopping(Session, UUID, Task<Void, any Error>)
    }
    private var sessions: [String: Entry] = [:]

    /// Real Host permits include the executing turn and admitted queued calls.
    /// SQL lock observations cannot see commands waiting in the native lane.
    func admittedCommandCount(shardID: String) -> Int {
        guard case .ready(let session, _) = sessions[shardID] else { return 0 }
        return session.budget.snapshot().commandCount
    }

    private func acquire(shardID: String) async throws -> Session {
        while true {
            switch sessions[shardID] {
            case .ready(let session, let users):
                sessions[shardID] = .ready(session, users: users + 1)
                return session
            case .starting(let id, let task):
                let session: Session
                do { session = try await task.value }
                catch {
                    if case .starting(let current, _) = sessions[shardID], current == id {
                        sessions.removeValue(forKey: shardID)
                    }
                    throw error
                }
                if case .starting(let current, _) = sessions[shardID], current == id {
                    sessions[shardID] = .ready(session, users: 0)
                }
            case .stopping(_, let id, let task):
                // Failure stays recorded and blocks subsequent acquisition.
                try await task.value
                if case .stopping(_, let current, _) = sessions[shardID], current == id {
                    sessions.removeValue(forKey: shardID)
                }
            case nil:
                sessions[shardID] = .starting(UUID(), Task { try await Session.open(shardID: shardID, retainedPlacement: retainedPlacement) })
            }
        }
    }

    private func release(_ session: Session) async throws {
        guard case .ready(let current, let users) = sessions[session.shardID],
              current.id == session.id, users > 0 else { preconditionFailure("Unbalanced native test Host use") }
        if users > 1 {
            sessions[session.shardID] = .ready(current, users: users - 1)
            return
        }
        let id = UUID(), task = Task { try await session.close() }
        sessions[session.shardID] = .stopping(session, id, task)
        try await task.value
        if case .stopping(_, let current, _) = sessions[session.shardID], current == id {
            sessions.removeValue(forKey: session.shardID)
        }
    }

    func execute<Value: Sendable>(roomID: RoomID, owner: V2RoomDataOwner,
        _ body: @escaping @Sendable (V2RoomActivationToken) async throws -> Value) async throws -> Value {
        try await executeWithLifetime(roomID: roomID, owner: owner) { token, _ in
            try await body(token)
        }
    }

    /// Passes the capability issued by the actual Host restoration. No token
    /// or remote value can manufacture physical execution ownership.
    func executeWithLifetime<Value: Sendable>(roomID: RoomID, owner: V2RoomDataOwner,
        _ body: @escaping @Sendable (V2RoomActivationToken, V2RoomActivationLifetime) async throws -> Value) async throws -> Value {
        let session = try await acquire(shardID: owner.shardID)
        let unknown = Mutex<(any Error)?>(nil)
        let value: Value
        do {
            try Task.checkCancellation()
            let deadline = ContinuousClock.now + .seconds(30)
            guard case .ready(let token) = try await session.host.activate(roomID: roomID, owner: owner, deadline: deadline) else {
                throw V2RoomCallFailure.notAccepted(.notReady)
            }
            let response = try await session.host.invoke(token: token,
                request: .init(execute: { try await body($0, $1) }, recordUnknown: { error in unknown.withLock { $0 = error } }),
                deadline: deadline)
            guard let typed = try response.result.get() as? Value else { preconditionFailure("Wrong native test result type") }
            value = typed
        } catch {
            try await release(session)
            throw unknown.withLock { $0 } ?? error
        }
        try await release(session)
        return value
    }
}
