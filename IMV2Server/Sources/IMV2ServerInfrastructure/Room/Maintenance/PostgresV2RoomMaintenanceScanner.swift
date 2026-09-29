import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 每个物理所有者数据库对应一个实例。簿记扫描按有界键顺序访问
/// 所有本地房间，无须新增资格索引或 schema；
/// 逐房间命令会在围栏下检查终态条件。
public actor PostgresV2RoomMaintenanceScanner: V2RoomMaintenanceScanning {
    private let database: any Database
    private let retention: PostgresV2RoomLogRetentionStore
    private var lastBookkeepingRoomID: UUID?

    public init(database: any Database) {
        self.database = database
        self.retention = .init(database: database)
    }

    public func retentionCandidates(limit: Int) async throws -> [RoomID] {
        try await retention.scanCandidateRoomIDs(limit: limit)
    }

    public func bookkeepingCandidates(limit: Int) async throws -> [RoomID] {
        guard (1...1_000).contains(limit) else { throw V2ControlPlaneHousekeepingError.invalidLimit }
        guard let sql = database as? any SQLDatabase else {
            throw V2ControlPlaneHousekeepingError.corruptPersistenceState
        }
        let after = lastBookkeepingRoomID
        let predicate: SQLQueryString = if let after { "room_id > \(bind: after)" } else { "TRUE" }
        var rows = try await sql.raw("""
            SELECT room_id FROM im_v2.rooms WHERE \(predicate)
            ORDER BY room_id LIMIT \(bind: limit)
            """).all(decoding: V2RoomMaintenanceScanRow.self)
        if rows.isEmpty, after != nil {
            rows = try await sql.raw("""
                SELECT room_id FROM im_v2.rooms ORDER BY room_id LIMIT \(bind: limit)
                """).all(decoding: V2RoomMaintenanceScanRow.self)
        }
        lastBookkeepingRoomID = rows.last?.roomID
        return rows.map { RoomID(uuid: $0.roomID) }
    }
}

private struct V2RoomMaintenanceScanRow: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}
