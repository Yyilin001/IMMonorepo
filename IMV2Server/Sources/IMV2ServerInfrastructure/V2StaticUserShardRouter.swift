import Foundation
import FluentKit
import SQLKit
import IMV2Core

/// Immutable deployment routing snapshot. Realtime source authorization and
/// registration-head reads must not borrow the routing pool for every user.
/// Business transactions still use V2UserShardRouteFencing where required.
public struct V2StaticUserShardRouter: V2UserShardRouter {
    public let defaultRoute: V2UserShardRoute
    private let overrides: [UserID: V2UserShardRoute]

    private init(defaultRoute: V2UserShardRoute, overrides: [UserID: V2UserShardRoute]) {
        self.defaultRoute = defaultRoute
        self.overrides = overrides
    }

    public static func load(database: any Database, maximumOverrides: Int = 100_000) async throws -> Self {
        guard maximumOverrides > 0, maximumOverrides <= 1_000_000,
              let sql = database as? any SQLDatabase else { throw V2UserShardRouterError.invalidRoute }
        // A single statement gives one snapshot for both config and overrides.
        // Static deployment config changes require an explicit restart/reload.
        let rows = try await sql.raw("""
            SELECT config.default_write_bucket AS default_bucket, config.router_epoch AS default_epoch,
                   route.user_id::text AS user_id, route.write_bucket, route.router_epoch
            FROM im_v2.user_shard_router_configuration AS config
            LEFT JOIN im_v2.user_shard_route_overrides AS route ON TRUE
            WHERE config.configuration_key = TRUE
            ORDER BY route.user_id
            LIMIT \(bind: maximumOverrides + 1)
            """).all(decoding: Row.self)
        guard let first = rows.first, rows.count <= maximumOverrides else {
            throw V2UserShardRouterError.resultCountMismatch
        }
        let defaultRoute = try V2UserShardRoute(bucket: first.defaultBucket, observedRouterEpoch: first.defaultEpoch)
        var overrides: [UserID: V2UserShardRoute] = [:]
        for row in rows {
            guard row.defaultBucket == first.defaultBucket, row.defaultEpoch == first.defaultEpoch else {
                throw V2UserShardRouterError.invalidRoute
            }
            guard let id = row.userID else {
                guard rows.count == 1, row.writeBucket == nil, row.routerEpoch == nil else {
                    throw V2UserShardRouterError.invalidRoute
                }
                continue
            }
            let user = try UserID(id)
            guard overrides[user] == nil else { throw V2UserShardRouterError.invalidRoute }
            overrides[user] = try .init(bucket: row.writeBucket ?? defaultRoute.bucket,
                                        observedRouterEpoch: row.routerEpoch ?? defaultRoute.observedRouterEpoch)
        }
        return .init(defaultRoute: defaultRoute, overrides: overrides)
    }

    public func routes(for users: [UserID]) async throws -> [V2UserShardRoute] {
        users.map { overrides[$0] ?? defaultRoute }
    }

    private struct Row: Decodable {
        let defaultBucket: String
        let defaultEpoch: Int64
        let userID: String?
        let writeBucket: String?
        let routerEpoch: Int64?
        enum CodingKeys: String, CodingKey {
            case defaultBucket = "default_bucket", defaultEpoch = "default_epoch"
            case userID = "user_id", writeBucket = "write_bucket", routerEpoch = "router_epoch"
        }
    }
}
