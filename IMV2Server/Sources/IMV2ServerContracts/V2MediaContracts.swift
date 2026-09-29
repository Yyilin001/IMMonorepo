import Foundation
import IMV2Core

/// 媒体存储错误。
public enum V2MediaStoreError: Error, Equatable, Sendable {
    /// 同一幂等操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 媒体不存在、不可用或不属于调用方。
    case mediaUnavailable
    /// 媒体或其授权已过期。
    case mediaExpired
    /// 当前状态不允许请求的状态跃迁。
    case invalidStateTransition
    /// 待引用媒体集合为空、重复或归属不符。
    case invalidReferenceSet
    /// 请求者不具备下载该媒体的可见性。
    case downloadNotAuthorized
    /// 设备不具备上传资格。
    case uploadNotAuthorized
}

/// 媒体扫描结论。
public enum V2MediaScanResult: Equatable, Sendable {
    /// 扫描通过。
    case passed
    /// 扫描不通过。
    case failed
}


/// 媒体边缘 HTTP 处理错误。
public enum V2MediaEdgeHTTPHandlerError: Error, Equatable, Sendable {
    /// 媒体标识过长或格式非法。
    case invalidMediaID
    /// 提供方返回值不满足响应契约。
    case invalidProviderTarget
    /// 房间与消息标识不成对或无法解析。
    case invalidMessageLocation
    /// 消息归属未经授权，当前不允许按消息定位媒体。
    case messageOwnerUnavailable
}
