import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes
import _NIOFileSystem

/// 本地文件系统媒体边缘接口（开发/测试用途）。
/// 目标路径由签名能力派生，本适配器不接受裸文件路径、原始存储 key 或长期凭证。
/// 生产环境建议改为对象存储原生边缘实现。
public struct V2VaporLocalFilesystemMediaRoutes: Sendable {
    private let provider: V2LocalFilesystemMediaProvider
    private let fileIO: FileIO
    private let publicBaseURL: URL
    private let maximumUploadBytes: Int

    public init(
        provider: V2LocalFilesystemMediaProvider,
        fileIO: FileIO,
        publicBaseURL: URL,
        maximumUploadBytes: Int64
    ) throws {
        guard publicBaseURL.scheme?.lowercased() == "https",
              publicBaseURL.host != nil,
              publicBaseURL.query == nil,
              publicBaseURL.fragment == nil,
              maximumUploadBytes > 0,
              maximumUploadBytes <= Int64(Int.max)
        else { throw V2VaporLocalFilesystemMediaRoutesError.invalidConfiguration }
        self.provider = provider
        self.fileIO = fileIO
        self.publicBaseURL = publicBaseURL
        self.maximumUploadBytes = Int(maximumUploadBytes)
    }

    /// 挂载短期签名资源相关接口：
    /// - `PUT /v2/local-media/upload/{mediaID}`：开始并提交对象上传。
    /// - `GET /v2/local-media/download/{mediaID}`：下载对象。
    public func register(on routes: RoutesBuilder) {
        routes.on(
            .put,
            "v2", "local-media", "upload", ":mediaID",
            maxBodySize: ByteCount(value: maximumUploadBytes)
        ) { request async throws -> Response in
            guard let rawMediaID = request.parameters.get("mediaID"),
                  let mediaID = try? MediaID(rawMediaID),
                  let targetURL = targetURL(for: request),
                  let contentType = request.headers[.contentType],
                  let rawContentLength = request.headers[.contentLength],
                  let contentLength = Int64(rawContentLength),
                  contentLength >= 0
            else { throw Abort(.forbidden) }
            guard contentLength <= Int64(maximumUploadBytes) else {
                throw Abort(.contentTooLarge)
            }
            let upload: V2LocalFilesystemStagedUpload
            do {
                upload = try await provider.beginUploadedObject(
                    mediaID: mediaID,
                    targetURL: targetURL,
                    contentType: contentType,
                    declaredByteCount: contentLength
                )
            } catch is V2LocalFilesystemMediaProviderError {
                // A signed target is an opaque capability; do not reveal why
                // one was rejected or whether its object exists.
                throw Abort(.forbidden)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            do {
                let byteCounter = V2StreamingUploadByteCounter(maximumBytes: maximumUploadBytes)
                let written = try await FileSystem.shared.withFileHandle(
                    forWritingAt: .init(upload.fileURL.path),
                    options: .newFile(replaceExisting: false)
                ) { handle in
                    var writer = handle.bufferedWriter()
                    var written: Int64 = 0
                    try await request.body.forEachChunk { chunk in
                        try Task.checkCancellation()
                        try byteCounter.consume(chunk.count)
                        let bytes = chunk.withUnsafeBytes { Array($0) }
                        written += try await writer.write(contentsOf: bytes)
                    }
                    try Task.checkCancellation()
                    try await writer.flush()
                    return written
                }
                guard written == contentLength else {
                    throw V2LocalFilesystemMediaProviderError.byteCountMismatch
                }
                try Task.checkCancellation()
                try await provider.commitUploadedObject(upload, actualByteCount: written)
            } catch let abort as AbortError {
                await provider.discardUploadedObject(upload)
                throw abort
            } catch is V2LocalFilesystemMediaProviderError {
                await provider.discardUploadedObject(upload)
                throw Abort(.forbidden)
            } catch {
                await provider.discardUploadedObject(upload)
                throw Abort(.serviceUnavailable)
            }
            return noStoreResponse(status: .noContent)
        }

        routes.get("v2", "local-media", "download", ":mediaID") { request async throws -> Response in
            guard let rawMediaID = request.parameters.get("mediaID"),
                  let mediaID = try? MediaID(rawMediaID),
                  let targetURL = targetURL(for: request)
            else { throw Abort(.notFound) }
            let object: V2LocalFilesystemDownloadedObject
            do {
                object = try await provider.downloadedObject(mediaID: mediaID, targetURL: targetURL)
            } catch is V2LocalFilesystemMediaProviderError {
                // Do not distinguish expiration, a malformed capability, and
                // an absent object from the public object-byte boundary.
                throw Abort(.notFound)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            guard object.byteCount <= Int64(Int.max) else { throw Abort(.serviceUnavailable) }
            var response = try await fileIO.streamFile(
                at: object.fileURL.path,
                for: request,
                mediaType: .init(type: "application", subType: "octet-stream")
            )
            for header in noStoreHeaders() {
                response.headers[header.name] = header.value
            }
            response.headers[.contentType] = "application/octet-stream"
            return response
        }
    }

    private func targetURL(for request: Request) -> URL? {
        guard var components = URLComponents(url: publicBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = request.url.path
        components.percentEncodedQuery = request.url.query
        return components.url
    }

    private func noStoreResponse(status: HTTPResponse.Status) -> Response {
        .init(status: status, headers: noStoreHeaders())
    }

    private func noStoreHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return headers
    }
}

public enum V2VaporLocalFilesystemMediaRoutesError: Error, Equatable, Sendable {
    case invalidConfiguration
}

final class V2StreamingUploadByteCounter: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var consumedBytes = 0

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func consume(_ count: Int) throws {
        let accepted = lock.withLock { () -> Bool in
            guard count >= 0, consumedBytes <= maximumBytes - count else { return false }
            consumedBytes += count
            return true
        }
        guard accepted else { throw Abort(.contentTooLarge) }
    }
}
