import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// `GET /v2/media/{mediaID}` 的框架无关 HTTP 传输适配器。
///
/// Vapor 路由只负责取出已认证的用户与设备，并把本类型的返回值或错误映射为 HTTP 响应。
/// 本处理器刻意不负责 Bearer 令牌解析，也不持有提供方配置。
public struct V2MediaEdgeHTTPHandler: Sendable {
    private let edge: any V2MediaDownloadTargetResolving

    /// 使用标准媒体边缘下载服务构造处理器。
    ///
    /// - Parameter edge: 串联媒体授权与提供方会话兑换的标准实现。
    public init(edge: V2MediaEdgeDownloadService) {
        self.edge = edge
    }

    /// 注入自定义下载目标解析实现构造处理器。
    ///
    /// - Parameter resolver: 下载目标解析实现，测试可注入替身。
    public init(resolver: any V2MediaDownloadTargetResolving) { edge = resolver }

    /// 解析一次媒体下载请求并生成稳定的响应信封。
    ///
    /// 原始房间与消息标识必须同时给出或同时省略：同时给出时会解析为媒体消息位置，
    /// 只给其中一个即视为位置非法。
    ///
    /// - Parameters:
    ///   - actorUserID: 已认证的用户。
    ///   - deviceID: 已认证的设备。
    ///   - rawMediaID: 原始媒体标识，不超过 128 字节。
    ///   - rawRoomID: 原始房间标识，可与 `rawMessageID` 一同给出。
    ///   - rawMessageID: 原始消息标识，可与 `rawRoomID` 一同给出。
    /// - Returns: 面向 HTTP 的下载目标信封。
    /// - Throws: 媒体标识过长或无法解析时抛出
    ///   ``V2MediaEdgeHTTPHandlerError/invalidMediaID``；房间与消息标识仅给出其一、
    ///   超出长度或无法解析为 UUID 时抛出
    ///   ``V2MediaEdgeHTTPHandlerError/invalidMessageLocation``；提供方返回值未通过稳定契约
    ///   校验时抛出 ``V2MediaEdgeHTTPHandlerError/invalidProviderTarget``。
    public func downloadTarget(
        actorUserID: UserID,
        deviceID: DeviceID,
        rawMediaID: String,
        rawRoomID: String? = nil,
        rawMessageID: String? = nil,
        rawImageSize: String? = nil
    ) async throws -> V2MediaDownloadTargetEnvelope {
        guard rawMediaID.utf8.count <= 128 else { throw V2MediaEdgeHTTPHandlerError.invalidMediaID }
        let mediaID: MediaID
        do {
            mediaID = try MediaID(rawMediaID)
        } catch {
            throw V2MediaEdgeHTTPHandlerError.invalidMediaID
        }
        let message: V2MediaMessageLocation?
        switch (rawRoomID, rawMessageID) {
        case (nil, nil): message = nil
        case (.some(let room), .some(let identifier)):
            guard room.utf8.count <= 128, identifier.utf8.count <= 128,
                  let roomUUID = UUID(uuidString: room), let messageUUID = UUID(uuidString: identifier)
            else { throw V2MediaEdgeHTTPHandlerError.invalidMessageLocation }
            message = .init(roomID: .init(uuid: roomUUID), messageID: .init(uuid: messageUUID))
        default: throw V2MediaEdgeHTTPHandlerError.invalidMessageLocation
        }
        if let rawImageSize {
            guard let raw = Int(rawImageSize), let size = V2MediaImagePreviewSize(rawValue: raw), let message
            else { throw V2MediaEdgeHTTPHandlerError.invalidMessageLocation }
            return try await edge.imagePreviewTarget(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID, message: message, size: size)
        }
        let target = try await edge.downloadTarget(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID, message: message)
        do {
            return try .init(plan: target)
        } catch {
            // 服务商返回值若未通过稳定契约校验，绝不能进入 HTTP 响应。
            throw V2MediaEdgeHTTPHandlerError.invalidProviderTarget
        }
    }
}
