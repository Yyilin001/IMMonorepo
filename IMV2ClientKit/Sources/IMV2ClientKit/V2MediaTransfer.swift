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
    public let expectedByteCount: Int64?

    public init(url: URL, headers: [String: String] = [:], expiresAt: Date, expectedByteCount: Int64? = nil) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expectedByteCount.map({ $0 >= 0 }) ?? true,
              headers.allSatisfy({ key, value in
                  Self.isAllowedProviderHeader(key)
                      && key.utf8.count <= 128
                      && value.utf8.count <= 8_192
                      && !key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
                      && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
              })
        else { throw V2ClientMediaTransferError.invalidTarget }
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
        self.expectedByteCount = expectedByteCount
    }

    private static func isAllowedProviderHeader(_ name: String) -> Bool {
        let canonical = name.lowercased()
        return canonical == "content-type"
            || canonical == "content-md5"
            || canonical == "digest"
            || canonical.hasPrefix("x-amz-")
            || canonical.hasPrefix("x-oss-")
            || canonical.hasPrefix("x-goog-")
    }
}

/// 已认证的媒体边缘边界。
///
/// 实现需要获取一个全新的不透明服务端会话，并用它换取目标；
/// 访问令牌必须留在该适配器内部，而不能被复制进提供方目标的请求头。
public protocol V2ClientMediaDownloadTargetResolver: Sendable {
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget
}

/// 上传边缘接收的只有已校验的元数据，并返回一个临时的写入目标。
///
/// 它绝不会从应用收到本地文件 URL 或持久化的提供方凭据。
public protocol V2ClientMediaUploadTargetResolver: Sendable {
    func resolveUploadTarget(
        operationID: MediaUploadOperationID,
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64
    ) async throws -> V2ClientMediaTransferTarget
}

public protocol V2ClientMediaUploadCompleting: Sendable {
    func completeUpload(mediaID: MediaID) async throws
}

public protocol V2ClientMediaUploadStatusReading: Sendable {
    func uploadStatus(mediaID: MediaID) async throws -> V2MediaObjectState
}

/// 用于已认证媒体边缘的、自洽且绑定设备的凭据对。
///
/// 访问令牌只能用于边缘请求，绝不能被复制到最终的对象提供方目标或任何持久化的客户端状态中。
public struct V2ClientMediaEdgeCredentials: Sendable {
    public let accessToken: String
    public let deviceID: DeviceID

    public init(accessToken: String, deviceID: DeviceID) {
        self.accessToken = accessToken
        self.deviceID = deviceID
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
    private let session: URLSession

    public init(session: URLSession = V2SecureURLSession.account) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw V2ClientMediaTransferError.invalidResponse }
        return (data, http)
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
        } catch {
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
        } catch {
            throw V2ClientMediaTransferError.networkFailure
        }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        case 401, 403: throw V2ClientMediaTransferError.authorizationDenied
        default: throw V2ClientMediaTransferError.serverStatus(response.statusCode)
        }
        let envelope: V2MediaDownloadTargetEnvelope
        do {
            envelope = try JSONDecoder().decode(V2MediaDownloadTargetEnvelope.self, from: data)
            guard let url = URL(string: envelope.url) else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
            return try .init(
                url: url,
                headers: envelope.headers,
                expiresAt: envelope.expiresAt,
                expectedByteCount: envelope.expectedByteCount
            )
        } catch let error as V2ClientMediaTransferError {
            throw error
        } catch {
            throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        }
    }
}

/// 面向上传请求与完成契约的 HTTPS 适配器。
///
/// 两次调用共用同一份自洽的 Bearer 令牌/设备组合，显式使用 no-store，
/// 且绝不自动重试写入：失败的上传是否要创建新的持久媒体意图，由调用方决定。
public struct V2HTTPMediaUploadEdgeClient: V2ClientMediaUploadTargetResolver, V2ClientMediaUploadCompleting, V2ClientMediaUploadStatusReading, Sendable {
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

    public func resolveUploadTarget(
        operationID: MediaUploadOperationID,
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64
    ) async throws -> V2ClientMediaTransferTarget {
        guard byteCount > 0 else { throw V2ClientMediaTransferError.invalidUploadRequest }
        var request = try await authenticatedRequest(
            url: endpoint.appendingPathComponent("uploads", isDirectory: false),
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(V2MediaUploadTargetRequestBody(
                operationID: operationID.rawValue,
                mediaID: mediaID.rawValue,
                contentType: contentType,
                byteCount: byteCount
            ))
        } catch {
            throw V2ClientMediaTransferError.invalidUploadRequest
        }
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        case 401, 403: throw V2ClientMediaTransferError.authorizationDenied
        case 409: throw V2ClientMediaTransferError.uploadStateConflict
        default: throw V2ClientMediaTransferError.serverStatus(response.statusCode)
        }
        do {
            let envelope = try JSONDecoder().decode(V2MediaUploadTargetEnvelope.self, from: data)
            guard let url = URL(string: envelope.url) else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
            return try .init(
                url: url,
                headers: envelope.headers,
                expiresAt: envelope.expiresAt,
                expectedByteCount: envelope.expectedByteCount
            )
        } catch let error as V2ClientMediaTransferError {
            throw error
        } catch {
            throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        }
    }

    public func completeUpload(mediaID: MediaID) async throws {
        let request = try await authenticatedRequest(
            url: endpoint.appendingPathComponent(mediaID.rawValue, isDirectory: false).appendingPathComponent("complete", isDirectory: false),
            method: "POST"
        )
        let (_, response) = try await send(request)
        switch response.statusCode {
        case 204: return
        case 401, 403: throw V2ClientMediaTransferError.authorizationDenied
        case 404, 409: throw V2ClientMediaTransferError.uploadStateConflict
        default: throw V2ClientMediaTransferError.serverStatus(response.statusCode)
        }
    }

    public func uploadStatus(mediaID: MediaID) async throws -> V2MediaObjectState {
        let request = try await authenticatedRequest(
            url: endpoint.appendingPathComponent(mediaID.rawValue, isDirectory: false).appendingPathComponent("upload-status", isDirectory: false),
            method: "GET"
        )
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        case 401, 403: throw V2ClientMediaTransferError.authorizationDenied
        case 404: throw V2ClientMediaTransferError.uploadStateConflict
        default: throw V2ClientMediaTransferError.serverStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(V2MediaUploadStatusEnvelope.self, from: data).state
        } catch {
            throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        }
    }

    private func authenticatedRequest(url: URL, method: String) async throws -> URLRequest {
        try Task.checkCancellation()
        let edgeCredentials: V2ClientMediaEdgeCredentials
        do {
            edgeCredentials = try await credentials.mediaEdgeCredentials()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2ClientMediaTransferError.authorizationUnavailable
        }
        guard !edgeCredentials.accessToken.isEmpty,
              !edgeCredentials.accessToken.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2ClientMediaTransferError.authorizationUnavailable }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = method
        request.setValue("Bearer \(edgeCredentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(edgeCredentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2ClientMediaTransferError {
            throw error
        } catch {
            throw V2ClientMediaTransferError.networkFailure
        }
    }
}

/// 文件传输边界。
///
/// 它刻意与目标授权分离，使单元测试无需全局 URLProtocol 或真实网络。
public protocol V2ClientMediaByteTransfer: Sendable {
    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) async throws
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws
}

/// 基于 URLSession 的前台媒体字节传输实现。
///
/// 目前刻意不选用后台传输：V2 还没有获批的持久传输操作 schema 或重新启动回调契约。
/// 该前台适配器通过 URLSession 的异步 API 继承调用方的取消，
/// 且绝不会把已签名目标写入磁盘。
public actor V2URLSessionMediaByteTransfer: V2ClientMediaByteTransfer {
    private let session: URLSession
    private let fileManager: FileManager

    public init(session: URLSession = V2SecureURLSession.mediaProvider, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    public func upload(fileURL: URL, target: V2ClientMediaTransferTarget) async throws {
        try Task.checkCancellation()
        let byteCount = try fileByteCount(at: fileURL)
        try validate(target: target, actualByteCount: byteCount)
        let request = request(for: target, method: "PUT")
        do {
            let (_, response) = try await session.upload(for: request, fromFile: fileURL)
            try validate(response: response)
        } catch {
            throw try mapTransport(error)
        }
    }

    public func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        try Task.checkCancellation()
        try validate(target: target, actualByteCount: nil)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw V2ClientMediaTransferError.destinationAlreadyExists
        }
        do {
            let (temporaryURL, response) = try await session.download(for: request(for: target, method: "GET"))
            defer { try? fileManager.removeItem(at: temporaryURL) }
            try validate(response: response)
            let byteCount = try fileByteCount(at: temporaryURL)
            if let expected = target.expectedByteCount, byteCount != expected {
                throw V2ClientMediaTransferError.byteCountMismatch
            }
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                throw V2ClientMediaTransferError.destinationAlreadyExists
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch let error as V2ClientMediaTransferError {
            throw error
        } catch {
            throw try mapTransport(error)
        }
    }

    private func request(for target: V2ClientMediaTransferTarget, method: String) -> URLRequest {
        var request = URLRequest(url: target.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        for (name, value) in target.headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func validate(target: V2ClientMediaTransferTarget, actualByteCount: Int64?) throws {
        guard target.expiresAt > Date() else { throw V2ClientMediaTransferError.targetExpired }
        if let expected = target.expectedByteCount, let actualByteCount, expected != actualByteCount {
            throw V2ClientMediaTransferError.byteCountMismatch
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw V2ClientMediaTransferError.invalidResponse }
        switch http.statusCode {
        case 200 ... 299: return
        case 401, 403: throw V2ClientMediaTransferError.authorizationDenied
        default: throw V2ClientMediaTransferError.serverStatus(http.statusCode)
        }
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fileManager.attributesOfItem(atPath: url.path) }
        catch { throw V2ClientMediaTransferError.fileSystemFailure }
        guard let value = attributes[.size] as? NSNumber else { throw V2ClientMediaTransferError.fileSystemFailure }
        return value.int64Value
    }

    private func mapTransport(_ error: Error) throws -> V2ClientMediaTransferError {
        if error is CancellationError { throw CancellationError() }
        if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
        if let transferError = error as? V2ClientMediaTransferError { return transferError }
        return .networkFailure
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

/// 前台媒体上传编排：解析目标、上传字节、通知完成并等待扫描可用。
///
/// 每个异步业务阶段后检查取消，避免迟到成功继续触发下一阶段。
/// 返回成功只证明媒体达到可用状态，不表示引用该媒体的消息已经发送。
public struct V2ClientMediaUploadService: Sendable {
    private let targetResolver: any V2ClientMediaUploadTargetResolver
    private let byteTransfer: any V2ClientMediaByteTransfer
    private let completer: any V2ClientMediaUploadCompleting
    private let statusReader: any V2ClientMediaUploadStatusReading
    private let now: @Sendable () -> Date
    private let maximumAvailabilityChecks: Int
    private let availabilityCheckInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        targetResolver: any V2ClientMediaUploadTargetResolver,
        byteTransfer: any V2ClientMediaByteTransfer,
        completer: any V2ClientMediaUploadCompleting,
        statusReader: any V2ClientMediaUploadStatusReading,
        now: @escaping @Sendable () -> Date = Date.init,
        maximumAvailabilityChecks: Int = 60,
        availabilityCheckInterval: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        precondition(maximumAvailabilityChecks > 0)
        precondition(availabilityCheckInterval > .zero)
        self.targetResolver = targetResolver
        self.byteTransfer = byteTransfer
        self.completer = completer
        self.statusReader = statusReader
        self.now = now
        self.maximumAvailabilityChecks = maximumAvailabilityChecks
        self.availabilityCheckInterval = availabilityCheckInterval
        self.sleep = sleep
    }

    public func upload(
        fileURL: URL,
        operationID: MediaUploadOperationID,
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64
    ) async throws {
        try Task.checkCancellation()
        guard byteCount > 0 else { throw V2ClientMediaTransferError.invalidUploadRequest }
        let target: V2ClientMediaTransferTarget
        do {
            target = try await targetResolver.resolveUploadTarget(
                operationID: operationID,
                mediaID: mediaID,
                contentType: contentType,
                byteCount: byteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2ClientMediaTransferError {
            throw error
        } catch {
            throw V2ClientMediaTransferError.authorizationUnavailable
        }
        try Task.checkCancellation()
        guard target.expiresAt > now(), target.expectedByteCount == byteCount else {
            if target.expiresAt > now() {
                throw V2ClientMediaTransferError.byteCountMismatch
            }
            throw V2ClientMediaTransferError.targetExpired
        }
        try await byteTransfer.upload(fileURL: fileURL, target: target)
        try Task.checkCancellation()
        try await completer.completeUpload(mediaID: mediaID)
        try await awaitAvailability(of: mediaID)
    }

    private func awaitAvailability(of mediaID: MediaID) async throws {
        for check in 0 ..< maximumAvailabilityChecks {
            try Task.checkCancellation()
            let state: V2MediaObjectState
            do {
                state = try await statusReader.uploadStatus(mediaID: mediaID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as V2ClientMediaTransferError {
                throw error
            } catch {
                throw V2ClientMediaTransferError.networkFailure
            }
            try Task.checkCancellation()
            switch state {
            case .available:
                return
            case .failed, .expired:
                throw V2ClientMediaTransferError.mediaRejected
            case .pendingUpload, .scanning:
                guard check + 1 < maximumAvailabilityChecks else { break }
                try await sleep(availabilityCheckInterval)
            }
        }
        throw V2ClientMediaTransferError.scanPending
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
    case destinationAlreadyExists
    case invalidResponse
    case serverStatus(Int)
    case networkFailure
    case fileSystemFailure
    case invalidUploadRequest
    case uploadStateConflict
    case scanPending
    case mediaRejected
}

private struct V2MediaUploadTargetRequestBody: Encodable {
    let operationID: String
    let mediaID: String
    let contentType: String
    let byteCount: Int64
}
