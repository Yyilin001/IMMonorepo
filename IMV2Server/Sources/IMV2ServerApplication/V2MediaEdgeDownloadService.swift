import IMV2ServerContracts
import Foundation
import IMV2Core

/// 需认证的媒体边缘下载用例。
///
/// 薄 HTTP 处理层只负责解码设备身份与媒体标识，然后调用本服务；
/// 它不得自行实现成员关系、消息撤回或提供方会话策略。
public protocol V2MediaDownloadTargetResolving: Sendable {
    /// 为单个已认证设备解析可用的提供方对象目标。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - mediaID: 目标媒体标识。
    ///   - message: 媒体所属消息位置；边界实现当前仅支持为空。
    /// - Returns: 仅在本进程内使用的提供方对象目标。
    /// - Throws: 设备不匹配、无可见性、媒体不可用或提供方交换失败时抛出。
    func downloadTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ResourceTransferPlan
    func imagePreviewTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID, message: V2MediaMessageLocation, size: V2MediaImagePreviewSize) async throws -> V2MediaDownloadTargetEnvelope

}

public extension V2MediaDownloadTargetResolving {
    func imagePreviewTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID, message: V2MediaMessageLocation, size: V2MediaImagePreviewSize) async throws -> V2MediaDownloadTargetEnvelope {
        throw V2MediaStoreError.downloadNotAuthorized
    }
}

/// Only called after the same message visibility checks used for originals.
public protocol V2MediaImagePreviewProviding: Sendable {
    func issueImagePreviewTarget(mediaID: MediaID, roomID: RoomID, size: V2MediaImagePreviewSize, expiresAt: Date) async throws -> V2MediaDownloadTargetEnvelope
}

/// 媒体边缘下载的标准实现，串联媒体授权与提供方会话交换。
public struct V2MediaEdgeDownloadService: V2MediaDownloadTargetResolving {
    private let media: V2MediaService
    private let providerSessions: V2MediaProviderSessionService

    /// 组合媒体服务与提供方会话服务。
    ///
    /// - Parameters:
    ///   - media: 负责媒体状态与可见性判断的服务。
    ///   - providerSessions: 负责把下载会话兑换为提供方目标的服务。
    public init(media: V2MediaService, providerSessions: V2MediaProviderSessionService) {
        self.media = media
        self.providerSessions = providerSessions
    }

    /// 为某一个已认证设备生成内存中的提供方目标。
    ///
    /// 不透明授权凭据只在本用例内部流转，不会返回给聊天客户端，也不写入事件日志或持久化记录。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起下载的用户。
    ///   - deviceID: 发起下载的设备。
    ///   - mediaID: 目标媒体标识。
    ///   - message: 媒体所属消息位置；当前非空即拒绝。
    /// - Returns: 仅在本进程内使用的提供方对象目标。
    /// - Throws: `message` 非空时抛出 ``V2MediaEdgeHTTPHandlerError/messageOwnerUnavailable``；
    ///   其余错误来自媒体授权或提供方会话兑换。
    public func downloadTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID, message: V2MediaMessageLocation? = nil) async throws -> V2ResourceTransferPlan {
        guard message == nil else { throw V2MediaEdgeHTTPHandlerError.messageOwnerUnavailable }
        let grant = try await media.requestDownload(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID)
        return try await providerSessions.exchangeDownload(
            actorUserID: actorUserID,
            deviceID: deviceID,
            downloadSessionID: grant.downloadSessionID
        )
    }
}
