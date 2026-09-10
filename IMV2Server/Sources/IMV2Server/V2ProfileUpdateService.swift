import Foundation
import IMV2Core

/// 受修订号约束的资料变更结果。
///
/// `idempotent` 表示同一操作此前已经提交，调用方拿到的是该次变更产生的原资料修订，
/// 不会因此再分配一次传播事件。
public enum V2ProfileUpdateOutcome: Equatable, Sendable {
    /// 本次调用实际提交了资料变更。
    case updated(V2ProfileView)
    /// 同一操作已提交过，返回其原有资料视图。
    case idempotent(V2ProfileView)
}

/// 资料变更的持久化能力。
public protocol V2ProfileUpdateStore: Sendable {
    /// 应用一次资料变更。
    ///
    /// - Parameter command: 资料变更命令。
    /// - Returns: 变更结果。
    /// - Throws: 修订冲突、操作载荷不一致或持久化失败时抛出。
    func update(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateOutcome
}

/// 本人资料读取能力。
///
/// 与变更能力分开声明，便于两者独立测试；资料 API 在启动时组合二者。
public protocol V2OwnProfileReading: Sendable {
    /// 读取指定用户的当前资料。
    ///
    /// - Parameter actorUserID: 需要读取资料的用户。
    /// - Returns: 该用户的当前资料视图。
    /// - Throws: 用户不存在或持久化失败时抛出。
    func currentProfile(for actorUserID: UserID) async throws -> V2ProfileView
}

/// 资料变更与本人资料读取的组合服务。
public struct V2ProfileUpdateService: Sendable {
    private let store: any V2ProfileUpdateStore
    private let reader: any V2OwnProfileReading

    /// 组合资料变更存储与读取实现。
    ///
    /// - Parameters:
    ///   - store: 执行资料变更的存储。
    ///   - reader: 读取本人资料的实现。
    public init(store: any V2ProfileUpdateStore, reader: any V2OwnProfileReading) {
        self.store = store
        self.reader = reader
    }

    /// 应用一次资料变更。
    ///
    /// - Parameter command: 资料变更命令。
    /// - Returns: 变更结果。
    /// - Throws: 存储实现抛出的错误。
    public func update(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateOutcome {
        try await store.update(command)
    }

    /// 读取指定用户的当前资料。
    ///
    /// - Parameter actorUserID: 需要读取资料的用户。
    /// - Returns: 该用户的当前资料视图。
    /// - Throws: 读取实现抛出的错误。
    public func currentProfile(for actorUserID: UserID) async throws -> V2ProfileView {
        return try await reader.currentProfile(for: actorUserID)
    }
}

/// 资料变更错误。
public enum V2ProfileUpdateError: Error, Equatable, Sendable {
    /// 资料存储当前不可用。
    case unavailable
    /// 命令携带的修订与当前资料不一致，参数为当前修订。
    case revisionConflict(current: V2ProfileRevision)
    /// 同一操作标识已被不同载荷的命令占用。
    case operationPayloadMismatch
    /// 头像媒体当前不可用。
    case avatarUnavailable
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
