import IMV2Core

/// 房间内容的权威副本形态。
///
/// 这是**服务端宣告的房间能力**，与 `rooms.delivery_mode` 刻意分开：投递模式描述用哪种
/// 扇出规划器，并且在房间创建后不可变；权威副本形态描述客户端该按个人流还是按房间游标
/// 恢复，可以在不重建房间的前提下按房间推进。
///
/// 今天的取值由投递模式推导（混合大群 = 房间日志），与既有客户端从 `delivery_mode` 推断
/// 的结果一致；把标准群推广到读模型时只改这一处推导，客户端无需再发版。
public enum V2RoomDeliveryAuthority: String, Codable, Equatable, Sendable {
    /// 逐用户投递是权威副本，房间日志只是加速。
    case fanout
    /// 房间事件日志是权威副本，客户端按房间游标恢复。
    case roomLog = "room_log"
}

/// 按当前规则推导房间的权威副本形态。
///
/// 混合大群一直以房间日志为权威副本；标准群的权威副本形态由部署策略决定，因此它可以
/// 在不重建房间（投递模式不可变）的前提下切到读模型。
///
/// - Parameters:
///   - deliveryMode: 房间的投递模式。
///   - configured: 部署为**标准群**选择的权威副本形态；默认与部署默认一致（`room_log`），
///     兼容基线必须显式传 `fanout`。
/// - Returns: 该房间当前的权威副本形态。
func v2RoomDeliveryAuthority(
    _ deliveryMode: V2GroupDeliveryMode,
    configured: V2RoomDeliveryAuthority = .roomLog
) -> V2RoomDeliveryAuthority {
    deliveryMode == .largeGroupHybrid ? .roomLog : configured
}

/// 合并"投递模式隐含的形态"与"房间列上存的形态"。
///
/// 混合大群**始终**以房间日志为权威副本，这是 `delivery_mode` 自带的语义；房间列只可能
/// 把标准群**升级**为读模型。这样即使房间行由历史写入路径或夹具直接插入、没有显式写列，
/// 也不会让混合大群意外退回逐用户投递。
///
/// - Parameters:
///   - deliveryMode: 房间的投递模式。
///   - stored: 房间列上保存的权威副本形态。
/// - Returns: 该房间实际生效的权威副本形态。
func v2EffectiveRoomDeliveryAuthority(
    _ deliveryMode: V2GroupDeliveryMode,
    stored: V2RoomDeliveryAuthority
) -> V2RoomDeliveryAuthority {
    deliveryMode == .largeGroupHybrid || stored == .roomLog ? .roomLog : .fanout
}
