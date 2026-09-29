import IMV2ServerContracts
import Foundation
import IMV2Core

/// 消息下载授权的持久化边界。上传、扫描和引用绑定分别由资源生命周期、
/// 扫描 worker 和房间写事务负责，不通过下载服务暴露状态写入。
public protocol V2MediaStore: Sendable {
    /// 创建或重放一次下载会话。
    ///
    /// - Parameters:
    ///   - requesterUserID: 请求下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - mediaID: 目标媒体标识。
    ///   - expiresAt: 会话到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 下载授权。
    /// - Throws: 无可见性、设备不匹配或持久化失败时抛出。
    func requestDownload(requesterUserID: UserID, deviceID: DeviceID, mediaID: MediaID, expiresAt: Date, now: Date) async throws -> V2MediaDownloadGrant

}

/// 创建短期下载 grant；不持有上传或扫描状态变更能力。
public struct V2MediaService: Sendable {
    private let store: any V2MediaStore
    private let downloadLimits: V2MediaDownloadLimits
    private let now: @Sendable () -> Date

    public init(store: any V2MediaStore, downloadLimits: V2MediaDownloadLimits = .standard,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.downloadLimits = downloadLimits
        self.now = now
    }

    /// 申请下载会话。
    ///
    /// 网关必须从认证结果推导用户与设备标识。本层只登记短时的不透明会话，
    /// 只有媒体边缘可以把它兑换为提供方专用的单对象目标。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - mediaID: 目标媒体标识。
    /// - Returns: 下载授权。
    /// - Throws: 会话到期时刻不可编码时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；返回的媒体标识不符或授权已过期时抛出
    ///   ``V2MediaServiceError/invalidGrant``；其余错误来自存储实现。
    public func requestDownload(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws -> V2MediaDownloadGrant {
        let instant = now()
        guard let expiry = v2PostgresFutureTimestamp(now: instant, interval: downloadLimits.grantLifetime) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let grant = try await store.requestDownload(
            requesterUserID: actorUserID,
            deviceID: deviceID,
            mediaID: mediaID,
            expiresAt: expiry,
            now: instant
        )
        guard grant.mediaID == mediaID, v2PostgresTimestampPrecedes(now(), grant.expiresAt) else {
            throw V2MediaServiceError.invalidGrant
        }
        return grant
    }

}

public enum V2MediaServiceError: Error, Equatable, Sendable { case invalidGrant }
