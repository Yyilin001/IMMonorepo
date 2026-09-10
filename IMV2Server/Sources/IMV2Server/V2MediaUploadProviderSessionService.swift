import Foundation
import IMV2Core

/// 提供方签发单个短时上传目标的能力。
///
/// 该能力与下载能力刻意分离，避免部署时误把写权限授予仅支持下载的适配器。
public protocol V2MediaUploadObjectProvider: Sendable {
    /// 为指定媒体签发上传目标。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - contentType: 媒体内容类型。
    ///   - byteCount: 期望上传字节数。
    ///   - expiresAt: 目标到期时刻。
    /// - Returns: 提供方对象目标。
    /// - Throws: 提供方失败时抛出。
    func issueUploadTarget(
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64,
        expiresAt: Date
    ) async throws -> V2MediaProviderObjectTarget
}

/// 已认领的上传会话。
public struct V2ClaimedMediaUpload: Equatable, Sendable {
    /// 目标媒体标识。
    public let mediaID: MediaID
    /// 上传会话标识。
    public let uploadSessionID: MediaUploadSessionID
    /// 媒体内容类型。
    public let contentType: String
    /// 期望上传字节数。
    public let byteCount: Int64
    /// 会话到期时刻。
    public let expiresAt: Date
    /// 本次认领令牌。
    public let claimToken: UUID

    /// 保存已认领的上传会话。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - uploadSessionID: 上传会话标识。
    ///   - contentType: 媒体内容类型。
    ///   - byteCount: 期望上传字节数。
    ///   - expiresAt: 会话到期时刻。
    ///   - claimToken: 本次认领令牌。
    public init(
        mediaID: MediaID,
        uploadSessionID: MediaUploadSessionID,
        contentType: String,
        byteCount: Int64,
        expiresAt: Date,
        claimToken: UUID
    ) {
        self.mediaID = mediaID
        self.uploadSessionID = uploadSessionID
        self.contentType = contentType
        self.byteCount = byteCount
        self.expiresAt = expiresAt
        self.claimToken = claimToken
    }
}

/// 上传会话的持久化能力。
///
/// 在签发提供方访问之前，存储会原子校验当前已认证设备、会话归属、
/// 媒体的 `pending_upload` 状态以及授权状态。
public protocol V2MediaUploadSessionStore: Sendable {
    /// 认领上传会话。
    ///
    /// - Parameters:
    ///   - ownerUserID: 会话归属用户。
    ///   - deviceID: 发起兑换的设备。
    ///   - uploadSessionID: 上传会话标识。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    /// - Returns: 已认领的上传会话。
    /// - Throws: 会话不可认领或持久化失败时抛出。
    func claimUpload(
        ownerUserID: UserID,
        deviceID: DeviceID,
        uploadSessionID: MediaUploadSessionID,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> V2ClaimedMediaUpload
    /// 将已认领会话标记为已消费。
    ///
    /// - Parameters:
    ///   - claim: 已认领的上传会话。
    ///   - now: 完成时刻。
    /// - Throws: 会话不可消费或持久化失败时抛出。
    func completeUploadTarget(_ claim: V2ClaimedMediaUpload, now: Date) async throws

    /// 释放已认领但未消费的会话。
    ///
    /// - Parameter claim: 已认领的上传会话。
    /// - Throws: 持久化失败时抛出。
    func releaseUploadTarget(_ claim: V2ClaimedMediaUpload) async throws
}

/// 把一次持久化的设备绑定上传会话兑换为内存中的提供方目标。
///
/// 完成回调保持独立：只有在该目标兑换被消费之后，它才可以推进媒体状态。
public struct V2MediaUploadProviderSessionService: Sendable {
    private let store: any V2MediaUploadSessionStore
    private let provider: any V2MediaUploadObjectProvider
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date

    /// 组合上传会话存储与提供方。
    ///
    /// - Parameters:
    ///   - store: 上传会话的持久化存储。
    ///   - provider: 签发上传目标的提供方。
    ///   - leaseDuration: 认领租约时长秒数，需为正的有限值，默认 15 秒。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 租约时长非正或非有限时抛出
    ///   ``V2MediaUploadProviderSessionError/invalidLeaseDuration``。
    public init(
        store: any V2MediaUploadSessionStore,
        provider: any V2MediaUploadObjectProvider,
        leaseDuration: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard leaseDuration.isFinite, leaseDuration > 0 else { throw V2MediaUploadProviderSessionError.invalidLeaseDuration }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.now = now
    }

    /// 认领上传会话并兑换提供方上传目标。
    ///
    /// 提供方返回值必须全部通过契约校验才会被消费：目标到期时间需晚于当前时刻且不晚于会话到期、
    /// 地址必须是带主机的 HTTPS 且不含用户信息与片段、期望字节数需与会话一致、
    /// 响应头需满足允许策略。任一步骤失败都会释放本次认领。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起兑换的用户。
    ///   - deviceID: 发起兑换的设备。
    ///   - uploadSessionID: 上传会话标识。
    /// - Returns: 提供方对象目标。
    /// - Throws: 时刻不可编码时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``；
    ///   会话已过期时抛出 ``V2MediaUploadProviderSessionError/expiredSession``；
    ///   提供方返回值不满足契约时抛出
    ///   ``V2MediaUploadProviderSessionError/invalidProviderTarget``。
    public func exchangeUpload(
        actorUserID: UserID,
        deviceID: DeviceID,
        uploadSessionID: MediaUploadSessionID
    ) async throws -> V2MediaProviderObjectTarget {
        try Task.checkCancellation()
        let instant = now()
        guard v2PostgresTimestampCanEncode(instant) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let claim = try await store.claimUpload(
            ownerUserID: actorUserID,
            deviceID: deviceID,
            uploadSessionID: uploadSessionID,
            now: instant,
            leaseDuration: leaseDuration
        )
        do {
            try Task.checkCancellation()
            let claimedAt = now()
            guard v2PostgresTimestampCanEncode(claimedAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard claim.expiresAt > claimedAt else { throw V2MediaUploadProviderSessionError.expiredSession }
            let target = try await provider.issueUploadTarget(
                mediaID: claim.mediaID,
                contentType: claim.contentType,
                byteCount: claim.byteCount,
                expiresAt: claim.expiresAt
            )
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
                  target.expectedByteCount == claim.byteCount,
                  target.headers.allSatisfy({ name, value in
                      V2MediaProviderTargetHeaderPolicy.isAllowed(name: name, value: value)
                  })
            else { throw V2MediaUploadProviderSessionError.invalidProviderTarget }
            try await store.completeUploadTarget(claim, now: completionTime)
            try Task.checkCancellation()
            let returnedAt = now()
            guard v2PostgresTimestampCanEncode(returnedAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard target.expiresAt > returnedAt else { throw V2MediaUploadProviderSessionError.expiredSession }
            return target
        } catch {
            try? await store.releaseUploadTarget(claim)
            throw error
        }
    }
}

/// 上传提供方会话错误。
public enum V2MediaUploadProviderSessionError: Error, Equatable, Sendable {
    /// 租约时长非正或非有限。
    case invalidLeaseDuration
    /// 上传会话或提供方目标已过期。
    case expiredSession
    /// 提供方返回值不满足目标契约。
    case invalidProviderTarget
}
