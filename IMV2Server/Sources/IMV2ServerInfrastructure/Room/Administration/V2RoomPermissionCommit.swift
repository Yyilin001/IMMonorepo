import Foundation
import FluentKit
import Synchronization
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts

/// One command's explicit persistence dependency. A resulting cut is returned
/// from its actual transaction and retained only after COMMIT is confirmed.
/// It grants no SQL authority and is never a task-local or a database decorator.
package final class V2RoomPermissionCommit: Sendable {
    private let source: PostgresV2RoomSubscriptionSource
    private let token: V2RoomActivationToken
    private let users: Set<UserID>
    private let baseVersion: Int64
    private let requiresReceiveReset: Bool
    private let retained = Mutex<V2RoomCommittedPermissionEffect?>(nil)

    package init(database: any Database, token: V2RoomActivationToken, lifetime: V2RoomActivationLifetime,
                 trackedUserIDs: Set<UserID>, baseVersion: Int64, requiresReceiveReset: Bool) throws {
        source = try .init(database: database, activation: token, lifetime: lifetime)
        self.token = token; users = trackedUserIDs; self.baseVersion = baseVersion
        self.requiresReceiveReset = requiresReceiveReset
    }
    func cut(in transaction: any Database) async throws -> V2RoomCommittedPermissionEffect? {
        let snapshot = try await source.permissionCut(in: transaction, trackedUserIDs: users)
        guard snapshot.roomControlVersion >= baseVersion else { throw V2RoomCallFailure.outcomeUnknown }
        guard snapshot.roomControlVersion > baseVersion else { return nil }
        return .init(activation: token, snapshot: snapshot, requiresReceiveReset: requiresReceiveReset)
    }
    func didCommit(_ effect: V2RoomCommittedPermissionEffect?) {
        guard let effect else { return }
        retained.withLock { current in
            if current.map({ $0.snapshot.roomControlVersion < effect.snapshot.roomControlVersion }) ?? true { current = effect }
        }
    }
    package func effect() -> V2RoomCommittedPermissionEffect? { retained.withLock { $0 } }
}

/// The cut and the business result share the same commit/rollback fate. An
/// uncertain COMMIT never publishes either into authoritative room memory.
func v2WithRoomPermissionCommit<Result: Sendable>(database: any Database,
    permissionCommit: V2RoomPermissionCommit?,
    useRoomDeadline: Bool = true,
    _ operation: @escaping @Sendable (any Database) async throws -> Result
) async throws -> Result {
    guard let permissionCommit else { return try await v2WithRoomScopedTransaction(database: database, useRoomDeadline: useRoomDeadline, operation) }
    guard useRoomDeadline else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
    let committed: V2RoomPermissionMutationResult<Result> = try await v2WithRoomScopedTransaction(database: database) { transaction in
        let result = try await operation(transaction)
        return try await .init(result: result, effect: permissionCommit.cut(in: transaction))
    }
    permissionCommit.didCommit(committed.effect)
    return committed.result
}
