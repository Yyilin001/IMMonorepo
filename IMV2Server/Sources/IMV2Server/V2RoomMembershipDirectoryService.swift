import Foundation
import IMV2Core

/// 成员名录中的单条记录。
///
/// 名录刻意做成有界的读取接口而不是同步投影：把大型房间的完整名册复制进每个成员的
/// 增量历史，会让一次成员事实产生 O(n²) 的持久化数据量。
public struct V2RoomMembershipDirectoryEntry: Equatable, Sendable {
    /// 成员用户标识。
    public let userID: UserID
    /// 成员在房间内的角色。
    public let role: V2RoomMembershipRole
    /// 本次名册读取所授权的当前公开聊天身份。
    ///
    /// 资料未生效的成员会被省略，而不会用只有内部标识、无法展示身份的记录占位。
    public let publicIdentity: V2PublicIdentity

    /// 保存名录记录。
    ///
    /// - Parameters:
    ///   - userID: 成员用户标识。
    ///   - role: 房间内角色。
    ///   - publicIdentity: 公开身份资料。
    public init(userID: UserID, role: V2RoomMembershipRole, publicIdentity: V2PublicIdentity) {
        self.userID = userID
        self.role = role
        self.publicIdentity = publicIdentity
    }
}

/// 成员名录的一页。
public struct V2RoomMembershipDirectoryPage: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 本页对应的成员修订。
    public let membershipRevision: UInt64
    /// 发起者的房间角色，每页都会重复返回。
    ///
    /// 这样管理界面无需枚举整个名册就能得知已认证发起者自身的角色。
    public let actorRole: V2RoomMembershipRole
    /// 本页成员记录。
    public let entries: [V2RoomMembershipDirectoryEntry]
    /// 下一页游标，对调用方不透明。
    ///
    /// 游标把查找边界绑定到本房间与同一个成员修订，因此名册变化期间的不同版本页面不会混在一起。
    public let nextCursor: String?

    /// 保存名录分页。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - membershipRevision: 本页成员修订。
    ///   - actorRole: 发起者角色。
    ///   - entries: 成员记录。
    ///   - nextCursor: 下一页游标，为空表示已到末尾。
    public init(roomID: RoomID, membershipRevision: UInt64, actorRole: V2RoomMembershipRole, entries: [V2RoomMembershipDirectoryEntry], nextCursor: String?) {
        self.roomID = roomID
        self.membershipRevision = membershipRevision
        self.actorRole = actorRole
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

/// 成员名录查询请求。
public struct V2RoomMembershipDirectoryRequest: Equatable, Sendable {
    /// 单页允许的最大条数。
    public static let maximumPageSize = 100
    /// 游标允许的最大字节数。
    public static let maximumCursorBytes = 512

    /// 目标房间。
    public let roomID: RoomID
    /// 发起查询的用户。
    public let actorUserID: UserID
    /// 上一页游标，已去除首尾空白。
    public let cursor: String?
    /// 本页条数。
    public let pageSize: Int

    /// 规范化并校验查询请求。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起查询的用户。
    ///   - cursor: 上一页游标；为空表示从头开始。
    ///   - pageSize: 本页条数，需大于零且不超过 ``maximumPageSize``。
    /// - Throws: 条数越界，或游标去除空白后为空或超过 ``maximumCursorBytes`` 时抛出
    ///   ``V2RoomMembershipDirectoryError/invalidRequest``。
    public init(roomID: RoomID, actorUserID: UserID, cursor: String?, pageSize: Int) throws {
        let trimmedCursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pageSize > 0, pageSize <= Self.maximumPageSize,
              trimmedCursor.map({ !$0.isEmpty && $0.utf8.count <= Self.maximumCursorBytes }) ?? true
        else { throw V2RoomMembershipDirectoryError.invalidRequest }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.cursor = trimmedCursor
        self.pageSize = pageSize
    }
}

/// 成员名录读取的持久化能力。
public protocol V2RoomMembershipDirectoryStore: Sendable {
    /// 读取一页成员名录。
    ///
    /// - Parameter request: 已校验的查询请求。
    /// - Returns: 成员名录分页。
    /// - Throws: 房间不存在、发起者非成员、游标非法或持久化失败时抛出。
    func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage
}

/// 成员名录服务。
///
/// 校验与授权留在窄接口之后，便于独立测试。网关适配器只能传入已认证的发起者身份，
/// 不会拿到无界名册。
public struct V2RoomMembershipDirectoryService: Sendable {
    private let store: any V2RoomMembershipDirectoryStore

    /// 组合名录存储。
    ///
    /// - Parameter store: 实际执行读取的存储实现。
    public init(store: any V2RoomMembershipDirectoryStore) {
        self.store = store
    }

    /// 读取一页成员名录。
    ///
    /// 返回的成员修订必须能写入有符号 64 位范围，否则视为持久化状态损坏。
    ///
    /// - Parameter request: 已校验的查询请求。
    /// - Returns: 成员名录分页。
    /// - Throws: 成员修订超出可编码范围时抛出
    ///   ``V2RoomMembershipDirectoryError/corruptPersistenceState``；其余错误来自存储实现。
    public func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        let page = try await store.list(request)
        guard page.membershipRevision <= UInt64(Int64.max) else {
            throw V2RoomMembershipDirectoryError.corruptPersistenceState
        }
        return page
    }
}

/// 成员名录错误。
public enum V2RoomMembershipDirectoryError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 房间不存在。
    case roomNotFound
    /// 发起者不是房间成员。
    case actorNotMember
    /// 游标非法或已失效。
    case invalidCursor
    /// 成员修订已变化，参数为当前修订。
    case revisionConflict(currentRevision: UInt64)
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
