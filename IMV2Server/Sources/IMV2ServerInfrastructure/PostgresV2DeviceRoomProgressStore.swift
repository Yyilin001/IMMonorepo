import FluentKit
import IMV2Core
import IMV2ServerContracts
import SQLKit
import Foundation

/// Account-local device progress; no membership or authentication query occurs
/// here. Authorization belongs to the Gateway's live delivery grant.
public struct PostgresV2DeviceRoomProgressStore: V2DeviceRoomProgressStoring {
    private let database: any Database
    private let schema: String
    public init(database: any Database, schema: String = "im_v2") throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        self.database = database; self.schema = schema
    }

    public func record(userID: UserID, deviceID: DeviceID, progress: [V2DeviceRoomProgress]) async throws {
        guard progress.count <= 64, Set(progress.map(\.roomID)).count == progress.count,
              let user = userID.uuidValue, let device = deviceID.uuidValue,
              let sql = database as? any SQLDatabase else { throw V2RoomRecoveryReadError.invalidRequest }
        guard !progress.isEmpty else { return }
        let rooms = try progress.map { item -> UUID in
            guard let id = item.roomID.uuidValue else { throw V2RoomRecoveryReadError.invalidRequest }
            return id
        }
        let cursors = progress.map { Int64($0.appliedThrough) }
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).device_room_progress AS current (user_id, device_id, room_id, applied_through)
            SELECT \(bind: user), \(bind: device), report.room_id, report.applied_through
            FROM unnest(\(bind: rooms)::uuid[], \(bind: cursors)::bigint[]) AS report(room_id, applied_through)
            ORDER BY report.room_id
            ON CONFLICT (user_id, device_id, room_id) DO UPDATE
            SET applied_through = EXCLUDED.applied_through
            WHERE current.applied_through < EXCLUDED.applied_through
            """).run()
    }

    public func load(userID: UserID, deviceID: DeviceID, roomIDs: [RoomID]) async throws -> [RoomID: UInt64] {
        guard roomIDs.count <= 64, Set(roomIDs).count == roomIDs.count,
              let user = userID.uuidValue, let device = deviceID.uuidValue,
              let sql = database as? any SQLDatabase else { throw V2RoomRecoveryReadError.invalidRequest }
        guard !roomIDs.isEmpty else { return [:] }
        let rooms = try roomIDs.map { room -> UUID in
            guard let id = room.uuidValue else { throw V2RoomRecoveryReadError.invalidRequest }
            return id
        }
        let rows = try await sql.raw("""
            SELECT room_id, applied_through FROM \(unsafeRaw: schema).device_room_progress
            WHERE user_id = \(bind: user) AND device_id = \(bind: device)
              AND room_id = ANY(\(bind: rooms)::uuid[])
            """).all()
        var result: [RoomID: UInt64] = [:]
        for row in rows {
            let room = RoomID(uuid: try row.decode(column: "room_id", as: UUID.self))
            let cursor = try row.decode(column: "applied_through", as: Int64.self)
            guard cursor >= 0, result[room] == nil else { throw V2RoomRecoveryReadError.corruptPersistence }
            result[room] = UInt64(cursor)
        }
        return result
    }
}
