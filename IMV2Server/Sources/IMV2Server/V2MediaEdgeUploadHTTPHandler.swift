import Foundation
import IMV2Core

/// 框架无关的上传传输适配器。
///
/// 它只校验传输层标识；设备认证与上传状态策略位于其下的边缘、服务与存储层。
public struct V2MediaEdgeUploadHTTPHandler: Sendable {
    private let edge: V2MediaEdgeUploadService

    /// 组合媒体边缘上传服务。
    ///
    /// - Parameter edge: 执行上传意图与提供方兑换的服务实现。
    public init(edge: V2MediaEdgeUploadService) { self.edge = edge }

    /// 解析上传请求并生成稳定的上传目标信封。
    ///
    /// - Parameters:
    ///   - actorUserID: 已认证的用户。
    ///   - deviceID: 已认证的设备。
    ///   - rawOperationID: 原始上传操作标识，不超过 128 字节。
    ///   - rawMediaID: 原始媒体标识，不超过 128 字节。
    ///   - contentType: 媒体内容类型。
    ///   - byteCount: 期望上传字节数。
    /// - Returns: 面向 HTTP 的上传目标信封。
    /// - Throws: 标识过长或无法解析时抛出
    ///   ``V2MediaEdgeUploadHTTPHandlerError/invalidIdentifier``；提供方返回值未通过契约校验时抛出
    ///   ``V2MediaEdgeUploadHTTPHandlerError/invalidProviderTarget``。
    public func uploadTarget(
        actorUserID: UserID,
        deviceID: DeviceID,
        rawOperationID: String,
        rawMediaID: String,
        contentType: String,
        byteCount: Int64
    ) async throws -> V2MediaUploadTargetEnvelope {
        guard rawOperationID.utf8.count <= 128, rawMediaID.utf8.count <= 128 else {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier
        }
        let operationID: MediaUploadOperationID
        let mediaID: MediaID
        do {
            operationID = try .init(rawOperationID)
            mediaID = try .init(rawMediaID)
        } catch {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier
        }
        let target = try await edge.uploadTarget(
            actorUserID: actorUserID,
            deviceID: deviceID,
            operationID: operationID,
            mediaID: mediaID,
            contentType: contentType,
            byteCount: byteCount
        )
        do {
            return try .init(
                url: target.url,
                headers: target.headers,
                expiresAt: target.expiresAt,
                expectedByteCount: target.expectedByteCount
            )
        } catch {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidProviderTarget
        }
    }

    /// 标记上传完成。
    ///
    /// - Parameters:
    ///   - actorUserID: 已认证的用户。
    ///   - deviceID: 已认证的设备。
    ///   - rawMediaID: 原始媒体标识。
    /// - Throws: 标识过长或无法解析时抛出
    ///   ``V2MediaEdgeUploadHTTPHandlerError/invalidIdentifier``；其余错误来自上传服务。
    public func uploadCompleted(actorUserID: UserID, deviceID: DeviceID, rawMediaID: String) async throws {
        guard rawMediaID.utf8.count <= 128, let mediaID = try? MediaID(rawMediaID) else {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier
        }
        try await edge.uploadCompleted(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID)
    }

    /// 查询上传状态信封。
    ///
    /// - Parameters:
    ///   - actorUserID: 已认证的用户。
    ///   - deviceID: 已认证的设备。
    ///   - rawMediaID: 原始媒体标识。
    /// - Returns: 面向 HTTP 的上传状态信封。
    /// - Throws: 标识过长或无法解析时抛出
    ///   ``V2MediaEdgeUploadHTTPHandlerError/invalidIdentifier``；其余错误来自上传服务。
    public func uploadStatus(actorUserID: UserID, deviceID: DeviceID, rawMediaID: String) async throws -> V2MediaUploadStatusEnvelope {
        guard rawMediaID.utf8.count <= 128, let mediaID = try? MediaID(rawMediaID) else {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier
        }
        return .init(state: try await edge.uploadStatus(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID))
    }
}

/// 媒体边缘上传 HTTP 处理错误。
public enum V2MediaEdgeUploadHTTPHandlerError: Error, Equatable, Sendable {
    /// 操作或媒体标识过长或格式非法。
    case invalidIdentifier
    /// 提供方返回值不满足响应契约。
    case invalidProviderTarget
}
