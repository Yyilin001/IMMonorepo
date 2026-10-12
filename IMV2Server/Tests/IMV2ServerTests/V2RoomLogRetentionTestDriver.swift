import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import SQLKit
@testable import IMV2ServerInfrastructure

/// Runs retention regressions through the current candidate scan and exact
/// native Actor room write instead of the retired unowned batch SQL path.
actor V2RoomLogRetentionTestDriver {
    private let database: any Database
    private let scanner: PostgresV2RoomLogRetentionStore
    private let eventLimit: Int

    init(database: any Database, eventLimit: Int = 512) {
        self.database = database
        self.scanner = .init(database: database, eventLimit: eventLimit)
        self.eventLimit = eventLimit
    }

    func trimRoomLogs(mode: V2RoomLogRetentionMode, window: TimeInterval,
                      now: Date, limit: Int) async throws -> V2RoomLogTrimReport {
        let sql = try requireSQL(database)
        let candidates = try await scanner.scanCandidateRoomIDs(limit: limit)
        var scanned = 0, trimmed = 0, deleted = 0
        for room in candidates where deleted < eventLimit {
            guard let owner = try await sql.raw("SELECT room_shard_id, owner_epoch FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)")
                .first(decoding: OwnerRow.self) else { throw V2RoomActorStateError.roomNotFound }
            let store = PostgresV2RoomLogRetentionStore(database: database, eventLimit: eventLimit - deleted)
            let report = try await withRoomActivation(database: database, roomID: room,
                shardID: owner.room_shard_id, epoch: owner.owner_epoch) { token in
                try await store.trimRoomLog(token: token, mode: mode, window: window, now: now)
            }
            scanned += report.scannedRooms; trimmed += report.trimmedRooms; deleted += report.deletedEvents
        }
        return .init(scannedRooms: scanned, trimmedRooms: trimmed, deletedEvents: deleted)
    }

    private func requireSQL(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return sql
    }
    private struct OwnerRow: Decodable { let room_shard_id: String; let owner_epoch: Int64 }
}
