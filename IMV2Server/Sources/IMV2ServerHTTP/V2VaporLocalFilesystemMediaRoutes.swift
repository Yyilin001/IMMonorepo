import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import Vapor
import HTTPTypes
import _NIOFileSystem

/// 本地文件系统媒体边缘接口（开发/测试用途）。
/// 目标路径由签名能力派生，本适配器不接受裸文件路径、原始存储 key 或长期凭证。
/// 生产环境建议改为对象存储原生边缘实现。
public struct V2VaporLocalFilesystemMediaRoutes<Provider: V2LocalMediaByteServing>: Sendable {
    private let provider: Provider
    private let publicBaseURL: URL
    private let maximumUploadBytes: Int

    public init(
        provider: Provider,
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
            let upload: Provider.StagedUpload
            do {
                upload = try await provider.beginUploadedObject(
                    mediaID: mediaID,
                    targetURL: targetURL,
                    contentType: contentType,
                    declaredByteCount: contentLength
                )
            } catch is V2LocalFilesystemMediaProviderError {
                // 已签名目标是一项不透明能力；不要透露拒绝原因或对象是否存在。
                throw Abort(.forbidden)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            do {
                let byteCounter = V2StreamingUploadByteCounter(maximumBytes: Int(contentLength))
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
            let object: Provider.DownloadedObject
            do {
                object = try await provider.downloadedObject(mediaID: mediaID, targetURL: targetURL)
            } catch is V2LocalFilesystemMediaProviderError {
                // 在公开的对象字节访问边界，不要区分过期、能力格式错误和对象不存在。
                throw Abort(.notFound)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            guard object.byteCount >= 0, object.byteCount <= Int64(Int.max) else { throw Abort(.serviceUnavailable) }
            let eTag: String
            do { eTag = try await object.strongETag() }
            catch is CancellationError { throw CancellationError() }
            catch { throw Abort(.notFound) }
            var headers = noStoreHeaders()
            headers[.contentType] = "application/octet-stream"
            headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
            headers[.eTag] = eTag
            headers[.acceptRanges] = "bytes"
            let range: ResourceResponseRange
            if let validator = request.headers[.ifRange], validator != eTag {
                range = .full
            } else {
                range = resourceResponseRange(request.headers[.range], byteCount: object.byteCount)
            }
            let start: Int64, end: Int64, status: HTTPResponse.Status
            switch range {
            case .unsatisfiable:
                headers[.contentRange] = "bytes */\(object.byteCount)"
                return .init(status: .rangeNotSatisfiable, headers: headers)
            case .full:
                start = 0; end = object.byteCount; status = .ok
            case .selected(let lower, let upper):
                start = lower; end = upper; status = .partialContent
                headers[.contentRange] = "bytes \(lower)-\(upper - 1)/\(object.byteCount)"
            }
            return try .init(status: status, headers: headers, body: .init(stream: { writer in
                var offset = start
                while offset < end {
                    try Task.checkCancellation()
                    let limit = Int(min(65_536, end - offset))
                    let bytes = try await object.readChunk(offset: offset, maximumBytes: limit)
                    guard !bytes.isEmpty, bytes.count <= limit else {
                        throw V2LocalFilesystemMediaProviderError.objectUnavailable
                    }
                    try await writer.write(bytes)
                    offset += Int64(bytes.count)
                }
            }, count: Int(end - start)))
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
