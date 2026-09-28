import CryptoKit
import Foundation
import IMV2ClientKit
import IMV2Core

/// 一个本地的、可分享的媒体文件。
///
/// 它刻意不包含提供方 URL、凭据或服务端文件名；
/// 这些信息始终留在 ClientKit 的一次性授权与传输边界之内。
struct V2DownloadedConversationMedia: Hashable, Identifiable, Sendable {
    let mediaID: MediaID
    let fileURL: URL
    private let owner: V2ForegroundConversationMediaDownloader?

    init(mediaID: MediaID, fileURL: URL, owner: V2ForegroundConversationMediaDownloader? = nil) {
        self.mediaID = mediaID; self.fileURL = fileURL; self.owner = owner
    }

    /// A path is only a cache hint. Each file consumer must acquire its own use.
    func borrowFile() async throws -> V2ConversationMediaFileLease {
        guard let owner else { throw V2MediaFileAccessError.unavailable }
        return try await owner.borrowFile(mediaID: mediaID, fileURL: fileURL)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mediaID == rhs.mediaID && lhs.fileURL == rhs.fileURL && lhs.owner === rhs.owner
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(mediaID); hasher.combine(fileURL); hasher.combine(owner.map(ObjectIdentifier.init))
    }

    var id: MediaID { mediaID }
}

enum V2MediaFileAccessError: Error, Equatable { case unavailable, overloaded }

/// Owned by exactly one decode, player or share operation. release() is
/// idempotent; copying this value does not create another ownership claim.
nonisolated final class V2ConversationMediaFileLease: Sendable, Identifiable {
    let id: UUID
    let fileURL: URL
    fileprivate let owner: V2ForegroundConversationMediaDownloader
    fileprivate init(id: UUID, fileURL: URL, owner: V2ForegroundConversationMediaDownloader) {
        self.id = id; self.fileURL = fileURL; self.owner = owner
    }
    func release() async { await owner.releaseLease(id) }
    deinit {
        let owner = owner, id = id
        // Backstop for a sheet removed before its controller was constructed.
        // Normal consumers explicitly release after their real I/O has ended.
        Task { await owner.releaseLease(id) }
    }
}

protocol V2ConversationMediaDownloading: Sendable {
    /// 在返回可借用的本地文件之前，先重新授权并发布新的缓存代次。
    ///
    /// 实现绝不能返回提供方目标地址。
    ///
    /// - Parameters:
    ///   - media: 待下载的媒体引用。
    ///   - message: 媒体所在消息的位置，可为空。
    /// - Returns: 可分享的本地媒体文件。
    /// - Throws: 授权失败或传输失败时抛出。
    func download(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia
}

/// 可选的本地缓存能力。
///
/// 它与下载能力分离，使既有的测试/远端实现不会因此获得文件系统权限。
protocol V2ConversationMediaCacheDiscarding: Sendable {
    func discard(_ media: V2MediaReference) async
}

enum V2DeviceLocalStorageError: Error, Equatable, Sendable {
    case fileSystemFailure
    case backupExclusionNotApplied
}

struct V2ConversationMediaCachePolicy: Equatable, Sendable {
    let maximumByteCount: Int64
    let maximumEntryCount: Int
    let maximumAge: TimeInterval

    init(
        maximumByteCount: Int64 = 512 * 1_024 * 1_024,
        maximumEntryCount: Int = 256,
        maximumAge: TimeInterval = 7 * 24 * 60 * 60
    ) {
        precondition(maximumByteCount > 0 && maximumEntryCount > 0)
        precondition(maximumAge.isFinite && maximumAge > 0)
        self.maximumByteCount = maximumByteCount
        self.maximumEntryCount = maximumEntryCount
        self.maximumAge = maximumAge
    }
}

/// 把 V2 的设备本地存储策略应用到存放本地同步状态或已下载媒体的目录。
///
/// 此目录保存前台下载缓存，采用 `Complete` 保护级别。
/// 后台上传源文件和完成回调 inbox 由各自的文件所有者管理。
enum V2DeviceLocalStoragePolicy {
    static func prepareManagedDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        var managedDirectory = directory.standardizedFileURL
        do {
            try fileManager.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
            try applyBackupExclusion(to: &managedDirectory)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: managedDirectory.path
            )
        } catch let error as V2DeviceLocalStorageError {
            throw error
        } catch {
            throw V2DeviceLocalStorageError.fileSystemFailure
        }
        return managedDirectory
    }

    static func applyToManagedFile(
        _ fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        var managedFile = fileURL.standardizedFileURL
        do {
            try applyBackupExclusion(to: &managedFile)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: managedFile.path
            )
        } catch let error as V2DeviceLocalStorageError {
            throw error
        } catch {
            throw V2DeviceLocalStorageError.fileSystemFailure
        }
    }

    private static func applyBackupExclusion(to url: inout URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw V2DeviceLocalStorageError.backupExclusionNotApplied
        }
    }
}

/// 账号范围的前台媒体下载器，拥有传输任务和受管缓存目录。
///
/// 每次请求重新获取服务端授权，先写随机 partial，再发布为 opaque 缓存路径。
/// 关闭后拒绝新请求；迟到传输不能重新发布已经结束账号的文件。
actor V2ForegroundConversationMediaDownloader: V2ConversationMediaDownloading, V2ConversationMediaCacheDiscarding {
    private var isClosed = false
    private var transfers: [UUID: Task<V2DownloadedConversationMedia, Error>] = [:]
    private var transferMedia: [UUID: MediaID] = [:]
    private let downloader: V2ClientMediaDownloadService
    private let directory: URL
    private let fileManager: FileManager
    private let cachePolicy: V2ConversationMediaCachePolicy
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    init(
        downloader: V2ClientMediaDownloadService,
        directory: URL,
        fileManager: FileManager = .default,
        cachePolicy: V2ConversationMediaCachePolicy = .init(),
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.downloader = downloader
        let prepared = try V2DeviceLocalStoragePolicy.prepareManagedDirectory(directory, fileManager: fileManager)
        // URL directory hints affect equality even when paths name the same
        // directory. Canonicalize once for both borrowing and cleanup guards.
        self.directory = URL(fileURLWithPath: prepared.path, isDirectory: true)
        self.fileManager = fileManager
        self.cachePolicy = cachePolicy
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 重新授权并下载媒体，成功后返回本地可分享路径。
    ///
    /// - Parameters:
    ///   - media: 不透明媒体引用。
    ///   - message: 需要消息可见性授权时使用的位置；其他用途可为 nil。
    /// - Returns: 当前媒体 ID 与完成发布的受管文件 URL。
    /// - Throws: 取消、账号下载器关闭、授权／传输或文件系统错误。
    ///   失败时尝试删除本次 partial，调用者不能将返回前的临时路径用于展示。
    func download(_ media: V2MediaReference, message: V2MediaMessageLocation? = nil) async throws -> V2DownloadedConversationMedia {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        guard transfers.count + avatarFlights.count < 4 else { throw V2ClientMediaTransferError.serverStatus(429) }
        let id = UUID()
        // The account owns and drains the transfer; caller cancellation is
        // explicitly forwarded to this shared lifetime boundary.
        let task = Task { try await self.performDownload(media, message: message) }
        transfers[id] = task
        transferMedia[id] = media.mediaID
        defer { transfers.removeValue(forKey: id); transferMedia.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            return result
        } onCancel: { task.cancel() }
    }

    /// 终止下载器并在所有传输结束后删除账号下载目录。
    ///
    /// 取消不能保证底层立刻停止写文件，因此先等待任务，再执行目录清理。
    ///
    /// - Throws: 目录删除失败时返回文件系统错误；可再次调用以重试清理。
    func close() async throws {
        isClosed = true
        let avatarTasks = Array(avatarFlights.values)
        for task in avatarTasks { task.cancel() }
        for task in avatarTasks { _ = await task.result }
        avatarFlights.removeAll()
        let pending = Array(transfers.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        // The UI is removed before account cleanup starts. Its player teardown,
        // completed share, and thumbnail decoder release actual file uses.
        if !filePins.isEmpty { await withCheckedContinuation { fileDrainWaiters.append($0) } }
        if fileManager.fileExists(atPath: directory.path) {
            do { try fileManager.removeItem(at: directory) }
            catch { throw V2DeviceLocalStorageError.fileSystemFailure }
        }
        publishedFiles.removeAll(); verifiedAvatars.removeAll(); pendingDeletion.removeAll()
    }

    private var reservedBytes: Int64 = 0
    private var avatarFlights: [String: V2SharedOperation<V2DownloadedConversationMedia>] = [:]
    private var filePins: [URL: Int] = [:]
    private var verifiedAvatars: Set<URL> = []
    private var publishedFiles: [URL: MediaID] = [:]
    private var fileLeases: [UUID: URL] = [:]
    private var pendingDeletion: Set<URL> = []
    private var activeTemporaryFiles: Set<URL> = []
    private var discardedTemporaryFiles: Set<URL> = []
    private var fileDrainWaiters: [CheckedContinuation<Void, Never>] = []

    fileprivate func borrowFile(mediaID: MediaID, fileURL: URL) throws -> V2ConversationMediaFileLease {
        try Task.checkCancellation()
        let url = fileURL.standardizedFileURL
        guard !isClosed, publishedFiles[url] == mediaID, !pendingDeletion.contains(url),
              url.deletingLastPathComponent() == directory,
              let facts = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              facts.isRegularFile == true, facts.isSymbolicLink != true
        else { throw V2MediaFileAccessError.unavailable }
        guard fileLeases.count < 64 else { throw V2MediaFileAccessError.overloaded }
        let id = UUID()
        fileLeases[id] = url; filePins[url, default: 0] += 1
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        return .init(id: id, fileURL: url, owner: self)
    }

    fileprivate func releaseLease(_ id: UUID) {
        guard let url = fileLeases.removeValue(forKey: id) else { return }
        releaseFile(url)
    }

    func releaseFile(_ url: URL) {
        let count = filePins[url, default: 0]
        if count <= 1 { filePins.removeValue(forKey: url) } else { filePins[url] = count - 1 }
        if filePins[url] == nil, pendingDeletion.contains(url) { removeCachedFile(url) }
        if filePins.isEmpty {
            let waiters = fileDrainWaiters; fileDrainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func avatar(_ access: V2ResourceAvatarAccess) async throws -> V2DownloadedConversationMedia {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        let key = access.mediaID.rawValue + ":" + access.variantID.rawValue + ":" + String(access.version) + ":" + access.checksum.value
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent(digest + ".media")
        if fileManager.fileExists(atPath: destination.path),
           (verifiedAvatars.contains(destination) || (try? V2ResourceFileDigest.sha256(fileURL: destination, expectedByteCount: access.plan.expectedByteCount)) == access.checksum.value) {
            verifiedAvatars.insert(destination)
            filePins[destination, default: 0] += 1
            try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: destination.path)
            return .init(mediaID: access.mediaID, fileURL: destination)
        }
        let flight: V2SharedOperation<V2DownloadedConversationMedia>
        if let existing = avatarFlights[key] { flight = existing }
        else {
            guard transfers.count + avatarFlights.count < 4 else { throw V2ClientMediaTransferError.serverStatus(429) }
            flight = V2SharedOperation { try await self.performAvatar(access, key: key, destination: destination) }
            avatarFlights[key] = flight
        }
        filePins[destination, default: 0] += 1
        do {
            let result = try await flight.value
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            return result
        } catch {
            releaseFile(destination)
            throw error
        }
    }

    private func performAvatar(_ access: V2ResourceAvatarAccess, key: String, destination: URL) async throws -> V2DownloadedConversationMedia {
        defer { avatarFlights.removeValue(forKey: key) }
        let expected = access.plan.expectedByteCount
        guard expected > 0, expected <= 2 * 1_024 * 1_024 else { throw V2ClientMediaTransferError.invalidTarget }
        guard access.plan.expiresAt > now() else { throw V2ClientMediaTransferError.targetExpired }
        let temporary = destination.deletingPathExtension().appendingPathExtension("download")
        let partial = temporary.appendingPathExtension("range-part")
        let journal = temporary.appendingPathExtension("range-journal")
        let existing = (try? fileManager.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        let reservation = try reserve(bytes: expected,alreadyStaged: existing)
        defer { reservedBytes -= reservation }
        activeTemporaryFiles.formUnion([temporary,partial,journal])
        defer {
            activeTemporaryFiles.subtract([temporary,partial,journal])
            try? fileManager.removeItem(at: temporary)
        }
        let target = try V2ClientMediaTransferTarget(downloadPlan: access.plan)
        // Use the same bounded byte leaf and account permit as attachments.
        // The immutable avatar version remains bound to its current lease.
        try await downloader.download(target: target,to: temporary)
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        guard (try fileManager.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value == expected,
              try V2ResourceFileDigest.sha256(fileURL: temporary,expectedByteCount: expected) == access.checksum.value else { throw V2ClientMediaTransferError.byteCountMismatch }
        try V2DeviceLocalStoragePolicy.applyToManagedFile(temporary,fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
        verifiedAvatars.insert(destination)
        return .init(mediaID: access.mediaID, fileURL: destination)
    }

    /// Reserve both transfer/temp and final publication peaks before starting I/O.
    private func reserve(bytes: Int64, alreadyStaged: Int64 = 0) throws -> Int64 {
        guard bytes > 0, bytes <= cachePolicy.maximumByteCount / 2 else { throw V2ConversationAttachmentStagingError.stagingQuotaExceeded }
        let peak = bytes * 2 - min(max(0,alreadyStaged),bytes)
        guard reservedBytes <= cachePolicy.maximumByteCount - peak else { throw V2ConversationAttachmentStagingError.stagingQuotaExceeded }
        try enforceCachePolicy(excluding: nil, reservedAddition: peak)
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        let used = try files.reduce(Int64(0)) { value, url in
            let facts = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return value + (facts.isRegularFile == true ? Int64(facts.fileSize ?? 0) : 0)
        }
        guard used <= cachePolicy.maximumByteCount - reservedBytes - peak else { throw V2ConversationAttachmentStagingError.stagingQuotaExceeded }
        let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free >= reservedBytes + peak + 16 * 1_024 * 1_024 else { throw V2ConversationAttachmentStagingError.stagingQuotaExceeded }
        reservedBytes += peak
        return peak
    }

    private func performDownload(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        // Immutable local generations keep an existing player/share and its
        // decoded thumbnail bound to the original bytes during a fresh download.
        let destination = directory.appendingPathComponent(cacheStem(for: media.mediaID) + "." + UUID().uuidString + ".media")
        let target = try await downloader.authorizedTarget(mediaID: media.mediaID, message: message)
        // Account directory + media identity + authoritative checksum form the
        // stable recovery key. Signed targets and headers remain in memory.
        let temporary = directory.appendingPathComponent("." + cacheStem(for: media.mediaID) + "." + target.checksum.value + ".download")
        let partial = temporary.appendingPathExtension("range-part")
        let journal = temporary.appendingPathExtension("range-journal")
        guard !activeTemporaryFiles.contains(temporary) else { throw V2ClientMediaTransferError.uploadStateConflict }
        activeTemporaryFiles.formUnion([temporary,partial,journal])
        defer {
            activeTemporaryFiles.subtract([temporary,partial,journal])
            try? fileManager.removeItem(at: temporary)
            if discardedTemporaryFiles.remove(temporary) != nil {
                try? fileManager.removeItem(at: partial)
                try? fileManager.removeItem(at: journal)
            }
        }
        let expected = target.expectedByteCount
        let existing = (try? fileManager.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        let reservation = try reserve(bytes: expected,alreadyStaged: existing)
        defer { reservedBytes -= reservation }
        try await downloader.download(target: target, to: temporary)
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }

        do {
            // Apply the complete protection policy before the commit. Once
            // the staging file becomes visible at the stable cache URL there
            // is no later fallible step that can report failure while leaving
            // a partially configured cache entry behind.
            try V2DeviceLocalStoragePolicy.applyToManagedFile(temporary, fileManager: fileManager)
            try fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: temporary.path)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            throw V2DeviceLocalStorageError.fileSystemFailure
        }
        publishedFiles[destination] = media.mediaID
        for (url, id) in publishedFiles where id == media.mediaID && url != destination {
            retireCachedFile(url)
        }
        // Admission already reserved the byte peak. Keep this generation for
        // the caller; policy cleanup never removes a consumer's pinned file.
        try? enforceCachePolicy(excluding: destination)
        return .init(mediaID: media.mediaID, fileURL: destination, owner: self)
    }

    func discard(_ media: V2MediaReference) async {
        for (id,target) in transferMedia where target == media.mediaID { transfers[id]?.cancel() }
        let stem = cacheStem(for: media.mediaID)
        for temporary in activeTemporaryFiles where temporary.pathExtension == "download" && temporary.lastPathComponent.hasPrefix("." + stem + ".") {
            discardedTemporaryFiles.insert(temporary)
        }
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            if file.pathExtension == "media" && (file.lastPathComponent == stem + ".media" || file.lastPathComponent.hasPrefix(stem + ".")) {
                retireCachedFile(file.standardizedFileURL)
            } else if file.lastPathComponent.hasPrefix("." + stem + "."), ["range-part","range-journal","download"].contains(file.pathExtension), !activeTemporaryFiles.contains(file) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func retireCachedFile(_ url: URL) {
        publishedFiles.removeValue(forKey: url)
        pendingDeletion.insert(url)
        if filePins[url] == nil { removeCachedFile(url) }
    }

    private func removeCachedFile(_ url: URL) {
        do {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            publishedFiles.removeValue(forKey: url); verifiedAvatars.remove(url); pendingDeletion.remove(url)
        } catch { /* Keep the retirement marker; maintenance retries deletion. */ }
    }

    /// 清理被中断的临时下载文件。
    ///
    /// 被中断的 URLSession 下载只会留下随机的 `.partial` 文件；
    /// 该操作绝不触碰完整的缓存条目，也绝不会遍历到缓存目录之外。
    func discardOrphanedTemporaryFiles() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return }
        for entry in entries {
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  (candidate.lastPathComponent.hasPrefix(".") || ["range-part","range-journal","download"].contains(candidate.pathExtension)),
                  (candidate.pathExtension == "partial" ||
                    (["range-part","range-journal","download"].contains(candidate.pathExtension) &&
                     ((try? candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < now().addingTimeInterval(-cachePolicy.maximumAge))),
                  !activeTemporaryFiles.contains(candidate),
                  (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            try? fileManager.removeItem(at: candidate)
        }
    }

    /// 激活期维护。
    ///
    /// 依次清除被中断的传输、已过期条目，然后按最近最少下载顺序删除文件，
    /// 直到满足两个容量上限。它只检查缓存目录直属的、带缓存扩展名的常规子文件，
    /// 绝不跟随指向受管目录之外的路径。
    func performMaintenance() {
        discardOrphanedTemporaryFiles()
        for url in pendingDeletion where filePins[url] == nil { removeCachedFile(url) }
        try? enforceCachePolicy(excluding: nil)
    }

    private func enforceCachePolicy(excluding retainedURL: URL?, reservedAddition: Int64 = 0) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).compactMap { url -> MediaCacheEntry? in
            let candidate = url.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  candidate.pathExtension == "media"
            else { return nil }
            let values = try candidate.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return .init(
                url: candidate,
                byteCount: max(0, Int64(values.fileSize ?? 0)),
                lastAccessedAt: values.contentModificationDate ?? .distantPast
            )
        }
        let expirationBoundary = now().addingTimeInterval(-cachePolicy.maximumAge)
        var retainedEntries: [MediaCacheEntry] = []
        for entry in entries {
            if entry.lastAccessedAt < expirationBoundary,
               entry.url != retainedURL?.standardizedFileURL, filePins[entry.url] == nil {
                do {
                    try fileManager.removeItem(at: entry.url)
                    publishedFiles.removeValue(forKey: entry.url); verifiedAvatars.remove(entry.url)
                } catch {
                    retainedEntries.append(entry)
                }
            } else {
                retainedEntries.append(entry)
            }
        }

        var totalBytes = retainedEntries.reduce(Int64(0)) { partial, entry in
            partial.addingReportingOverflow(entry.byteCount).overflow
                ? Int64.max
                : partial + entry.byteCount
        }
        var totalEntries = retainedEntries.count
        for entry in retainedEntries.sorted(by: MediaCacheEntry.olderFirst) {
            guard totalEntries > cachePolicy.maximumEntryCount || totalBytes > cachePolicy.maximumByteCount - reservedBytes - reservedAddition else { break }
            guard entry.url != retainedURL?.standardizedFileURL, filePins[entry.url] == nil else { continue }
            do {
                try fileManager.removeItem(at: entry.url)
                publishedFiles.removeValue(forKey: entry.url)
                verifiedAvatars.remove(entry.url)
                totalEntries -= 1
                totalBytes = max(0, totalBytes - entry.byteCount)
            } catch {
                continue
            }
        }
    }

    private func cacheStem(for mediaID: MediaID) -> String {
        SHA256.hash(data: Data(mediaID.rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct MediaCacheEntry {
    let url: URL
    let byteCount: Int64
    let lastAccessedAt: Date

    static func olderFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.lastAccessedAt == rhs.lastAccessedAt
            ? lhs.url.lastPathComponent < rhs.url.lastPathComponent
            : lhs.lastAccessedAt < rhs.lastAccessedAt
    }
}
