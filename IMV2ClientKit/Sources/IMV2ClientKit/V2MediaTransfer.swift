import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// 由已认证媒体边缘返回的临时提供方目标。
///
/// 它刻意既不支持 `Codable` 也不可持久化：
/// 一个已签名 URL 及其头部绝不能进入消息投影、发件箱、日志或备份。
public struct V2ClientMediaTransferTarget: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let expiresAt: Date
    public let expectedByteCount: Int64
    public let checksum: V2ResourceChecksum

    public init(downloadPlan:V2ResourceTransferPlan) throws {
        guard downloadPlan.mode == .httpGet, let checksum = downloadPlan.checksum else {throw V2ClientMediaTransferError.invalidTarget}
        self.url=downloadPlan.url
        self.headers=Dictionary(uniqueKeysWithValues:downloadPlan.headers.map {($0.name,$0.value)})
        self.expiresAt=downloadPlan.expiresAt
        self.expectedByteCount=downloadPlan.expectedByteCount
        self.checksum=checksum
    }
}

/// 已认证的媒体边缘边界。
///
/// 实现需要获取一个全新的不透明服务端会话，并用它换取目标；
/// 访问令牌必须留在该适配器内部，而不能被复制进提供方目标的请求头。
public protocol V2ClientMediaDownloadTargetResolver: Sendable {
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget
}

/// 用于已认证媒体边缘的、自洽且绑定设备的凭据对。
///
/// 访问令牌只能用于边缘请求，绝不能被复制到最终的对象提供方目标或任何持久化的客户端状态中。
public struct V2ClientMediaEdgeCredentials: Sendable {
    public let accessToken: String
    public let deviceID: DeviceID
    /// Local monotonic request budget; never encoded or persisted with credentials.
    public let requestDeadline: ContinuousClock.Instant?

    public init(accessToken: String, deviceID: DeviceID, requestDeadline: ContinuousClock.Instant? = nil) {
        self.accessToken = accessToken
        self.deviceID = deviceID; self.requestDeadline = requestDeadline
    }
}

public protocol V2ClientMediaEdgeCredentialProvider: Sendable {
    func mediaEdgeCredentials() async throws -> V2ClientMediaEdgeCredentials
}

/// 把 URLSession 与请求/响应校验隔离开，
/// 使解析器测试无需依赖全局 URLProtocol 注册或真实的边缘部署。
public protocol V2ClientMediaEdgeHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public actor V2URLSessionMediaEdgeHTTPTransport: V2ClientMediaEdgeHTTPTransport {
    private let executor: V2HTTPExecutor
    public init(session: URLSession = V2SecureURLSession.account) { executor = .init(session: session) }
    public init(executor: V2HTTPExecutor) { self.executor = executor }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await executor.execute(request, budget: .init(timeout: 15, maximumResponseBytes: 524_288), service: "mediaAuthorization")
    }

}

/// 面向与框架无关的 `GET /v2/media/{mediaID}` 边缘契约的 HTTPS 适配器。
///
/// 该请求刻意使用 no-store 且不重试：
/// 新目标必须反映当前的撤回、成员与设备状态。
public struct V2HTTPMediaDownloadTargetResolver: V2ClientMediaDownloadTargetResolver, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientMediaEdgeCredentialProvider
    private let transport: any V2ClientMediaEdgeHTTPTransport

    public init(
        endpoint: URL,
        credentials: any V2ClientMediaEdgeCredentialProvider,
        transport: any V2ClientMediaEdgeHTTPTransport = V2URLSessionMediaEdgeHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint
        }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    public func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation? = nil) async throws -> V2ClientMediaTransferTarget {
        try Task.checkCancellation()
        let edgeCredentials: V2ClientMediaEdgeCredentials
        do {
            edgeCredentials = try await credentials.mediaEdgeCredentials()
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as V2HTTPFailure { throw failure } catch let auth as V2AuthSessionError { throw auth } catch {
            throw V2ClientMediaTransferError.authorizationUnavailable
        }
        guard !edgeCredentials.accessToken.isEmpty,
              !edgeCredentials.accessToken.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2ClientMediaTransferError.authorizationUnavailable }

        guard var components = URLComponents(url: endpoint.appendingPathComponent(mediaID.rawValue, isDirectory: false), resolvingAgainstBaseURL: false) else {
            throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint
        }
        if let message {
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "room_id" && $0.name != "message_id" } + [
                .init(name: "room_id", value: message.roomID.rawValue), .init(name: "message_id", value: message.messageID.rawValue)
            ]
        }
        guard let requestURL = components.url else { throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint }
        var request = URLRequest(
            url: requestURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(edgeCredentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(edgeCredentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        V2HTTPRequestDeadline.attach(edgeCredentials.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2ClientMediaTransferError {
            throw error
        } catch let failure as V2HTTPFailure { throw failure }
        catch let auth as V2AuthSessionError { throw auth }
        catch {
            throw V2ClientMediaTransferError.networkFailure
        }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        case 401: throw V2ClientMediaTransferError.authorizationUnavailable
        case 403: throw V2ClientMediaTransferError.authorizationDenied
        case 429, 503: throw V2HTTPFailure.status(response, service: "mediaAuthorization")
        default: throw V2ClientMediaTransferError.serverStatus(response.statusCode)
        }
        let envelope: V2MediaDownloadTargetEnvelope
        do {
            guard data.count <= 512*1_024 else {throw V2ClientMediaTransferError.invalidMediaEdgeResponse}
            envelope = try JSONDecoder().decode(V2MediaDownloadTargetEnvelope.self, from: data)
            let plan = envelope.plan
            guard !plan.url.absoluteString.contains(edgeCredentials.accessToken),
                  !plan.headers.contains(where: { $0.value.contains(edgeCredentials.accessToken) })
            else { throw V2ClientMediaTransferError.invalidTarget }
            return try .init(downloadPlan: plan)
        } catch let error as V2ClientMediaTransferError {
            throw error
        } catch {
            throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        }
    }
}

/// 文件传输边界。
///
/// 它刻意与目标授权分离，使单元测试无需全局 URLProtocol 或真实网络。
public protocol V2ClientMediaByteTransfer: Sendable {
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws
}

/// 基于 URLSession 的前台媒体字节传输实现。
///
/// 下载计划只授权前台读取；资源上传的后台授权由独立上传协调器处理。
/// 该前台适配器通过 URLSession 的异步 API 继承调用方的取消，
/// 且绝不会把已签名目标写入磁盘。
public actor V2URLSessionMediaByteTransfer: V2ClientMediaByteTransfer {
    private let transport: any V2RangeDownloadTransport
    private let fileManager: FileManager
    private var active: Set<URL> = []
    private let chunkBytes: Int64
    public init(session: URLSession = V2SecureURLSession.mediaProvider, fileManager: FileManager = .default,
                scheduler: V2AccountWorkScheduler? = nil, diagnostics: V2NetworkDiagnostics? = nil) {
        transport = V2URLSessionRangeDownloadTransport(session: session,scheduler: scheduler,diagnostics: diagnostics)
        self.fileManager = fileManager; chunkBytes = 1024 * 1024
    }
    public init(transport: any V2RangeDownloadTransport, chunkBytes: Int64 = 1024 * 1024, fileManager: FileManager = .default) {
        precondition(chunkBytes > 0 && chunkBytes <= 8 * 1024 * 1024)
        self.transport = transport; self.chunkBytes = chunkBytes; self.fileManager = fileManager
    }
    public func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        try Task.checkCancellation()
        guard target.expiresAt > Date() else { throw V2ClientMediaTransferError.targetExpired }
        guard target.expectedByteCount >= 0,target.expectedByteCount <= 512 * 1024 * 1024 else { throw V2ClientMediaTransferError.invalidTarget }
        let destination = destinationURL.standardizedFileURL
        guard destination.isFileURL,!active.contains(destination) else { throw V2ClientMediaTransferError.uploadStateConflict }
        guard !fileManager.fileExists(atPath: destination.path) else { throw V2ClientMediaTransferError.destinationAlreadyExists }
        active.insert(destination); defer { active.remove(destination) }
        let file = try V2RangeDownloadFile(destination: destination,target: target)
        var rebuild: (V2RangeDownloadResponse, Int64)?
        do {
            var verifyCompletedCheckpoint = file.offset == target.expectedByteCount && target.expectedByteCount > 0
            while file.offset < target.expectedByteCount || verifyCompletedCheckpoint {
                verifyCompletedCheckpoint = false
                try Task.checkCancellation()
                let remainingLease = target.expiresAt.timeIntervalSinceNow
                guard remainingLease > 0 else { throw V2ClientMediaTransferError.targetExpired }
                let start = file.offset
                let priorETag = file.etag
                let end = start == target.expectedByteCount ? start + chunkBytes - 1 : min(target.expectedByteCount - 1,start + chunkBytes - 1)
                var request = URLRequest(url: target.url,cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,timeoutInterval: min(60,remainingLease))
                request.httpMethod = "GET"
                for (name,value) in target.headers { request.setValue(value,forHTTPHeaderField: name) }
                request.setValue("bytes=\(start)-\(end)",forHTTPHeaderField:"Range")
                request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
                if let etag = file.etag { request.setValue(etag,forHTTPHeaderField:"If-Range") }
                let transfer = try await transport.stream(request,maximumBytes: max(64 * 1024,target.expectedByteCount),
                    receiveResponse: { try file.accept($0,requestedStart: start,requestedEnd: end) },consume: { try file.append($0) })
                let response = transfer.response
                // A strong unchanged validator associates this rebuilt full body
                // with the already hash-verified local prefix. Publish's complete
                // checksum must still pass before the association becomes evidence.
                if start > 0, response.statusCode == 200, let priorETag,
                   response.value(forHTTPHeaderField: "ETag") == priorETag {
                    rebuild = (transfer, start)
                } else { transfer.record() }
                try file.finishResponse()
                guard file.offset > start || (file.offset == target.expectedByteCount && [200,416].contains(response.statusCode)) else { throw V2RangeDownloadError.invalidRange }
                // Each Range request drains and releases its byte permit before
                // another chunk is admitted. 200 providers restart from zero.
            }
            try Task.checkCancellation()
            try file.publish(to: destination)
            if let (transfer, prefix) = rebuild {
                let proven: Int64? = transfer.metric.flatMap { $0.bodyBytesReceived >= prefix ? prefix : nil }
                transfer.record(verifiedPrefixBytes: proven)
                rebuild = nil
            }
        } catch {
            // Failed validation, cancellation and missing task counters stay unknown.
            rebuild?.0.record()

            try? file.preserveProgress()
            if (error as? V2RangeDownloadError) == .versionChanged { try? file.discardProgress() }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }
}

/// 前台媒体下载编排：每次解析新的受控目标，再将字节写入调用者指定路径。
///
/// 本类型不管理账号缓存和发布目录；App 负责 partial、关闭栅栏、文件保护与清理。
public struct V2ClientMediaDownloadService: Sendable {
    private let targetResolver: any V2ClientMediaDownloadTargetResolver
    private let byteTransfer: any V2ClientMediaByteTransfer
    private let now: @Sendable () -> Date

    public init(targetResolver: any V2ClientMediaDownloadTargetResolver, byteTransfer: any V2ClientMediaByteTransfer, now: @escaping @Sendable () -> Date = Date.init) {
        self.targetResolver = targetResolver
        self.byteTransfer = byteTransfer
        self.now = now
    }

    public func authorizedTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget {
        let target = try await targetResolver.resolveDownloadTarget(mediaID: mediaID, message: message)
        try Task.checkCancellation()
        guard target.expiresAt > now() else { throw V2ClientMediaTransferError.targetExpired }
        return target
    }
    public func download(target: V2ClientMediaTransferTarget, to destination: URL) async throws {
        try Task.checkCancellation()
        guard target.expiresAt > now() else { throw V2ClientMediaTransferError.targetExpired }
        try await byteTransfer.download(target: target, destinationURL: destination)
    }

    public func download(mediaID: MediaID, message: V2MediaMessageLocation? = nil, to destinationURL: URL) async throws {
        let target: V2ClientMediaTransferTarget
        do {
            target = try await targetResolver.resolveDownloadTarget(mediaID: mediaID, message: message)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2ClientMediaTransferError {
            throw error
        } catch {
            throw V2ClientMediaTransferError.authorizationUnavailable
        }
        guard target.expiresAt > now() else { throw V2ClientMediaTransferError.targetExpired }
        try await byteTransfer.download(target: target, destinationURL: destinationURL)
    }
}

public enum V2ClientMediaTransferError: Error, Equatable, Sendable {
    case invalidTarget
    case invalidMediaEdgeEndpoint
    case invalidMediaEdgeResponse
    case authorizationUnavailable
    case authorizationDenied
    case targetExpired
    case byteCountMismatch
    case checksumMismatch
    case destinationAlreadyExists
    case invalidResponse
    case serverStatus(Int)
    case networkFailure
    case fileSystemFailure
    case uploadStateConflict
    case scanPending
    case mediaRejected
}
