import Foundation
import IMV2Core

/// Authorized server-local files used only by the byte transport adapter.
/// File paths must never be serialized into a client response.
public protocol V2StagedMediaFile: Sendable {
    var fileURL: URL { get }
}

public protocol V2DownloadedMediaFile: Sendable {
    var fileURL: URL { get }
    var byteCount: Int64 { get }
    func strongETag() async throws -> String
}

/// A staged upload can only be committed or discarded through its provider's
/// matching associated type. Implementations recheck the signed capability at commit.
public protocol V2LocalMediaByteServing: Sendable {
    associatedtype StagedUpload: V2StagedMediaFile
    associatedtype DownloadedObject: V2DownloadedMediaFile
    func beginUploadedObject(mediaID: MediaID, targetURL: URL, contentType: String,
                             declaredByteCount: Int64) async throws -> StagedUpload
    func commitUploadedObject(_ upload: StagedUpload, actualByteCount: Int64) async throws
    func discardUploadedObject(_ upload: StagedUpload) async
    func downloadedObject(mediaID: MediaID, targetURL: URL) async throws -> DownloadedObject
}

public enum V2LocalFilesystemMediaProviderError: Error, Equatable, Sendable {
    /// 提供方配置不合法。
    case invalidConfiguration
    /// 媒体标识不合法。
    case invalidMediaID
    /// 访问目标签名或格式不合法。
    case invalidTarget
    /// 实际字节数与声明不符。
    case byteCountMismatch
    /// 目标对象不存在或不可读。
    case objectUnavailable
}
