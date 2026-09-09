import Foundation

/// 同一房间当前版本下共同读取的完整有效角色策略基线。
///
/// 不是声称两个角色在该版本都发生变更的事件。空集合表示全部拒绝，默认策略必须在生成基线前由所有者解析。
public struct V2GroupRolePolicyBaseline: Equatable, Sendable {
    /// 策略所属房间，构造时要求可解析为 UUID。
    public let roomID: RoomID
    /// 本次观察的正权限修订号。
    public let permissionRevision: UInt64
    /// 同一观察中的成员修订号，允许零。
    public let membershipRevision: UInt64
    /// 同一观察中的房间序号，允许零。
    public let roomSequence: UInt64
    /// 已解析默认或覆盖规则后的完整管理员权限集合。
    public let adminPermissions: Set<V2GroupPermission>
    /// 已解析后的完整普通成员权限集合。
    public let memberPermissions: Set<V2GroupPermission>

    /// 构造完整策略基线，校验房间 UUID 及各版本数值范围。
    ///
    /// - Parameters:
    ///   - roomID: 可解析为 UUID 的房间身份，保存输入表示。
    ///   - permissionRevision: 1 到 Int64.max 的权限版本。
    ///   - membershipRevision: 0 到 Int64.max 的成员版本。
    ///   - roomSequence: 0 到 Int64.max 的房间序号。
    ///   - adminPermissions: 管理员完整有效权限，允许空集合。
    ///   - memberPermissions: 普通成员完整有效权限，允许空集合。
    /// - Throws: 身份无效报告 invalidIdentifier；权限版本无效报告 invalidPositiveValue；成员版本或序号越界报告 invalidNonNegativeValue。
    ///
    /// 不自动补充默认权限，不证明这些字段来自同一事务，该一致性由调用方保证。
    public init(
        roomID: RoomID,
        permissionRevision: UInt64,
        membershipRevision: UInt64,
        roomSequence: UInt64,
        adminPermissions: Set<V2GroupPermission>,
        memberPermissions: Set<V2GroupPermission>
    ) throws {
        guard UUID(uuidString: roomID.rawValue) != nil else { throw V2CoreError.invalidIdentifier }
        guard permissionRevision > 0, permissionRevision <= UInt64(Int64.max) else { throw V2CoreError.invalidPositiveValue }
        guard membershipRevision <= UInt64(Int64.max), roomSequence <= UInt64(Int64.max) else { throw V2CoreError.invalidNonNegativeValue }
        self.roomID = roomID
        self.permissionRevision = permissionRevision
        self.membershipRevision = membershipRevision
        self.roomSequence = roomSequence
        self.adminPermissions = adminPermissions
        self.memberPermissions = memberPermissions
    }
}
