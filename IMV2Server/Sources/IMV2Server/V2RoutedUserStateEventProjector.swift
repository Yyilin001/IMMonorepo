import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 解析用户当前归属并投递事件；持久化回执保证重试不重复分配序号。
public struct V2RoutedUserStateEventProjector: V2UserStateEventProjecting {
    private let routeFence: any V2UserShardRouteFencing
    private let registry: any V2UserShardStorageResolving
    private let controlSchema: String

    /// routeFence 必须使用独立于 registry 数据写入的连接池。
    public init(routeFence: any V2UserShardRouteFencing, registry: any V2UserShardStorageResolving,
                controlSchema: String = "im_v2") throws {
        guard controlSchema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2UserStateEventError.invalidEvent
        }
        self.controlSchema = controlSchema
        self.routeFence = routeFence
        self.registry = registry
    }

    public func project(_ event: V2UserStateEvent) async throws -> UInt64 {
        try await routeFence.withCurrentRoute(for: event.userID) { route, control in
            guard let sql = control as? any SQLDatabase, event.userID.uuidValue != nil else {
                throw V2UserStateEventError.corruptPersistenceState
            }
            let owner = try registry.location(for: route.bucket)
            let resolvedPayload = event.kind == .directReadReceipt
                ? try await v2ResolveDirectReadReceiptCandidate(event, sql: sql, schema: controlSchema)
                : nil
            let projection = try await PostgresV2UserStateEventProjector(database: owner.database, schema: owner.schema)
                .projectResolved(event, projectionPayload: resolvedPayload)

            return projection.sequence
        }
    }
}
