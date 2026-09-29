import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Route hints select a batching shape only; acceptance still checks owner,
/// activation, authorization and capacity under the transaction's locks.
struct V2RoomWriteBatchRouteResolver: Sendable {
    let database: any Database
    let cache: V2RoomWriteBatchRouteCache

    func resolve(
        roomIDs: [UUID]
    ) async -> [V2RoomWriteBatchRouteCache.Route?] {
        var routes = await cache.values(for: roomIDs)
        let missingRoomIDs = Set(zip(roomIDs, routes).compactMap { roomID, route in
            route == nil ? roomID : nil
        }).sorted { $0.uuidString < $1.uuidString }
        if !missingRoomIDs.isEmpty,
           let loadedRoutes = try? await loadRoomWriteBatchRoutes(roomIDs: missingRoomIDs)
        {
            await cache.insert(loadedRoutes)
            let loadedByRoomID = Dictionary(
                uniqueKeysWithValues: loadedRoutes.map { ($0.roomID, $0.route) }
            )
            for index in routes.indices where routes[index] == nil {
                routes[index] = loadedByRoomID[roomIDs[index]]
            }
        }
        return routes
    }

    /// 只解析建议性批次分类器所需的不可变执行形态。
    ///
    /// 授权、成员、策略、房间状态与容量仍完全只由事务写入路径负责。
    ///
    /// - Parameter roomIDs: 待解析路由的房间标识。
    /// - Returns: 每个房间对应的房间标识与路由。
    /// - Throws: 路由缺失或查询失败时抛出。
    private func loadRoomWriteBatchRoutes(
        roomIDs: [UUID]
    ) async throws -> [(roomID: UUID, route: V2RoomWriteBatchRouteCache.Route)] {
        guard let sql = database as? any SQLDatabase else { return [] }
        let roomIDsJSON = try roomWriteJSON(roomIDs.map(\.uuidString))
        let rows = try await sql.raw("""
            WITH requested AS MATERIALIZED (
                SELECT value::uuid AS room_id
                FROM jsonb_array_elements_text(\(bind: roomIDsJSON)::jsonb) AS value
            )
            SELECT room.room_id, room.room_kind, room.capacity_class
            FROM requested
            JOIN im_v2.rooms AS room USING (room_id)
            """).all(decoding: RoomWriteBatchRouteRow.self)
        return rows.map { row in
            let route: V2RoomWriteBatchRouteCache.Route
            if row.roomKind == "direct" {
                route = .direct
            } else if row.roomKind == "group",
                      row.capacityClass == V2GroupCapacityClass.large.rawValue {
                route = .large
            } else {
                route = .individual
            }
            return (
                roomID: row.roomID,
                route: route
            )
        }
    }

}

private struct RoomWriteBatchRouteRow: Decodable {
    let roomID: UUID
    let roomKind: String
    let capacityClass: String

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomKind = "room_kind"
        case capacityClass = "capacity_class"
    }
}
