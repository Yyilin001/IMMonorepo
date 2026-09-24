import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server

/// Grants a fresh activation for one room turn, runs `body` under its token,
/// then releases the lease. An activation still held by another in-flight
/// test turn is waited out briefly rather than treated as a failure.
func withRoomActivation<Value: Sendable>(
    database: any Database,
    roomID: RoomID,
    shardID: String = "room-a",
    epoch: Int64 = 0,
    _ body: (V2RoomActivationToken) async throws -> Value
) async throws -> Value {
    let leases = PostgresV2RoomActivationStore(database: database)
    let host = V2ActorHostIdentity(hostID: try .init("activation-test"), incarnationID: UUID())
    let owner = try V2RoomDataOwner(shardID: shardID, epoch: epoch)
    for _ in 0..<500 {
        guard case .acquired(let lease) = try await leases.acquire(roomID: roomID, owner: owner,
            host: host, duration: try .init(10_000)) else {
            try await Task.sleep(for: .milliseconds(10))
            continue
        }
        do {
            let value = try await body(lease.token)
            _ = try await leases.release(token: lease.token)
            return value
        } catch {
            _ = try? await leases.release(token: lease.token)
            throw error
        }
    }
    throw V2RoomActivationLeaseError.activationChanged
}

/// Runs the activation-fenced room bookkeeping turn that production room
/// actors use for room-owned operation ledgers and review jobs. Control-plane
/// housekeeping never deletes those rows, so integration tests that age them
/// must purge through this path.
func purgeRoomBookkeeping(
    database: any Database,
    roomID: UUID,
    shardID: String = "room-a",
    now: Date,
    retention: TimeInterval = 7 * 86_400,
    idempotencyRetention: TimeInterval = V2IdempotencyPolicy.minimumServerRetention
) async throws -> V2ActorRoomBookkeepingPurgeResultWire {
    try await withRoomActivation(database: database, roomID: .init(uuid: roomID), shardID: shardID) { token in
        try await PostgresV2RoomBookkeepingStore(database: database).purge(
            token: token, now: now, retention: retention,
            idempotencyRetention: idempotencyRetention, rowLimit: 1_000)
    }
}

/// Source-room forward command transport for delivery-worker tests. Like
/// RoomRef in the gateway, each command runs the production room forward
/// executor under an activation of the source room.
func forwardSourceCommand(
    database: any Database,
    shardID: String = "room-a",
    now: @escaping @Sendable () -> Date
) -> @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult {
    { command, _ in
        try await withRoomActivation(database: database, roomID: command.roomID, shardID: shardID) { token in
            try await V2RoomForwardDomainExecutor(database: database, token: token,
                importExport: { _, _, _ in throw V2RoomCallFailure.notAccepted(.invalidRequest) },
                now: now).execute(command)
        }
    }
}

/// A forward source transport for delivery tests whose target never returns
/// a terminal receipt; any source command is a test failure.
let forwardSourceCommandUnexpected: @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult = { _, _ in
    throw V2RoomCallFailure.notAccepted(.invalidRequest)
}
