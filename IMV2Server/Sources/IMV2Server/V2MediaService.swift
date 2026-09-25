import Foundation
import IMV2Core

/// 由已认证上传/下载服务持有的持久化边界。
///
/// 实现可以把会话交给 S3、CDN 或其他对象系统，但该 IM 领域 API 不会返回任何对象地址。
public protocol V2MediaStore: Sendable {
    /// 创建或重放一次上传意图。
    ///
    /// - Parameters:
    ///   - command: 上传请求命令。
    ///   - deviceID: 发起上传的设备。
    ///   - expiresAt: 会话到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 上传授权。
    /// - Throws: 设备不匹配、意图冲突或持久化失败时抛出。
    func requestUpload(_ command: V2RequestMediaUploadCommand, deviceID: DeviceID, expiresAt: Date, now: Date) async throws -> V2MediaUploadGrant

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

    /// 标记上传完成并推进媒体状态。
    ///
    /// - Parameters:
    ///   - ownerUserID: 媒体归属用户。
    ///   - deviceID: 发起上传的设备。
    ///   - mediaID: 目标媒体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 设备不匹配、状态不允许推进或持久化失败时抛出。
    func markUploadCompleted(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now: Date) async throws

    /// 读取媒体对象当前状态。
    ///
    /// - Parameters:
    ///   - ownerUserID: 媒体归属用户。
    ///   - deviceID: 发起查询的设备。
    ///   - mediaID: 目标媒体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 媒体对象状态。
    /// - Throws: 设备不匹配或持久化失败时抛出。
    func uploadStatus(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now: Date) async throws -> V2MediaObjectState

    /// 记录扫描结果。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - passed: 扫描是否通过。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 状态不允许记录或持久化失败时抛出。
    func recordScanResult(mediaID: MediaID, passed: Bool, now: Date) async throws

    /// 断言媒体可用于被消息引用。
    ///
    /// - Parameters:
    ///   - ownerUserID: 媒体归属用户。
    ///   - mediaIDs: 待引用的媒体标识列表。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 任一媒体不可用或持久化失败时抛出。
    func assertAvailableForReference(ownerUserID: UserID, mediaIDs: [MediaID], now: Date) async throws
}

/// 媒体服务。
///
/// 扫描回调与用户命令刻意分离：能上传的调用方无法自行决定扫描结果。
public struct V2MediaService: Sendable {
    private let store: any V2MediaStore
    private let limits: V2MediaUploadLimits
    private let downloadLimits: V2MediaDownloadLimits
    private let now: @Sendable () -> Date

    /// 组合媒体存储与上传、下载限制。
    ///
    /// - Parameters:
    ///   - store: 实际执行持久化操作的存储实现。
    ///   - limits: 上传限制。
    ///   - downloadLimits: 下载限制，默认使用标准值。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2MediaStore, limits: V2MediaUploadLimits, downloadLimits: V2MediaDownloadLimits = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.limits = limits
        self.downloadLimits = downloadLimits
        self.now = now
    }

    /// 申请上传授权。
    ///
    /// 存储返回后会用当前时刻复核授权，因为存储需要先检查持久化重放再校验新的截止时间。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起上传的用户。
    ///   - deviceID: 发起上传的设备。
    ///   - operationID: 上传幂等操作标识。
    ///   - mediaID: 目标媒体标识。
    ///   - contentType: 媒体内容类型。
    ///   - byteCount: 期望字节数。
    /// - Returns: 上传授权。
    /// - Throws: 返回的媒体标识不符或授权已过期时抛出
    ///   ``V2MediaServiceError/invalidGrant``；其余错误来自存储实现。
    public func requestUpload(actorUserID: UserID, deviceID: DeviceID, operationID: MediaUploadOperationID, mediaID: MediaID, contentType: String, byteCount: Int64) async throws -> V2MediaUploadGrant {
        let instant = now()
        let command = try V2RequestMediaUploadCommand(actorUserID: actorUserID, operationID: operationID, mediaID: mediaID, contentType: contentType, byteCount: byteCount, limits: limits)
        let grant = try await store.requestUpload(command, deviceID: deviceID, expiresAt: instant.addingTimeInterval(limits.temporaryLifetime), now: instant)
        // 存储在检查持久重放后校验新截止时间。
        // 等待完成后，使用当时的时钟校验持久化结果。
        guard grant.mediaID == mediaID, v2PostgresTimestampPrecedes(now(), grant.expiresAt) else { throw V2MediaServiceError.invalidGrant }
        return grant
    }

    /// 标记上传完成。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起上传的用户。
    ///   - deviceID: 发起上传的设备。
    ///   - mediaID: 目标媒体标识。
    /// - Throws: 存储实现抛出的错误。
    public func uploadCompleted(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws {
        try await store.markUploadCompleted(ownerUserID: actorUserID, deviceID: deviceID, mediaID: mediaID, now: now())
    }

    /// 读取上传状态。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起查询的用户。
    ///   - deviceID: 发起查询的设备。
    ///   - mediaID: 目标媒体标识。
    /// - Returns: 媒体对象状态。
    /// - Throws: 存储实现抛出的错误。
    public func uploadStatus(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws -> V2MediaObjectState {
        try await store.uploadStatus(ownerUserID: actorUserID, deviceID: deviceID, mediaID: mediaID, now: now())
    }

    /// 记录扫描完成结果。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - passed: 扫描是否通过。
    /// - Throws: 存储实现抛出的错误。
    public func scannerCompleted(mediaID: MediaID, passed: Bool) async throws {
        try await store.recordScanResult(mediaID: mediaID, passed: passed, now: now())
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

    /// 断言媒体可用于被引用。
    ///
    /// 消息接受流程在提交房间事件或所需发件箱行之前，于其所属 SQL 事务内调用本方法。
    ///
    /// - Parameters:
    ///   - ownerUserID: 媒体归属用户。
    ///   - media: 待引用的媒体列表。
    /// - Throws: 存储实现抛出的错误。
    public func assertAvailableForReference(ownerUserID: UserID, media: [V2MediaReference]) async throws {
        try await store.assertAvailableForReference(ownerUserID: ownerUserID, mediaIDs: media.map(\.mediaID), now: now())
    }
}

/// 媒体服务错误。
public enum V2MediaServiceError: Error, Equatable, Sendable { case invalidGrant }
