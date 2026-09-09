import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// Ephemeral provider target returned by the authenticated media edge. This is
/// intentionally neither Codable nor persistable: a signed URL and its
/// headers must not enter a message projection, outbox, log, or backup.
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

/// Authenticated media-edge boundary. Implementations obtain a fresh opaque
/// server session and exchange it for a target; access tokens must stay inside
/// that adapter rather than being copied into provider-target headers.
public protocol V2ClientMediaDownloadTargetResolver: Sendable {
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget
}

/// The upload edge receives only validated metadata and returns a transient
/// write target. It never receives the local file URL or a durable provider
/// credential from the application.
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

/// A coherent device-bound credential pair for the authenticated media edge.
/// The access token must be used only in the edge request and never copied to
/// the resulting object-provider target or any persisted client state.
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

/// Isolates URLSession from request/response validation so resolver tests do
/// not rely on a global URLProtocol registration or a real edge deployment.
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

/// HTTPS adapter for the framework-neutral `GET /v2/media/{mediaID}` edge
/// contract. This request is deliberately no-store and non-retrying: a new
/// target must reflect current withdrawal, membership, and device state.
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

/// HTTPS adapter for the upload request and completion contracts. Both calls
/// use one coherent bearer-token/device pair, are explicitly no-store, and
/// never automatically retry a write: callers decide whether a failed upload
/// should create a fresh durable media intent.
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

/// File transfer boundary, deliberately separate from target authorization so
/// unit tests need no global URLProtocol or real network.
public protocol V2ClientMediaByteTransfer: Sendable {
    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) async throws
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws
}

/// Background transfer is intentionally not selected yet: V2 has no approved
/// persistent transfer-operation schema or relaunch callback contract. This
/// foreground adapter inherits caller cancellation through URLSession's async
/// APIs and never stores a signed target on disk.
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
