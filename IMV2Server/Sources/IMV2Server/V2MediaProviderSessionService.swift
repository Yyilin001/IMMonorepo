import Foundation
import IMV2Core

/// 提供方对象目标。
///
/// 该值只会从已认证的媒体边缘返回给请求设备。它刻意不实现 `Codable`，
/// 也绝不能进入聊天事件、日志字段、推送载荷或数据库记录。
public struct V2MediaProviderObjectTarget: Equatable, Sendable {
    /// 提供方签发的访问地址。
    public let url: URL
    /// 访问该地址需要携带的请求头。
    public let headers: [String: String]
    /// 目标到期时刻。
    public let expiresAt: Date
    /// 期望的字节数；未知时为 `nil`。
    public let expectedByteCount: Int64?

    /// 保存提供方对象目标。
    ///
    /// - Parameters:
    ///   - url: 访问地址。
    ///   - headers: 附加请求头，默认空。
    ///   - expiresAt: 到期时刻。
    ///   - expectedByteCount: 期望字节数，默认未知。
    public init(url: URL, headers: [String: String] = [:], expiresAt: Date, expectedByteCount: Int64? = nil) {
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
        self.expectedByteCount = expectedByteCount
    }
}

/// 对象存储细节所属的边界。
///
/// 生产适配器可以使用 S3、CDN 或其他提供方，而不会把提供方凭据泄漏到 IM 权威库或协议中。
public protocol V2MediaObjectProvider: Sendable {
    /// 为指定媒体签发下载目标。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - expiresAt: 目标到期时刻。
    /// - Returns: 提供方对象目标。
    /// - Throws: 提供方失败时抛出。
    func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) async throws -> V2MediaProviderObjectTarget
}

/// 已认领的下载会话。
public struct V2ClaimedMediaDownload: Equatable, Sendable {
    /// 目标媒体标识。
    public let mediaID: MediaID
    /// 下载会话标识。
    public let downloadSessionID: MediaDownloadSessionID
    /// 会话到期时刻。
    public let expiresAt: Date
    /// 本次认领令牌。
    public let claimToken: UUID

    /// 保存已认领的下载会话。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - downloadSessionID: 下载会话标识。
    ///   - expiresAt: 会话到期时刻。
    ///   - claimToken: 本次认领令牌。
    public init(mediaID: MediaID, downloadSessionID: MediaDownloadSessionID, expiresAt: Date, claimToken: UUID) {
        self.mediaID = mediaID
        self.downloadSessionID = downloadSessionID
        self.expiresAt = expiresAt
        self.claimToken = claimToken
    }
}

/// 下载会话的持久化能力。
public protocol V2MediaDownloadSessionStore: Sendable {
    /// 认领下载会话。
    ///
    /// 认领必须重新评估认证与内容授权：短时的 IM 授权本身不是绕过吊销的依据。
    ///
    /// - Parameters:
    ///   - requesterUserID: 请求下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - downloadSessionID: 下载会话标识。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    /// - Returns: 已认领的下载会话。
    /// - Throws: 会话不可认领或持久化失败时抛出。
    func claimDownload(
        requesterUserID: UserID,
        deviceID: DeviceID,
        downloadSessionID: MediaDownloadSessionID,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> V2ClaimedMediaDownload
    /// 重新校验授权并消费这一个未过期租约。
    ///
    /// 认领缺失、已过期、已被替换或不再授权时都必须抛出。
    ///
    /// - Parameters:
    ///   - claim: 已认领的下载会话。
    ///   - now: 完成时刻。
    /// - Throws: 会话不满足条件或持久化失败时抛出。
    func completeDownload(_ claim: V2ClaimedMediaDownload, now: Date) async throws

    /// 释放已认领但未消费的下载会话。
    ///
    /// - Parameter claim: 已认领的下载会话。
    /// - Throws: 持久化失败时抛出。
    func releaseDownload(_ claim: V2ClaimedMediaDownload) async throws
}

/// 把一次不透明会话兑换为一次提供方对象目标。
///
/// 服务不创建游离任务，也不会在提供方签发地址期间持有数据库事务。
public struct V2MediaProviderSessionService: Sendable {
    private let store: any V2MediaDownloadSessionStore
    private let provider: any V2MediaObjectProvider
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date

    /// 组合下载会话存储与提供方。
    ///
    /// - Parameters:
    ///   - store: 下载会话的持久化存储。
    ///   - provider: 签发下载目标的提供方。
    ///   - leaseDuration: 认领租约时长秒数，需为正的有限值，默认 15 秒。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 租约时长非正或非有限时抛出
    ///   ``V2MediaProviderSessionError/invalidLeaseDuration``。
    public init(
        store: any V2MediaDownloadSessionStore,
        provider: any V2MediaObjectProvider,
        leaseDuration: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard leaseDuration.isFinite, leaseDuration > 0 else { throw V2MediaProviderSessionError.invalidLeaseDuration }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.now = now
    }

    /// 认领下载会话并兑换提供方下载目标。
    ///
    /// 提供方返回值必须全部通过契约校验才会被消费：到期时间需晚于当前时刻且不晚于会话到期、
    /// 地址必须是带主机的 HTTPS 且不含用户信息与片段、期望字节数非负、
    /// 响应头需满足允许策略。任一步骤失败都会释放本次认领。
    ///
    /// - Parameters:
    ///   - actorUserID: 请求下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - downloadSessionID: 下载会话标识。
    /// - Returns: 提供方对象目标。
    /// - Throws: 时刻不可编码时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``；
    ///   会话或目标已过期时抛出 ``V2MediaProviderSessionError/expiredSession``；
    ///   提供方返回值不满足契约时抛出
    ///   ``V2MediaProviderSessionError/invalidProviderTarget``。
    public func exchangeDownload(
        actorUserID: UserID,
        deviceID: DeviceID,
        downloadSessionID: MediaDownloadSessionID
    ) async throws -> V2MediaProviderObjectTarget {
        try Task.checkCancellation()
        let instant = now()
        guard v2PostgresTimestampCanEncode(instant) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let claim = try await store.claimDownload(
            requesterUserID: actorUserID,
            deviceID: deviceID,
            downloadSessionID: downloadSessionID,
            now: instant,
            leaseDuration: leaseDuration
        )
        do {
            try Task.checkCancellation()
            let claimedAt = now()
            guard v2PostgresTimestampCanEncode(claimedAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard claim.expiresAt > claimedAt else { throw V2MediaProviderSessionError.expiredSession }
            let target = try await provider.issueDownloadTarget(mediaID: claim.mediaID, expiresAt: claim.expiresAt)
            try Task.checkCancellation()
            let completionTime = now()
            guard v2PostgresTimestampCanEncode(completionTime) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard target.expiresAt > completionTime,
                  target.expiresAt <= claim.expiresAt,
                  target.url.scheme?.lowercased() == "https",
                  target.url.host != nil,
                  target.url.user == nil,
                  target.url.password == nil,
                  target.url.fragment == nil,
                  target.expectedByteCount.map({ $0 >= 0 }) ?? true,
                  target.headers.allSatisfy({ name, value in
                      V2MediaProviderTargetHeaderPolicy.isAllowed(name: name, value: value)
                  })
            else {
                throw V2MediaProviderSessionError.invalidProviderTarget
            }
            try await store.completeDownload(claim, now: completionTime)
            try Task.checkCancellation()
            let returnedAt = now()
            guard v2PostgresTimestampCanEncode(returnedAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard target.expiresAt > returnedAt else { throw V2MediaProviderSessionError.expiredSession }
            return target
        } catch {
            try? await store.releaseDownload(claim)
            throw error
        }
    }
}

/// 提供方目标响应头的允许策略。
enum V2MediaProviderTargetHeaderPolicy {
    /// 判断单个响应头是否允许返回给客户端。
    ///
    /// 只允许内容类型、内容校验与各云厂商的 `x-amz-`、`x-oss-`、`x-goog-` 前缀头；
    /// 名称与取值都不得包含控制字符，长度分别不超过 128 与 8192 字节。
    ///
    /// - Parameters:
    ///   - name: 响应头名称。
    ///   - value: 响应头取值。
    /// - Returns: 允许透传时为 `true`。
    static func isAllowed(name: String, value: String) -> Bool {
        let canonical = name.lowercased()
        let allowedName = canonical == "content-type"
            || canonical == "content-md5"
            || canonical == "digest"
            || canonical.hasPrefix("x-amz-")
            || canonical.hasPrefix("x-oss-")
            || canonical.hasPrefix("x-goog-")
        return allowedName
            && !name.isEmpty
            && name.utf8.count <= 128
            && value.utf8.count <= 8_192
            && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

/// 媒体提供方会话错误。
public enum V2MediaProviderSessionError: Error, Equatable, Sendable {
    /// 租约时长非正或非有限。
    case invalidLeaseDuration
    /// 下载会话或提供方目标已过期。
    case expiredSession
    /// 提供方返回值不满足目标契约。
    case invalidProviderTarget
}
