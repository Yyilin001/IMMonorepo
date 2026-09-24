import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server

/// Runs the activation-fenced room bookkeeping turn that production room
/// actors use for room-owned operation ledgers and review jobs. Control-plane
/// housekeeping never deletes those rows, so integration tests that age them
/// must purge through this path. The lease is released before returning.
func purgeRoomBookkeeping(
    database: any Database,
    roomID: UUID,
    shardID: String = "room-a",
    now: Date,
    retention: TimeInterval = 7 * 86_400,
    idempotencyRetention: TimeInterval = V2IdempotencyPolicy.minimumServerRetention
) async throws -> V2ActorRoomBookkeepingPurgeResultWire {
    let leases = PostgresV2RoomActivationStore(database: database)
    let host = V2ActorHostIdentity(hostID: try .init("bookkeeping-test"), incarnationID: UUID())
    guard case .acquired(let lease) = try await leases.acquire(roomID: .init(uuid: roomID),
        owner: try V2RoomDataOwner(shardID: shardID, epoch: 0), host: host,
        duration: try .init(10_000)) else {
        throw V2RoomActivationLeaseError.activationChanged
    }
    let result = try await PostgresV2RoomBookkeepingStore(database: database).purge(
        token: lease.token, now: now, retention: retention,
        idempotencyRetention: idempotencyRetention, rowLimit: 1_000)
    _ = try await leases.release(token: lease.token)
    return result
}
