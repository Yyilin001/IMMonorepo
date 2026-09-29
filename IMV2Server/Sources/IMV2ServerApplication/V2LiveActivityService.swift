import IMV2ServerContracts
import Foundation
import IMV2Core

/// 实时状态服务，负责把调用转交存储并保证授权判定始终在数据库侧完成。
public struct V2LiveActivityService: Sendable, V2LiveActivityObservationAuthorizing {
    private let store: any V2LiveActivityStore

    /// 组合实时状态存储。
    ///
    /// - Parameter store: 执行授权与偏好操作的存储实现。
    public init(store: any V2LiveActivityStore) { self.store = store }

    /// 设置实时状态偏好。
    ///
    /// - Parameters:
    ///   - command: 偏好变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 存储实现抛出的错误。


    /// 读取实时状态偏好。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 生效偏好。
    /// - Throws: 存储实现抛出的错误。
    public func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences {
        try await store.preferences(userID: userID, now: now)
    }

    /// 读取房间对指定观察者可见的在线状态。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - viewerUserID: 发起观察的用户。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 当前在线状态。
    /// - Throws: 存储实现抛出的错误。
    public func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState {
        try await store.presence(roomID: roomID, viewerUserID: viewerUserID, now: now)
    }

    /// 校验是否可以发送正在输入提示。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起提示的用户。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 存储实现抛出的错误。
    public func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) async throws {
        try await store.authorizeTyping(roomID: roomID, actorUserID: actorUserID, now: now)
    }

    /// 为瞬时事件校验投递授权。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - viewerUserID: 观察者。
    ///   - subjectUserID: 被观察的成员。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 存储实现抛出的错误。
    public func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) async throws {
        try await store.authorizeObservation(
            roomID: roomID,
            viewerUserID: viewerUserID,
            subjectUserID: subjectUserID,
            now: now
        )
    }

    /// 查询用户的偏好是否允许展示在线状态。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 允许展示时为 `true`。
    /// - Throws: 存储实现抛出的错误。
    public func allowsOnlinePresence(userID: UserID) async throws -> Bool {
        try await store.allowsOnlinePresence(userID: userID)
    }
}
