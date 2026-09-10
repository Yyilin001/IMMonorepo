import Foundation
import IMV2Core

/// 资料补全所依赖的持久化边界。
///
/// 界面与功能存储依赖 `V2ProfileRepository`，而不直接依赖 GRDB 行。
public protocol V2ClientProfileProjectionStore: Sendable {
    /// 读取指定用户的资料视图。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 资料视图；不存在时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func profileView(userID: UserID) async throws -> V2ProfileView?

    /// 批量读取资料视图。
    ///
    /// - Parameter userIDs: 目标用户列表。
    /// - Returns: 以用户标识为键的资料映射。
    /// - Throws: 持久化失败时抛出。
    func profileViews(userIDs: [UserID]) async throws -> [UserID: V2ProfileView]

    /// 保存资料视图。
    ///
    /// - Parameter profile: 待保存资料。
    /// - Throws: 持久化失败时抛出。
    func saveProfileView(_ profile: V2ProfileView) async throws

    /// 标记用户资料当前不可用。
    ///
    /// - Parameter userID: 目标用户。
    /// - Throws: 持久化失败时抛出。
    func markProfileUnavailable(userID: UserID) async throws

    /// 读取待处理的资料失效通知。
    ///
    /// - Parameter limit: 本次最多返回的条数。
    /// - Returns: 失效通知列表。
    /// - Throws: 持久化失败时抛出。
    func pendingProfileInvalidations(limit: Int) async throws -> [V2ProfileInvalidation]

    /// 应用一次资料查询结果批次。
    ///
    /// - Parameter results: 查询结果。
    /// - Throws: 持久化失败时抛出。
    func applyProfileViewResults(_ results: [V2ProfileViewLookupResult]) async throws
}

/// 资料仓储。
///
/// 协调远端补全与持久化投影。该 actor 不持有界面状态，
/// 也不会把传输 DTO 泄漏到该边界之上。
public actor V2ProfileRepository {
    private let store: any V2ClientProfileProjectionStore
    private let reader: any V2ProfileViewReading

    /// 组合本地投影存储与远端读取实现。
    ///
    /// - Parameters:
    ///   - store: 本地资料投影存储。
    ///   - reader: 远端资料读取实现。
    public init(store: any V2ClientProfileProjectionStore, reader: any V2ProfileViewReading) {
        self.store = store
        self.reader = reader
    }

    /// 读取指定用户的本地资料视图。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 资料视图；本地不存在时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    public func profileView(userID: UserID) async throws -> V2ProfileView? {
        try await store.profileView(userID: userID)
    }

    /// 仅补全请求中给出的上下文。
    ///
    /// 服务端判定为不可用的结果会立即移除该目标此前可能残留的已授权投影。
    ///
    /// - Parameter keys: 待补全的查询键。
    /// - Returns: 本次发生变化的用户集合。
    /// - Throws: 结果数量或键集合与请求不符、同批资料自相矛盾时抛出
    ///   ``V2ProfileRepositoryError/invalidResponse``；其余失败来自远端读取或本地存储。
    @discardableResult
    public func hydrate(_ keys: [V2ProfileViewLookupKey]) async throws -> Set<UserID> {
        guard !keys.isEmpty else { return [] }
        let results = try await reader.readProfileViews(keys)
        guard results.count == keys.count,
              Set(results.map(\.key)) == Set(keys),
              V2ProfileViewResultBatch(results).hasConsistentProfiles
        else {
            throw V2ProfileRepositoryError.invalidResponse
        }
        try Task.checkCancellation()
        try await store.applyProfileViewResults(results)
        var changedUserIDs = Set<UserID>()
        for result in results {
            try Task.checkCancellation()
            switch result {
            case .profile(_, let view):
                changedUserIDs.insert(view.userID)
            case .unavailable(let key):
                changedUserIDs.insert(key.userID)
            }
        }
        return changedUserIDs
    }

    /// 刷新待处理的资料失效通知。
    ///
    /// 私聊资料的失效通过持久化个人同步日志投递，因此隐含私聊房间的授权上下文。
    ///
    /// - Parameter limit: 本次最多处理的失效条数，默认取查询键上限。
    /// - Returns: 本次发生变化的用户集合。
    /// - Throws: 与 ``hydrate(_:)`` 相同的错误。
    @discardableResult
    public func refreshPendingInvalidations(limit: Int = V2ProfileViewLookupLimits.maximumKeys) async throws -> Set<UserID> {
        let invalidations = try await store.pendingProfileInvalidations(limit: limit)
        return try await hydrate(invalidations.map {
            .init(userID: $0.userID, context: .directConversation)
        })
    }

    /// 结合本地资料与展示上下文解析出可展示的资料。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - alias: 联系人别名。
    ///   - groupMember: 群成员展示信息。
    ///   - surface: 展示场景。
    /// - Returns: 解析后的资料。
    /// - Throws: 持久化失败时抛出。
    public func resolve(
        userID: UserID,
        alias: V2ContactAlias? = nil,
        groupMember: V2GroupMemberPresentation? = nil,
        surface: V2ProfileDisplaySurface
    ) async throws -> V2ResolvedProfile {
        V2ProfileResolver.resolve(
            userID: userID,
            profile: try await store.profileView(userID: userID),
            alias: alias,
            groupMember: groupMember,
            surface: surface
        )
    }
}

/// 一次资料查询结果批次的汇总。
struct V2ProfileViewResultBatch {
    /// 可用于落库的资料，按用户标识索引。
    let profiles: [UserID: V2ProfileView]
    /// 判定为不可用的用户集合。
    let unavailableUserIDs: Set<UserID>
    /// 同一用户是否出现互相矛盾的资料。
    let hasConsistentProfiles: Bool

    /// 汇总查询结果。
    ///
    /// - Parameter results: 查询结果列表。
    init(_ results: [V2ProfileViewLookupResult]) {
        var profiles: [UserID: V2ProfileView] = [:]
        var unavailableUserIDs = Set<UserID>()
        var isConsistent = true
        for result in results {
            switch result {
            case .profile(_, let profile):
                if let existing = profiles[profile.userID], existing != profile {
                    isConsistent = false
                } else {
                    profiles[profile.userID] = profile
                }
            case .unavailable(let key):
                unavailableUserIDs.insert(key.userID)
            }
        }
        self.profiles = profiles
        self.unavailableUserIDs = unavailableUserIDs
        hasConsistentProfiles = isConsistent
    }
}

/// 资料仓储错误。
public enum V2ProfileRepositoryError: Error, Equatable, Sendable {
    /// 资料接口必须为每个请求的授权上下文恰好返回一条结果。
    ///
    /// 把部分响应当作成功处理，可能会让已经失效、不再可读的取值继续留在本地磁盘上。
    case invalidResponse
}
