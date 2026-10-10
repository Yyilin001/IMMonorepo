import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import SQLKit
@testable import IMV2ServerInfrastructure

/// Runs retention regressions through the current candidate scan and exact
/// activation-fenced room write instead of the retired unowned batch SQL path.
actor V2RoomLogRetentionTestDriver {
    private let database: any Database
    private let scanner: PostgresV2RoomLogRetentionStore
    private let eventLimit: Int
    private let leases: PostgresV2RoomActivationStore
    private let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())

    init(database: any Database, eventLimit: Int = 512) {
        self.database = database
        self.scanner = .init(database: database, eventLimit: eventLimit)
        self.eventLimit = eventLimit
        self.leases = .init(database: database)
    }

    func trimRoomLogs(mode: V2RoomLogRetentionMode, window: TimeInterval,
                      now: Date, limit: Int) async throws -> V2RoomLogTrimReport {
        let sql = try requireSQL(database)
        let candidates = try await scanner.scanCandidateRoomIDs(limit: limit)
        var scanned = 0, trimmed = 0, deleted = 0
        for room in candidates where deleted < eventLimit {
            guard let owner = try await sql.raw("SELECT room_shard_id, owner_epoch FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)")
                .first(decoding: OwnerRow.self) else { throw V2RoomActivationLeaseError.roomNotFound }
            let token: V2RoomActivationToken
            switch try await leases.acquire(roomID: room, owner: .init(shardID: owner.room_shard_id, epoch: owner.owner_epoch),
                                            host: host, duration: .init(60_000)) {
            case .acquired(let lease): token = lease.token
            case .occupied: throw V2RoomActivationLeaseError.activationChanged
            }
            do {
                let store = PostgresV2RoomLogRetentionStore(database: database, eventLimit: eventLimit - deleted)
                let report = try await store.trimRoomLog(token: token, mode: mode, window: window, now: now)
                scanned += report.scannedRooms; trimmed += report.trimmedRooms; deleted += report.deletedEvents
                _ = try await leases.release(token: token)
            } catch {
                _ = try? await leases.release(token: token)
                throw error
            }
        }
        return .init(scannedRooms: scanned, trimmedRooms: trimmed, deletedEvents: deleted)
    }

    private func requireSQL(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return sql
    }
    private struct OwnerRow: Decodable { let room_shard_id: String; let owner_epoch: Int64 }
}
