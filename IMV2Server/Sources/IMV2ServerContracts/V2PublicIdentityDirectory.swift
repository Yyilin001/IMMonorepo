import Foundation
import IMV2Core

/// 公开身份目录错误。
public enum V2PublicIdentityDirectoryError: Error, Equatable, Sendable {
    /// 目录或数据库当前不可用。
    case unavailable
    /// 查询预算已用尽，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
}

/// 按公开账号名解析身份的能力。
public protocol V2PublicIdentityDirectoryReading: Sendable {
    /// 解析公开账号名对应的身份。
    ///
    /// - Parameters:
    ///   - handle: 公开账号名。
    ///   - actorUserID: 发起查询的用户。
    /// - Returns: 对应身份；账号不存在、未生效或对方拉黑了发起者时返回 `nil`。
    /// - Throws: 存储不可用或触发限流时抛出。
    func resolve(handle: V2PublicHandle, actorUserID: UserID) async throws -> V2PublicIdentity?
}

/// 公开身份的读取与管理能力。
public protocol V2PublicIdentityAccountManaging: V2PublicIdentityDirectoryReading {
    /// 读取指定用户的公开身份。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 公开身份；账号不存在或未生效时返回 `nil`。
    /// - Throws: 存储不可用时抛出。
    func profile(for userID: UserID) async throws -> V2PublicIdentity?

    /// 更新指定用户的展示名称。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - displayName: 新的展示名称。
    /// - Returns: 更新后（或未变化时原样返回）的公开身份。
    /// - Throws: 名称不合法或存储不可用时抛出。
    func updateDisplayName(for userID: UserID, displayName: String) async throws -> V2PublicIdentity
}
