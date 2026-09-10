import IMV2Core

/// 通过已认证连接获取完整的当前策略观测。
///
/// 应用该观测仍需本地账号、成员关系与版本三重栅栏；仅获取不会修改任何投影或恢复意图。
public protocol V2ClientGroupRolePolicyBaselineTransport: Sendable {
    /// 读取房间当前的角色策略基线。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 服务端给出的完整策略基线。
    /// - Throws: 会话未认证、房间不可访问或响应不合法时抛出。
    func fetchRolePolicyBaseline(roomID: RoomID) async throws -> V2GroupRolePolicyBaseline
}
