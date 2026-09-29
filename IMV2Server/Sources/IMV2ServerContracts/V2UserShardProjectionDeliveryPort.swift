import Foundation
import IMV2Core

/// 用户同步中不参与扇出的一小部分（关系、拉黑与接收偏好）以控制面存储为权威。
///
/// 该边界把已提交记录投递到当前写入归属。
/// 来源操作标识就是持久化重试键，因此响应丢失后可以安全地重复投递，
/// 而不会额外占用目标端序号。
public struct V2UserShardProjectionDeliveryRequest: Sendable {
    /// 目标用户。
    public let userID: UserID
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 需要投递的投影类型集合。
    public let projectionKinds: Set<String>

    /// 保存投递请求。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - sourceEventID: 来源事件标识。
    ///   - projectionKinds: 投影类型集合。
    public init(
        userID: UserID,
        sourceEventID: EventID,
        projectionKinds: Set<String>
    ) {
        self.userID = userID
        self.sourceEventID = sourceEventID
        self.projectionKinds = projectionKinds
    }
}

/// 用户分片投影当前归属投递能力。
public protocol V2UserShardProjectionDelivering: Sendable {
    /// 把既有控制面记录写入用户当前写入归属。
    ///
    /// 返回的序号属于当前写入归属，可用于尽力而为的实时同步提示；
    /// 返回 `nil` 表示控制面存储中不存在所请求的来源投影。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - sourceEventID: 来源事件标识。
    ///   - projectionKinds: 投影类型集合。
    /// - Returns: 当前写入归属的序号；无来源投影时为 `nil`。
    /// - Throws: 路由或存储失败时抛出。
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64?

    /// 投递一个有界的已提交微批。
    ///
    /// 结果保持请求顺序，语义等同于逐条调用标量方法。具体存储可以把路由栅栏与来源读取
    /// 合并为集合式操作；默认实现保证既有适配器行为正确。
    ///
    /// - Parameter requests: 待投递请求列表。
    /// - Returns: 与输入顺序对应的序号结果。
    /// - Throws: 路由或存储失败时抛出。
    func deliverToCurrentShard(
        _ requests: [V2UserShardProjectionDeliveryRequest]
    ) async throws -> [UInt64?]
}

public extension V2UserShardProjectionDelivering {
    /// 逐条投递的默认实现。
    ///
    /// - Parameter requests: 待投递请求列表。
    /// - Returns: 与输入顺序对应的序号结果。
    /// - Throws: 任一条目失败时抛出。
    func deliverToCurrentShard(
        _ requests: [V2UserShardProjectionDeliveryRequest]
    ) async throws -> [UInt64?] {
        var results: [UInt64?] = []
        results.reserveCapacity(requests.count)
        for request in requests {
            results.append(try await deliverToCurrentShard(
                userID: request.userID,
                sourceEventID: request.sourceEventID,
                projectionKinds: request.projectionKinds
            ))
        }
        return results
    }
}
