import Foundation
import IMV2Core

/// 已认证媒体边缘的上传用例。
///
/// 它先创建持久化上传意图，再仅用其中的不透明会话兑换内存中的提供方目标；
/// 媒体状态的实际跃迁留给显式的完成回调处理。
public struct V2MediaEdgeUploadService: Sendable {
    private let media: V2MediaService
    private let providerSessions: V2MediaUploadProviderSessionService

    /// 组合媒体服务与上传提供方会话服务。
    ///
    /// - Parameters:
    ///   - media: 负责媒体状态与上传意图的服务。
    ///   - providerSessions: 负责把上传会话兑换为提供方目标的服务。
    public init(media: V2MediaService, providerSessions: V2MediaUploadProviderSessionService) {
        self.media = media
        self.providerSessions = providerSessions
    }

    /// 为已认证设备创建上传意图并兑换内存中的提供方目标。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起上传的用户。
    ///   - deviceID: 发起上传的设备。
    ///   - operationID: 上传操作幂等标识。
    ///   - mediaID: 本次上传的媒体标识。
    ///   - contentType: 媒体内容类型。
    ///   - byteCount: 期望上传的字节数。
    /// - Returns: 仅在本进程内使用的提供方对象目标。
    /// - Throws: 设备不匹配、意图冲突或提供方会话交换失败时抛出。
    public func uploadTarget(
        actorUserID: UserID,
        deviceID: DeviceID,
        operationID: MediaUploadOperationID,
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64
    ) async throws -> V2MediaProviderObjectTarget {
        let grant = try await media.requestUpload(
            actorUserID: actorUserID,
            deviceID: deviceID,
            operationID: operationID,
            mediaID: mediaID,
            contentType: contentType,
            byteCount: byteCount
        )
        return try await providerSessions.exchangeUpload(
            actorUserID: actorUserID,
            deviceID: deviceID,
            uploadSessionID: grant.uploadSessionID
        )
    }

    /// 标记媒体上传完成，交由媒体服务推进状态。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起上传的用户。
    ///   - deviceID: 发起上传的设备。
    ///   - mediaID: 已完成上传的媒体标识。
    /// - Throws: 设备不匹配、状态不允许推进或持久化失败时抛出。
    public func uploadCompleted(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws {
        try await media.uploadCompleted(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID)
    }

    /// 查询媒体对象当前状态。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起查询的用户。
    ///   - deviceID: 发起查询的设备。
    ///   - mediaID: 目标媒体标识。
    /// - Returns: 媒体对象当前状态。
    /// - Throws: 设备不匹配或持久化失败时抛出。
    public func uploadStatus(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws -> V2MediaObjectState {
        try await media.uploadStatus(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID)
    }
}
