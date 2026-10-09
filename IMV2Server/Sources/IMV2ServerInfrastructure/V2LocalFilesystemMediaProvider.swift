import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import Foundation
import IMV2Core
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 一次本地开发上传的不透明授权。
///
/// HTTP 适配器只能写入随机暂存地址；签名目标声明与最终对象路径仍由提供方 actor
/// 持有并重新校验。
public struct V2LocalFilesystemStagedUpload: V2StagedMediaFile {
    public let fileURL: URL
    fileprivate let mediaID: MediaID
    fileprivate let targetURL: URL
    fileprivate let contentType: String
    fileprivate let expectedByteCount: Int64
}

/// 本地开发下载目标授权通过后返回的文件元数据。
///
/// 字节边缘会流式转发该文件，而不是把内容完整读入进程内存。
public struct V2LocalFilesystemDownloadedObject: V2DownloadedMediaFile {
    public let fileURL: URL
    public let byteCount: Int64

    public func strongETag() async throws -> String {
        try Task.checkCancellation()
        let file = fileURL
        // FileHandle reads are blocking. Keep them outside the HTTP actor and
        // explicitly transfer cancellation to this owned hashing task.
        let hashing = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 128 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                hash.update(data: bytes)
            }
            let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return "\"\(hex)\""
        }
        return try await withTaskCancellationHandler {
            let result = try await hashing.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            hashing.cancel()
        }
    }
}

/// 仅用于本地、可重复的开发者与隔离测试验证的对象提供方。
///
/// 它刻意不被生产运行时装配：地址主机、TLS 终结、持久化对象存储与恶意软件扫描
/// 仍属于部署方职责。
///
/// 提供方把不透明媒体字节保存在调用方指定的私有目录中，并签发短时、精确到单个对象的访问目标。
/// 任何本地文件地址或文件系统路径都不会返回给 IM 领域层或客户端协议。
public actor V2LocalFilesystemMediaProvider: V2LocalMediaByteServing, V2MediaObjectProvider, V2MediaUploadObjectProvider, V2MediaPurgeProvider {
    private let rootDirectory: URL
    private let targetBaseURL: URL
    private let signingKey: Data
    private let now: @Sendable () -> Date
    private var didPrepare = false
    private var preparation: Task<Void, any Error>?

    /// 校验并保存根目录、目标地址与签名密钥。
    ///
    /// - Parameters:
    ///   - rootDirectory: 媒体字节落盘的私有根目录。
    ///   - targetBaseURL: 对外发布的 HTTPS 基础地址，需带主机且不含查询与片段。
    ///   - signingKey: 签名密钥，至少 32 字节。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2LocalFilesystemMediaProviderError/invalidConfiguration``。
    public init(
        rootDirectory: URL,
        targetBaseURL: URL,
        signingKey: Data,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard signingKey.count >= 32,
              targetBaseURL.scheme?.lowercased() == "https",
              targetBaseURL.host != nil,
              targetBaseURL.query == nil,
              targetBaseURL.fragment == nil
        else { throw V2LocalFilesystemMediaProviderError.invalidConfiguration }
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.targetBaseURL = targetBaseURL
        self.signingKey = signingKey
        self.now = now
    }

    /// 在进程启动时建立私有目录并清理上次崩溃遗留的上传碎片。
    ///
    /// 同一提供方的并发调用等待同一次初始化；成功后重复调用是空操作，失败后可以重试。
    /// 初始化不会因单个调用方取消而中断，避免留下只完成一半的暂存目录。
    ///
    /// - Throws: 目录创建或清理失败时抛出。
    public func prepare() async throws {
        guard !didPrepare else { return }
        if let preparation { return try await preparation.value }
        // 挂起前先发布任务：Actor 可重入性不能启动第二次破坏性清理。
        // 调用方取消不会取消共享初始化；所有调用方等待同一个
        // 有界文件系统任务结束。
        let task = Task {
            defer { preparation = nil }
            let rootDirectory = self.rootDirectory
            let stagingDirectory = self.stagingDirectory
            try await Self.performBlocking {
                try FileManager.default.createDirectory(
                    at: rootDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if FileManager.default.fileExists(atPath: stagingDirectory.path) {
                    try FileManager.default.removeItem(at: stagingDirectory)
                }
                try FileManager.default.createDirectory(
                    at: stagingDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            didPrepare = true
        }
        preparation = task
        try await task.value
    }

    /// 为一个上传会话签发短时上传目标。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - contentType: 媒体内容类型，需非空。
    ///   - byteCount: 期望字节数，需非负。
    ///   - expiresAt: 目标到期时刻。
    /// - Returns: 提供方对象目标。
    /// - Throws: 媒体标识非法、内容类型为空或字节数为负时抛出
    ///   ``V2LocalFilesystemMediaProviderError/invalidTarget`` 或
    ///   ``V2LocalFilesystemMediaProviderError/invalidMediaID``。
    public func issueUploadTarget(
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64,
        expiresAt: Date
    ) async throws -> V2MediaProviderUploadTarget {
        guard byteCount >= 0, !contentType.isEmpty else {
            throw V2LocalFilesystemMediaProviderError.invalidTarget
        }
        _ = try objectURL(for: mediaID)
        let url = try signedTarget(
            kind: .upload,
            mediaID: mediaID,
            contentType: contentType,
            byteCount: byteCount,
            expiresAt: expiresAt
        )
        return .init(
            url: url,
            headers: ["Content-Type": contentType],
            expiresAt: expiresAt,
            expectedByteCount: byteCount
        )
    }

    /// Only the resource authority calls this after allocating and reauthorizing an attachment session.
    /// The new delegated PUT is signed independently of a short room activation.
    public func issueBackgroundUploadTarget(mediaID: MediaID, contentType: String, byteCount: Int64,
                                            authorization: V2ResourceBackgroundAuthorization) async throws -> V2MediaProviderUploadTarget {
        guard byteCount>0,byteCount<=8*1_024*1_024,!contentType.isEmpty else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        _ = try objectURL(for:mediaID)
        let url = try signedTarget(kind:.upload,mediaID:mediaID,contentType:contentType,byteCount:byteCount,
                                   expiresAt:authorization.expiresAt,backgroundAuthorization:authorization)
        return .init(url:url,headers:["Content-Type":contentType],expiresAt:authorization.expiresAt,expectedByteCount:byteCount)
    }

    /// 为一个下载会话签发短时下载目标。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - expiresAt: 目标到期时刻。
    /// - Returns: 提供方对象目标。
    /// - Throws: 媒体标识非法或对象不可用时抛出。
    public func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) async throws -> V2ResourceTransferPlan {
        _ = try validatedExpiryMilliseconds(expiresAt)
        let objectURL = try objectURL(for: mediaID)
        let byteCount = try await Self.performBlocking { () throws -> Int64 in
            try Self.requireNotPurged(objectURL)
            guard FileManager.default.fileExists(atPath: objectURL.path) else {
                throw V2LocalFilesystemMediaProviderError.objectUnavailable
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: objectURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw V2LocalFilesystemMediaProviderError.objectUnavailable
            }
            return size.int64Value
        }
        let digest = try await Self.performBlocking {
            try ForwardMediaFileIO.digest(objectURL, byteCount: byteCount)
        }
        let checksum = try V2ResourceChecksum(value: digest.map { String(format: "%02x", $0) }.joined())
        _ = try validatedExpiryMilliseconds(expiresAt)
        let instant = now()
        // Legacy long-lived/empty foreground targets do not delegate persistence to the OS.
        let grant: V2ResourceBackgroundDownloadAuthorization?
        if byteCount > 0, byteCount <= 512 * 1_024 * 1_024,
           instant.timeIntervalSince1970 > 0, expiresAt > instant, expiresAt.timeIntervalSince(instant) <= 900 {
            grant = try .init(id: UUID(), expectedByteCount: byteCount, checksum: checksum,
                              issuedAt: instant, expiresAt: expiresAt)
        } else { grant = nil }
        let url = try signedTarget(kind: .download, mediaID: mediaID, contentType: nil,
            byteCount: byteCount, expiresAt: expiresAt, backgroundDownloadAuthorization: grant)
        return try .init(mode: .httpGet, url: url, expiresAt: expiresAt, expectedByteCount: byteCount,
                         checksum: checksum, backgroundDownloadAuthorization: grant)
    }

    /// 在接收 HTTP 正文之前校验上传目标的签名声明，并在私有暂存目录中预留随机文件。
    ///
    /// 返回的路径并不指向最终对象。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - targetURL: 客户端提交的已签名目标地址。
    ///   - contentType: 声明的内容类型。
    ///   - declaredByteCount: 声明的字节数。
    /// - Returns: 暂存上传句柄。
    /// - Throws: 签名声明与本次上传不一致时抛出
    ///   ``V2LocalFilesystemMediaProviderError/byteCountMismatch``；
    ///   目标签名不合法时抛出 ``V2LocalFilesystemMediaProviderError/invalidTarget``。
    public func beginUploadedObject(
        mediaID: MediaID,
        targetURL: URL,
        contentType: String,
        declaredByteCount: Int64
    ) async throws -> V2LocalFilesystemStagedUpload {
        let claims = try verify(targetURL: targetURL, kind: .upload, mediaID: mediaID)
        guard claims.contentType == contentType,
              claims.byteCount == declaredByteCount,
              declaredByteCount >= 0
        else { throw V2LocalFilesystemMediaProviderError.byteCountMismatch }
        let stagingDirectory = self.stagingDirectory
        try await Self.performBlocking {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return .init(
            fileURL: stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false),
            mediaID: mediaID,
            targetURL: targetURL,
            contentType: contentType,
            expectedByteCount: declaredByteCount
        )
    }

    /// 重新校验目标有效期与精确字节数，然后以原子方式把暂存文件移动到同一卷上的不可变对象位置。
    ///
    /// - Parameters:
    ///   - upload: 暂存上传句柄。
    ///   - actualByteCount: 暂存上传实际写入的字节数。
    /// - Throws: 目标已过期、字节数不符或移动失败时抛出。
    public func commitUploadedObject(
        _ upload: V2LocalFilesystemStagedUpload,
        actualByteCount: Int64
    ) async throws {
        let claims = try verify(targetURL: upload.targetURL, kind: .upload, mediaID: upload.mediaID)
        guard claims.contentType == upload.contentType,
              claims.byteCount == upload.expectedByteCount,
              actualByteCount == upload.expectedByteCount,
              isValidStagingURL(upload.fileURL)
        else { throw V2LocalFilesystemMediaProviderError.byteCountMismatch }
        let rootDirectory = self.rootDirectory
        let objectURL = try objectURL(for: upload.mediaID)
        try await Self.performBlocking {
            try Self.withObjectMutationLock(objectURL) { marker in
                guard !FileManager.default.fileExists(atPath: marker.path) else { throw V2LocalFilesystemMediaProviderError.objectUnavailable }
                let attributes = try FileManager.default.attributesOfItem(atPath: upload.fileURL.path)
                guard let size = attributes[.size] as? NSNumber,
                      size.int64Value == actualByteCount
                else { throw V2LocalFilesystemMediaProviderError.byteCountMismatch }
                try FileManager.default.createDirectory(
                    at: rootDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: upload.fileURL.path
                )
                if FileManager.default.fileExists(atPath: objectURL.path) {
                    // Lost upload responses retry the same immutable identity. Equal bytes replay;
                    // different bytes can never replace a file that may already be under verification.
                    guard try ForwardMediaFileIO.digest(objectURL, byteCount: actualByteCount)
                        == ForwardMediaFileIO.digest(upload.fileURL, byteCount: actualByteCount)
                    else { throw V2LocalFilesystemMediaProviderError.byteCountMismatch }
                    try FileManager.default.removeItem(at: upload.fileURL)
                } else {
                    try FileManager.default.moveItem(at: upload.fileURL, to: objectURL)
                }
                try ForwardMediaFileIO.syncDirectory(rootDirectory)
            }
        }
    }

    /// 丢弃暂存上传文件，忽略文件已不存在的情况。
    ///
    /// - Parameter upload: 暂存上传句柄。
    public func discardUploadedObject(_ upload: V2LocalFilesystemStagedUpload) async {
        guard isValidStagingURL(upload.fileURL) else { return }
        let fileURL = upload.fileURL
        try? await Self.performBlocking {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 直接把已完成字节写入最终对象位置，供本地工具与测试使用。
    ///
    /// 仅当字节与精确的已签名本地上传目标一同提交时才接受。
    /// 它供本地无 HTTP 测试使用；生产对象边缘必须改为校验其自身的提供方原生目标。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - contentType: 媒体内容类型。
    ///   - bytes: 对象内容。
    /// - Throws: 媒体标识非法或写入失败时抛出。
    public func storeUploadedObject(
        mediaID: MediaID,
        targetURL: URL,
        contentType: String,
        bytes: Data
    ) async throws {
        let upload = try await beginUploadedObject(
            mediaID: mediaID,
            targetURL: targetURL,
            contentType: contentType,
            declaredByteCount: Int64(bytes.count)
        )
        do {
            try await Self.performBlocking {
                try bytes.write(to: upload.fileURL, options: .withoutOverwriting)
            }
            try await commitUploadedObject(upload, actualByteCount: Int64(bytes.count))
        } catch {
            await discardUploadedObject(upload)
            throw error
        }
    }

    /// 按已签名的下载目标返回可供流式读取的文件元数据。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - targetURL: 客户端提交的已签名目标地址。
    /// - Returns: 文件地址与字节数。
    /// - Throws: 目标签名不合法、已过期或对象不可读时抛出。
    public func downloadedObject(
        mediaID: MediaID,
        targetURL: URL
    ) async throws -> V2LocalFilesystemDownloadedObject {
        let claims = try verify(targetURL: targetURL, kind: .download, mediaID: mediaID)
        let objectURL = try objectURL(for: mediaID)
        let byteCount = try await Self.performBlocking { () throws -> Int64 in
            try Self.requireNotPurged(objectURL)
            guard FileManager.default.fileExists(atPath: objectURL.path) else {
                throw V2LocalFilesystemMediaProviderError.objectUnavailable
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: objectURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value == claims.byteCount
            else { throw V2LocalFilesystemMediaProviderError.objectUnavailable }
            return size.int64Value
        }
        return .init(fileURL: objectURL, byteCount: byteCount)
    }

    /// 读取已授权下载目标的完整字节，仅供扫描等本地用途。
    ///
    /// 仅当字节与精确的已签名本地下载目标一同提交时才允许读取。
    /// 返回的数据只用于本地对象边缘测试，绝不用于聊天事件序列化。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - targetURL: 已签名目标地址。
    /// - Returns: 文件字节。
    /// - Throws: 目标不合法或读取失败时抛出。
    public func readDownloadedObject(mediaID: MediaID, targetURL: URL) async throws -> Data {
        let object = try await downloadedObject(mediaID: mediaID, targetURL: targetURL)
        return try await Self.performBlocking {
            try Data(contentsOf: object.fileURL, options: [.mappedIfSafe])
        }
    }

    /// 持久标记媒体已删除并移除对象；迟到提交不能恢复它，调用方仍负责释放暂存文件。
    ///
    /// - Parameter mediaID: 目标媒体标识。
    /// - Throws: 媒体标识非法时抛出
    ///   ``V2LocalFilesystemMediaProviderError/invalidMediaID``。
    public func purge(mediaID: MediaID) async throws {
        let objectURL = try objectURL(for: mediaID)
        try await Self.performBlocking {
            try Self.withObjectMutationLock(objectURL) { marker in
                if !FileManager.default.fileExists(atPath: marker.path) {
                    try Data([1]).write(to: marker, options: .withoutOverwriting)
                }
                let handle = try FileHandle(forWritingTo: marker)
                defer { try? handle.close() }
                try handle.synchronize()
                try ForwardMediaFileIO.syncDirectory(marker.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: objectURL.path) {
                    try FileManager.default.removeItem(at: objectURL)
                }
                try ForwardMediaFileIO.syncDirectory(objectURL.deletingLastPathComponent())
            }
        }
    }

    /// 读取本地媒体字节，供本地扫描器使用。
    ///
    /// 该入口仅供开发期的 `V2LocalEICARMediaScanner` 检查使用。
    /// 对象缺失属于可重试的扫描失败，而不是判定为干净。
    ///
    /// - Parameter mediaID: 目标媒体标识。
    /// - Returns: 对象字节。
    /// - Throws: 媒体标识非法或对象不存在时抛出。
    public func localBytesForScanning(mediaID: MediaID) async throws -> Data {
        let objectURL = try objectURL(for: mediaID)
        return try await Self.performBlocking {
            try Self.requireNotPurged(objectURL)
            guard FileManager.default.fileExists(atPath: objectURL.path) else {
                throw V2LocalFilesystemMediaProviderError.objectUnavailable
            }
            return try Data(contentsOf: objectURL, options: [.mappedIfSafe])
        }
    }

    // 绝不删除锁文件：旧、新文件描述符必须保护同一 inode。
    private nonisolated static func withObjectMutationLock<Value>(
        _ object: URL, action: (URL) throws -> Value
    ) throws -> Value {
        let directory = object.deletingLastPathComponent().appendingPathComponent(".object-state", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try ForwardMediaFileIO.syncDirectory(object.deletingLastPathComponent())
        let lock = directory.appendingPathComponent(object.lastPathComponent + ".lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try action(directory.appendingPathComponent(object.lastPathComponent + ".purged"))
    }

    private nonisolated static func requireNotPurged(_ object: URL) throws {
        let marker = object.deletingLastPathComponent().appendingPathComponent(".object-state", isDirectory: true)
            .appendingPathComponent(object.lastPathComponent + ".purged")
        guard !FileManager.default.fileExists(atPath: marker.path) else {
            throw V2LocalFilesystemMediaProviderError.objectUnavailable
        }
    }

    private func signedTarget(
        kind: TargetKind,
        mediaID: MediaID,
        contentType: String?,
        byteCount: Int64,
        expiresAt: Date, backgroundAuthorization: V2ResourceBackgroundAuthorization? = nil,
        backgroundDownloadAuthorization: V2ResourceBackgroundDownloadAuthorization? = nil
    ) throws -> URL {
        // 下载元数据查询会挂起 Actor。此处再次校验，
        // 确保目标在实际签名时仍可使用。
        let milliseconds = try validatedExpiryMilliseconds(expiresAt)
        let claims = TargetClaims(
            kind: kind.rawValue,
            mediaID: mediaID.rawValue,
            contentType: contentType,
            byteCount: byteCount,
            expiresAtMilliseconds: milliseconds, backgroundAuthorization: backgroundAuthorization,
            backgroundDownloadAuthorization: backgroundDownloadAuthorization
        )
        let payload = try JSONEncoder().encode(claims)
        let encodedPayload = Self.base64URL(payload)
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(encodedPayload.utf8),
            using: SymmetricKey(data: signingKey)
        )
        guard var components = URLComponents(url: targetBaseURL, resolvingAgainstBaseURL: false) else {
            throw V2LocalFilesystemMediaProviderError.invalidTarget
        }
        components.path += "/v2/local-media/" + kind.rawValue + "/" + mediaID.rawValue
        components.queryItems = [
            .init(name: "target", value: "v2lm1.\(encodedPayload).\(Self.base64URL(Data(signature)))"),
        ]
        guard let url = components.url else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        return url
    }

    private func verify(targetURL: URL, kind: TargetKind, mediaID: MediaID) throws -> TargetClaims {
        guard targetURL.scheme?.lowercased() == targetBaseURL.scheme?.lowercased(),
              targetURL.host == targetBaseURL.host,
              targetURL.port == targetBaseURL.port,
              let token = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "target" })?
                .value
        else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "v2lm1",
              let payload = Self.decodeBase64URL(String(parts[1])),
              let signature = Self.decodeBase64URL(String(parts[2])),
              HMAC<SHA256>.isValidAuthenticationCode(
                signature,
                authenticating: Data(parts[1].utf8),
                using: SymmetricKey(data: signingKey)
              ),
              let claims = try? JSONDecoder().decode(TargetClaims.self, from: payload),
              claims.kind == kind.rawValue,
              claims.mediaID == mediaID.rawValue
        else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        guard Double(claims.expiresAtMilliseconds) > (try currentMilliseconds()) else {
            throw V2LocalFilesystemMediaProviderError.invalidTarget
        }
        if let grant = claims.backgroundAuthorization {
            guard kind == .upload, claims.byteCount>0,claims.byteCount<=8*1_024*1_024,
                  grant.expiresAtMilliseconds == claims.expiresAtMilliseconds
            else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        }
        if let grant = claims.backgroundDownloadAuthorization {
            guard kind == .download, claims.backgroundAuthorization == nil,
                  grant.expectedByteCount == claims.byteCount,
                  grant.expiresAtMilliseconds == claims.expiresAtMilliseconds
            else { throw V2LocalFilesystemMediaProviderError.invalidTarget }
        }
        return claims
    }

    private func validatedExpiryMilliseconds(_ expiresAt: Date) throws -> Int64 {
        // 目标编码后的截止时间不能晚于请求的截止时间。
        // 向零截断会延长负的 Unix 时间戳。
        guard let milliseconds = Int64(exactly: (expiresAt.timeIntervalSince1970 * 1_000).rounded(.down)),
              Double(milliseconds) > (try currentMilliseconds()) else {
            throw V2LocalFilesystemMediaProviderError.invalidTarget
        }
        return milliseconds
    }

    private func currentMilliseconds() throws -> Double {
        let milliseconds = now().timeIntervalSince1970 * 1_000
        guard Int64(exactly: milliseconds.rounded(.towardZero)) != nil else {
            throw V2LocalFilesystemMediaProviderError.invalidTarget
        }
        return milliseconds
    }

    private func objectURL(for mediaID: MediaID) throws -> URL {
        guard UUID(uuidString: mediaID.rawValue) != nil else {
            throw V2LocalFilesystemMediaProviderError.invalidMediaID
        }
        return rootDirectory.appendingPathComponent(mediaID.rawValue, isDirectory: false)
    }

    private var stagingDirectory: URL {
        rootDirectory.appendingPathComponent(".upload-staging", isDirectory: true)
    }

    private func isValidStagingURL(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent() == stagingDirectory.standardizedFileURL
            && UUID(uuidString: standardized.lastPathComponent) != nil
    }

    private nonisolated static func performBlocking<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: .utility, operation: operation).value
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func decodeBase64URL(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    private enum TargetKind: String { case upload, download }
    private struct TargetClaims: Codable {
        let kind: String
        let mediaID: String
        let contentType: String?
        let byteCount: Int64
        let expiresAtMilliseconds: Int64
        let backgroundAuthorization: V2ResourceBackgroundAuthorization?
        let backgroundDownloadAuthorization: V2ResourceBackgroundDownloadAuthorization?
    }
}

/// 本地文件系统媒体提供方错误。


/// 基于真实但无害的 EICAR 测试签名的本地扫描器。
///
/// 它可以在没有第三方守护进程的情况下演练扫描通过与被拒两种状态跃迁，
/// 但它不提供恶意软件防护，绝不能在生产部署中被选用。
public struct V2LocalEICARMediaScanner: V2MediaScanProvider, Sendable {
    private let provider: V2LocalFilesystemMediaProvider

    /// 组合本地媒体提供方。
    ///
    /// - Parameter provider: 读取待扫描字节的本地提供方。
    public init(provider: V2LocalFilesystemMediaProvider) { self.provider = provider }

    /// 扫描指定媒体是否包含 EICAR 测试签名。
    ///
    /// - Parameter mediaID: 目标媒体标识。
    /// - Returns: 含签名时判定不通过，否则判定通过。
    /// - Throws: 读取本地字节失败时抛出。
    public func scan(mediaID: MediaID) async throws -> V2MediaScanResult {
        let bytes = try await provider.localBytesForScanning(mediaID: mediaID)
        return bytes.range(of: Self.eicarTestSignature) == nil ? .passed : .failed
    }

    private static let eicarTestSignature = Data(
        "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".utf8
    )
}
